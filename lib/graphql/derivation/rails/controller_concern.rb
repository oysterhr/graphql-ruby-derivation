# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/hash/keys'
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
        # `resource_scopes` holds `{key => ResourceScope}` for any
        # `resource_arguments` blocks (SPEC.md §8.1).
        PendingAction = Struct.new(:inline_arguments, :arguments_from, :resource_scopes, keyword_init: true)

        # A single `resource_arguments key do ... end` block's own declarations,
        # buffered the same shape as `PendingAction` (minus nested
        # `resource_scopes` -- nesting is not supported, SPEC.md §8.1).
        ResourceScope = Struct.new(:key, :required, :inline_arguments, :arguments_from, keyword_init: true)

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

            current_buffer.inline_arguments << [name, type, opts]
          end

          # SPEC.md §8.1: declare a composable source (ObjectType class,
          # InputObject class, or Symbol sibling action) for the next action (or,
          # inside a `resource_arguments` block, for that resource scope). At
          # most one per action/scope; a second call before the next flush is a
          # ConfigurationError.
          def arguments_from(source, &block)
            unless current_buffer.arguments_from.nil?
              raise GraphQL::Derivation::ConfigurationError,
                'arguments_from may be called at most once per action (SPEC.md §8.1).'
            end

            current_buffer.arguments_from = [source, block]
          end

          # SPEC.md §8.1: declares a Rails-idiomatic nested resource scope for
          # the next action, so the request wire format matches
          # `form_for`/strong-parameters conventions (`{ expense: { title: ...
          # } }`) instead of every argument sitting flat at the top level.
          # `argument`/`arguments_from` calls inside `block` are scoped to this
          # resource rather than the action's flat/top-level argument set; the
          # block runs as if written directly in the class body.
          #
          # Mechanically this is sugar over the existing InputObject machinery:
          # the block's declarations build their own anonymous InputObject
          # (`build_input_object_class`, same construction as the top-level
          # one), which is then registered on `ArgumentSchema` and added as a
          # single ordinary `argument key, NestedInputObjectClass, required:
          # required` on the action's own InputObject (see `build_input_object`).
          # No new coercion path is needed -- `coerce_input`, collision
          # detection, and `arguments_from` cycle detection already handle a
          # nested InputObject argument as a normal case.
          #
          # `required:` defaults to `true` and must be explicit: since the
          # nested type is a real, introspectable InputObject (registered for
          # TypeScript codegen the same as any other generated InputObject,
          # SPEC.md §8.2), its own nullability in the generated SDL
          # (`ExpensesCreateExpenseInput!` vs `ExpensesCreateExpenseInput`)
          # must be a deliberate choice, not inferred.
          #
          # Nesting a `resource_arguments` block inside another is not
          # supported (raises immediately) -- though the underlying mechanism
          # (a nested InputObject argument can itself contain another) is
          # already generalizable to it, should that be needed later.
          def resource_arguments(key, required: true, &block)
            check_no_nested_resource_scope!(key)
            key = key.to_s
            check_resource_scope_not_already_declared!(key)

            scope = ResourceScope.new(key: key, required: required, inline_arguments: [], arguments_from: nil)
            pending_buffer.resource_scopes[key] = scope
            evaluate_resource_scope_block(scope, &block)

            define_resource_params_helper(key)
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
          #
          # `@defining_internal_helper` guards against `define_method` calls
          # this concern makes on itself (namely `define_resource_params_helper`)
          # -- `define_method` triggers `method_added` exactly like `def` does,
          # so without this guard, defining e.g. `expense_params` would flush
          # the still-pending buffer under THAT name instead of the real next
          # action, before the real action method is even reached.
          def method_added(method_name)
            super
            return if @defining_internal_helper

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

          # Every `resource_arguments` scope's own nested InputObject class,
          # keyed by action name (SPEC.md §8.1) -- resolved alongside the
          # action's own InputObject in `resolve_action_input_object!`, since
          # they carry their own `derive_from` derivation independently.
          def own_action_resource_input_objects
            @own_action_resource_input_objects ||= Hash.new { |hash, key| hash[key] = [] }
          end

          # Same ancestor-walking contract as `argument_input_object_for`, but
          # for the (possibly empty) list of resource-scope InputObjects.
          def resource_input_objects_for(action_name)
            action_name = action_name.to_s
            klass = self
            while klass.respond_to?(:own_action_resource_input_objects)
              found = klass.own_action_resource_input_objects[action_name]
              return found unless found.empty?

              klass = klass.superclass
            end
            []
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
          # name. Idempotent for already-resolved actions. Also resolves each
          # of the action's `resource_arguments` scopes' own InputObjects
          # (SPEC.md §8.1) -- they carry their own independent `derive_from`
          # derivation, which is not reached by resolving the outer InputObject
          # alone (they are plain `argument`s on it, not a `derive_from` source
          # of it).
          def resolve_action_input_object!(action_name)
            action_name = action_name.to_s
            input_object = argument_input_object_for(action_name)
            return unless input_object

            detect_sibling_cycle!(action_name)
            sibling_resolution_stack.push(action_name)
            begin
              resolve_input_object_and_resource_scopes!(action_name, input_object)
            ensure
              sibling_resolution_stack.pop
            end
          end

          private

          # `self` (the controller class) is the sibling resolver context.
          def resolve_input_object_and_resource_scopes!(action_name, input_object)
            resource_input_objects_for(action_name).each { |nested| nested.resolve_derivation!(context: self) }
            input_object.resolve_derivation!(context: self)
          end

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
            @pending_buffer ||= PendingAction.new(inline_arguments: [], arguments_from: nil, resource_scopes: {})
          end

          def reset_pending_buffer!
            @pending_buffer = PendingAction.new(inline_arguments: [], arguments_from: nil, resource_scopes: {})
          end

          # `argument`/`arguments_from` target this instead of `pending_buffer`
          # directly, so calls made inside a `resource_arguments` block are
          # scoped to that resource rather than the action's flat/top-level
          # argument set (SPEC.md §8.1).
          def current_buffer
            @current_resource_scope || pending_buffer
          end

          def flush_pending_action(action_name)
            buffer = pending_buffer
            return if pending_buffer_empty?(buffer)

            input_object, resource_input_objects = build_input_object(action_name, buffer)
            ArgumentSchema.for(resolved_argument_namespace).register_input_object(input_object)
            own_action_input_objects[action_name] = input_object
            own_action_resource_input_objects[action_name] = resource_input_objects
          ensure
            reset_pending_buffer!
          end

          def pending_buffer_empty?(buffer)
            buffer.inline_arguments.empty? && buffer.arguments_from.nil? && buffer.resource_scopes.empty?
          end

          # Builds the action's own InputObject from its flat/top-level
          # declarations, first building each `resource_arguments` scope's
          # own nested InputObject and adding it as a plain argument on the
          # action's InputObject (SPEC.md §8.1). Only the action's own
          # (top-level) InputObject needs registering on `ArgumentSchema`
          # (see that class's docs) -- a nested InputObject becomes reachable
          # for `to_definition` automatically once the top-level one is, so
          # it is not separately registered here.
          # Returns `[input_object, resource_input_objects]` -- the caller
          # needs the resource InputObjects separately so their own
          # derivations can be resolved later (`resolve_action_input_object!`).
          def build_input_object(action_name, buffer)
            type_name = "#{name}#{action_name.camelize}Input".delete(':')
            input_object = build_input_object_class(type_name, buffer.inline_arguments, buffer.arguments_from)
            resource_input_objects = build_resource_input_objects(action_name, input_object, buffer.resource_scopes)

            [input_object, resource_input_objects]
          end

          def build_resource_input_objects(action_name, input_object, resource_scopes)
            resource_scopes.map do |key, scope|
              check_resource_key_collision!(input_object, key)

              nested_type_name = "#{name}#{action_name.camelize}#{key.camelize}Input".delete(':')
              nested = build_input_object_class(nested_type_name, scope.inline_arguments, scope.arguments_from)
              input_object.argument(key, nested, required: scope.required)
              nested
            end
          end

          # Shared by the action-level InputObject and each
          # `resource_arguments` scope's own nested InputObject -- both are
          # "a `graphql_name`, some inline arguments, and at most one
          # `arguments_from`", built identically.
          def build_input_object_class(type_name, inline_arguments, arguments_from)
            input_object = Class.new(GraphQL::Schema::InputObject) do
              include GraphQL::Derivation::DerivableInputObject

              graphql_name(type_name)
            end

            inline_arguments.each do |arg_name, arg_type, opts|
              input_object.argument(arg_name, arg_type, **opts)
            end
            apply_arguments_from(input_object, arguments_from)
            input_object
          end

          # Runs `block` (the `resource_arguments` block) as if written
          # directly in the class body, with `argument`/`arguments_from`
          # calls inside it routed to `scope` via `current_buffer` -- see
          # `resource_arguments`'s own docs.
          def evaluate_resource_scope_block(scope, &block)
            @current_resource_scope = scope
            class_exec(&block)
          ensure
            @current_resource_scope = nil
          end

          def check_no_nested_resource_scope!(key)
            return unless @current_resource_scope

            raise GraphQL::Derivation::ConfigurationError,
              "resource_arguments #{key.inspect}: nested resource_arguments blocks are not " \
              'supported (SPEC.md §8.1).'
          end

          def check_resource_scope_not_already_declared!(key)
            return unless pending_buffer.resource_scopes.key?(key)

            raise GraphQL::Derivation::ConfigurationError,
              "resource_arguments #{key.inspect} was already declared for this action " \
              '(SPEC.md §8.1).'
          end

          # SPEC.md §8.1's collision rule, applied to `resource_arguments`:
          # graphql-ruby's own `argument()` does NOT raise on a duplicate name
          # by default -- it silently stores an overload array
          # (`add_argument`'s multiple-definitions-per-name support, meant for
          # polymorphic arguments), which would make a flat/`resource_arguments`
          # name collision fail confusingly at coercion time instead of
          # cleanly at declaration time. Checked explicitly, before the
          # `argument key, nested, ...` call that would otherwise silently
          # overload rather than collide.
          def check_resource_key_collision!(input_object, key)
            graphql_name = key.camelize(:lower)
            return unless input_object.arguments.key?(graphql_name)

            raise GraphQL::Derivation::ConfigurationError,
              "resource_arguments #{key.inspect} collides with an argument already declared " \
              "as #{graphql_name.inspect} on this action (SPEC.md §8.1)."
          end

          def apply_arguments_from(input_object, arguments_from)
            return unless arguments_from

            source, block = arguments_from
            # Symbol (sibling) sources ARE valid here: the controller class is
            # the registry that resolves them (SPEC.md §4.2). Opt in before
            # deriving so DerivableInputObject's §11.1 rejection does not fire
            # on the auto-generated InputObject.
            input_object.send(:allow_sibling_sources!) if source.is_a?(Symbol)
            input_object.derive_from(source, &block)
          end

          # Defines the Rails-familiar `"#{key}_params"` private instance
          # helper for a `resource_arguments key` scope (SPEC.md §8.1) --
          # equivalent to `arguments[key]`, added purely for call-site
          # ergonomics (`Expense.create(expense_params)`).
          def define_resource_params_helper(key)
            helper_name = "#{key}_params"
            @defining_internal_helper = true
            begin
              define_method(helper_name) { arguments[key.to_sym] }
            ensure
              @defining_internal_helper = false
            end
            private helper_name
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
          # SPEC.md §8.1 "Unknown top-level keys are silently ignored": a
          # real Rails `params` always includes routing internals
          # (`controller`, `action`) and every dynamic route segment,
          # regardless of whether any of them are declared as arguments.
          # Filtered out before validation -- exactly Rails' own
          # strong-parameters philosophy (`params.permit(...)` silently
          # drops unpermitted keys rather than raising) -- so they don't
          # trip `validate_input`'s "Field is not defined" check.
          raw_input = graphql_argument_input.slice(*input_object.arguments.keys)
          validate_request_input!(input_object, raw_input, context)

          coerced = context.schema.sync_lazy(input_object.coerce_input(raw_input, context))
          # `#to_h`, not `#to_kwargs`: a `resource_arguments` scope (SPEC.md
          # §8.1) is coerced as a nested InputObject argument, and `#to_h`
          # recursively unwraps nested InputObject values into plain Hashes
          # (`#to_kwargs` does not -- it would leave the nested value as a
          # `GraphQL::Schema::InputObject` instance, not the plain Hash a
          # controller action expects). Identical output to `#to_kwargs` for
          # the flat/no-nesting case.
          coerced.to_h
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

        # The request input, as a String-keyed Hash (recursively, so a
        # `resource_arguments` scope's nested Hash is string-keyed too) of
        # camelCase argument names matching the InputObject's GraphQL argument
        # names. Pulled from Rails' `params` when available; the keys must be
        # the GraphQL (camelCase) names. Controllers may override this if
        # their wire format differs.
        def graphql_argument_input
          return {} unless respond_to?(:params)

          raw = params
          raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
          raw.deep_stringify_keys
        end
      end
    end
  end
end
