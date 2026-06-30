# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/core_ext/string/inflections'
require 'graphql'
require 'graphql/derivation'
require 'graphql/derivation/rails/errors'
require 'graphql/derivation/rails/argument_schema'

module GraphQL
  module Derivation
    module Rails
      # SPEC.md §8.1. Mixed into a Rails controller base class to declare,
      # per-action, the typed argument set a request must satisfy. The class
      # DSL (`argument`, `arguments_from`) buffers declarations against the
      # *next* action defined (caught via `method_added`); each non-empty buffer
      # is flushed into an anonymous `GraphQL::Schema::InputObject` registered on
      # the namespace's `ArgumentSchema`. The instance method `arguments` then
      # coerces the request params against that InputObject.
      #
      # ## Derivation-timing design (the one non-obvious decision here)
      #
      # The anonymous InputObject `include`s `DerivableInputObject` and calls its
      # `derive_from`, so all the argument-building/collision machinery is reused
      # rather than reimplemented (SPEC's "don't duplicate derivation
      # machinery" intent). But resolution *timing* is driven here, not by
      # `DerivableInputObject.resolve_all!`: this concern calls each
      # InputObject's `resolve_derivation!` explicitly, passing the controller
      # class as `context:` so Symbol (sibling) sources can be looked up in the
      # action registry. Driving timing ourselves is what lets
      # `eager_load_argument_sources!` detect sibling cycles deterministically
      # (it tracks which actions are mid-resolution on a DFS stack).
      module ControllerConcern
        extend ActiveSupport::Concern

        # Internal record of what a single action declared, before it is flushed
        # into an InputObject. `arguments_from` holds `[source, block]` or nil.
        PendingAction = Struct.new(:inline_arguments, :arguments_from, keyword_init: true)

        class_methods do
          # SPEC.md §8.1: declare a single inline argument, buffered against the
          # next action. `loads:` is rejected (it implies object loading, which
          # is out of scope for argument schemas) at declaration time.
          def argument(name, type, **opts)
            if opts.key?(:loads)
              raise GraphQL::Derivation::ConfigurationError,
                "argument #{name.inspect}: `loads:` is not supported in ControllerConcern " \
                'argument declarations (SPEC.md §8.1).'
            end

            pending_buffer.inline_arguments << [name, type, opts]
          end

          # SPEC.md §8.1: declare a composable source (ObjectType class,
          # InputObject class, or Symbol sibling action) for the next action. At
          # most one per action; a second call before the next `method_added`
          # flush is a ConfigurationError.
          def arguments_from(source, &block)
            unless pending_buffer.arguments_from.nil?
              raise GraphQL::Derivation::ConfigurationError,
                'arguments_from may be called at most once per action (SPEC.md §8.1).'
            end

            pending_buffer.arguments_from = [source, block]
          end

          # SPEC.md §8.2: set the namespace whose `ArgumentSchema` holds this
          # controller's InputObjects. Inherited by subclasses; defaults to
          # `:default` when never called.
          def argument_namespace(name)
            @argument_namespace = name
          end

          def resolved_argument_namespace
            return @argument_namespace if defined?(@argument_namespace) && @argument_namespace

            superclass.respond_to?(:resolved_argument_namespace) ? superclass.resolved_argument_namespace : :default
          end

          # SPEC.md §8.1 `method_added` hook: flush the pending buffer into an
          # InputObject for `method_name`. Empty buffer => no InputObject, action
          # left unregistered (calling `arguments` from it raises
          # MissingInputTypeError).
          def method_added(method_name)
            super
            flush_pending_action(method_name.to_s)
          end

          # The InputObject registered for +action_name+ on this class or an
          # ancestor (SPEC.md §8.1/§4.2: "same controller class or an ancestor").
          # nil if unregistered.
          def argument_input_object_for(action_name)
            action_name = action_name.to_s
            klass = self
            while klass.respond_to?(:own_action_input_objects)
              found = klass.own_action_input_objects[action_name]
              return found if found

              klass = klass.superclass
            end
            nil
          end

          def own_action_input_objects
            @own_action_input_objects ||= {}
          end

          # SPEC.md §8.1: resolve every composable source registered on this
          # class and its ancestors, detecting sibling cycles. Intended to run
          # in CI so cycles fail before merge.
          def eager_load_argument_sources!
            sibling_resolution_stack.clear
            each_registered_action do |action_name, _input_object|
              resolve_action_input_object!(action_name)
            end
          end

          # `context:` contract consumed by ArgumentDerivation for Symbol
          # sources (SPEC.md §4.2). Resolves the sibling action's InputObject
          # (which may cascade into further siblings) and returns its resolved
          # arguments. Cycle detection lives here: an action already on the
          # in-progress stack means a sibling cycle.
          def resolve_sibling_arguments(action_name)
            action_name = action_name.to_s
            input_object = argument_input_object_for(action_name)
            unless input_object
              raise GraphQL::Derivation::ConfigurationError,
                "arguments_from references sibling action #{action_name.inspect}, " \
                'but no such action is registered on this controller or its ancestors (SPEC.md §4.2).'
            end

            resolve_action_input_object!(action_name)
            input_object.arguments.values
          end

          # Ensures +action_name+'s InputObject is resolved, guarding against
          # sibling cycles via a depth-first in-progress stack keyed by action
          # name. Idempotent for already-resolved actions.
          def resolve_action_input_object!(action_name)
            action_name = action_name.to_s
            input_object = argument_input_object_for(action_name)
            return unless input_object

            detect_sibling_cycle!(action_name)
            sibling_resolution_stack.push(action_name)
            begin
              # `self` (the controller class) is the sibling resolver context.
              input_object.resolve_derivation!(context: self)
            ensure
              sibling_resolution_stack.pop
            end
          end

          private

          def detect_sibling_cycle!(action_name)
            return unless sibling_resolution_stack.include?(action_name)

            cycle = sibling_resolution_stack[sibling_resolution_stack.index(action_name)..] + [action_name]
            raise GraphQL::Derivation::CyclicDependencyError,
              "Cyclic arguments_from sibling dependency: #{cycle.join(' → ')}"
          end

          def sibling_resolution_stack
            @sibling_resolution_stack ||= []
          end

          def pending_buffer
            @pending_buffer ||= PendingAction.new(inline_arguments: [], arguments_from: nil)
          end

          def reset_pending_buffer!
            @pending_buffer = PendingAction.new(inline_arguments: [], arguments_from: nil)
          end

          def flush_pending_action(action_name)
            buffer = pending_buffer
            return if buffer.inline_arguments.empty? && buffer.arguments_from.nil?

            input_object = build_input_object(action_name, buffer)
            ArgumentSchema.for(resolved_argument_namespace).register_input_object(input_object)
            own_action_input_objects[action_name] = input_object
          ensure
            reset_pending_buffer!
          end

          def build_input_object(action_name, buffer)
            type_name = "#{name}#{action_name.camelize}Input".delete(':')

            input_object = Class.new(GraphQL::Schema::InputObject) do
              include GraphQL::Derivation::DerivableInputObject

              graphql_name(type_name)
            end

            buffer.inline_arguments.each do |arg_name, arg_type, opts|
              input_object.argument(arg_name, arg_type, **opts)
            end
            apply_arguments_from(input_object, buffer.arguments_from)
            input_object
          end

          def apply_arguments_from(input_object, arguments_from)
            return unless arguments_from

            source, block = arguments_from
            # Symbol (sibling) sources ARE valid here: the controller class is
            # the registry that resolves them (SPEC.md §4.2). Opt in before
            # deriving so DerivableInputObject's §11.1 rejection does not fire
            # on the auto-generated InputObject.
            input_object.allow_sibling_sources! if source.is_a?(Symbol)
            input_object.derive_from(source, &block)
          end

          # Yields every [action_name, input_object] registered on this class
          # and all ancestors that include the concern.
          def each_registered_action(&block)
            klass = self
            while klass.respond_to?(:own_action_input_objects)
              klass.own_action_input_objects.each(&block)
              klass = klass.superclass
            end
          end
        end

        # SPEC.md §8.1: coerced request arguments for the current action,
        # memoized per request. Snake-case symbol keys.
        def arguments
          return @arguments if defined?(@arguments)

          @arguments = coerce_request_arguments
        end

        def coerce_request_arguments
          input_object = self.class.argument_input_object_for(action_name)
          unless input_object
            raise GraphQL::Derivation::Rails::MissingInputTypeError,
              "No arguments were declared for action #{action_name.inspect} on #{self.class} " \
              '(SPEC.md §8.1). Declare `argument` or `arguments_from` for it.'
          end

          self.class.resolve_action_input_object!(action_name)

          namespace = self.class.resolved_argument_namespace
          context = ArgumentSchema.for(namespace).coercion_context

          coerce_with_input_object(input_object, context)
        end

        def coerce_with_input_object(input_object, context)
          raw_input = graphql_argument_input
          validate_request_input!(input_object, raw_input, context)

          coerced = context.schema.sync_lazy(input_object.coerce_input(raw_input, context))
          coerced.to_kwargs
        rescue GraphQL::ExecutionError, GraphQL::CoercionError => e
          raise GraphQL::Derivation::Rails::ArgumentParsingError,
            "Could not coerce arguments for #{action_name.inspect}: #{e.message}"
        end

        def validate_request_input!(input_object, raw_input, context)
          validation = input_object.validate_input(raw_input, context)
          return if validation.valid?

          raise GraphQL::Derivation::Rails::ArgumentParsingError,
            "Could not coerce arguments for #{action_name.inspect}: #{validation.problems.inspect}"
        end

        # The request input, as a String-keyed Hash of camelCase argument names
        # matching the InputObject's GraphQL argument names. Pulled from Rails'
        # `params` when available; the keys must be the GraphQL (camelCase)
        # names. Controllers may override this if their wire format differs.
        def graphql_argument_input
          return {} unless respond_to?(:params)

          raw = params
          raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
          raw.transform_keys(&:to_s)
        end
      end
    end
  end
end
