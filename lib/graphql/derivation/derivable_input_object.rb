# frozen_string_literal: true

require 'graphql/derivation/engines/argument_derivation'

module GraphQL
  module Derivation
    # Implements SPEC.md §6, a mixin for `GraphQL::Schema::InputObject`
    # subclasses that adds `derive_from`. The derivation is stored
    # unevaluated at declaration time (SPEC.md §3.1) and only resolved once
    # `resolve_all!` (or the per-class `resolve_derivation!`) fires.
    module DerivableInputObject
      class << self
        # @return [Array<Class>] every class that has included this mixin,
        #   in inclusion order. Used by `resolve_all!` to know what to
        #   resolve -- deliberately not `ObjectSpace`-based (slow, fragile).
        def included_classes
          @included_classes ||= []
        end

        def included(base)
          super
          included_classes << base
          base.extend(ClassMethods)
        end

        # SPEC.md §6.3: resolves every pending derivation across every class
        # that has included this mixin. Idempotent -- classes whose
        # derivation was already resolved (or that never called
        # `derive_from`) are left untouched.
        def resolve_all!
          included_classes.each(&:resolve_derivation!)
        end
      end

      # Class-level API mixed into `GraphQL::Schema::InputObject` subclasses.
      module ClassMethods
        # SPEC.md §6.1/§6.2: declares a derivation source and an unevaluated
        # pick block. Validates the source and the at-most-once constraint
        # immediately; the derivation itself is deferred until
        # `resolve_derivation!` fires.
        def derive_from(source, &pick_block)
          check_not_already_derived!
          check_supported_source!(source)

          @derivation_source = source
          @derivation_pick_block = pick_block
        end

        # SPEC.md §6.3: resolves this class's pending derivation, if any.
        # Idempotent -- a second call is a no-op once resolution has
        # happened (or if `derive_from` was never called).
        #
        # @param context [#resolve_sibling_arguments, nil] forwarded to
        #   ArgumentDerivation for Symbol (sibling action) sources. Only the
        #   Rails ControllerConcern (SPEC.md §8) supplies this -- ordinary
        #   InputObjects never use Symbol sources (SPEC.md §11.1), so the
        #   default of nil keeps non-Rails callers unchanged.
        def resolve_derivation!(context: nil)
          return unless defined?(@derivation_pick_block) && @derivation_pick_block

          pre_existing_names = arguments.keys

          derived_arguments = GraphQL::Derivation::ArgumentDerivation.resolve(
            @derivation_source, @derivation_pick_block, context: context,
          )

          check_collisions!(pre_existing_names, derived_arguments)
          derived_arguments.each { |argument| register_derived_argument(argument) }

          @derivation_pick_block = nil
        end

        private

        # Internal escape hatch for the Rails ControllerConcern: its
        # auto-generated InputObjects DO have an action registry (the
        # controller class) to resolve Symbol siblings against, so they opt
        # into Symbol sources by calling this (via `send`, since it's private)
        # before `derive_from`. User-defined DerivableInputObjects have no way
        # to reach this, so §11.1's rejection still applies to them.
        def allow_sibling_sources!
          @allow_sibling_sources = true
        end

        # ArgumentDerivation builds arguments unattached (`owner: nil`) -- it
        # has no way to know which class will register them (SPEC.md §4.4:
        # "the caller registers it on the target InputObject"). graphql-ruby's
        # coercion path, however, calls `owner.validate_directive_argument`
        # during `coerce_input`, so the argument MUST know its owner before it
        # can coerce input. `GraphQL::Schema::Argument#owner` is read-only (set
        # only in the constructor), so attaching here means setting the ivar
        # directly -- a deliberate, scoped exception to "no instance_variable_set
        # on third-party objects", because there is no public setter and
        # rebuilding the argument would drop configured options.
        def register_derived_argument(argument)
          argument.instance_variable_set(:@owner, self)
          add_argument(argument)
        end

        def check_not_already_derived!
          return unless defined?(@derivation_source) && @derivation_source

          raise GraphQL::Derivation::ConfigurationError,
            "derive_from has already been called on #{self}. " \
            'derive_from may be called at most once per class (SPEC.md §6.2).'
        end

        # SPEC.md §11.1: sibling (Symbol) sources have no natural
        # equivalent outside ControllerConcern's action registry --
        # disallow them immediately, the same as §4.1's "any other invalid
        # source" treatment. The ControllerConcern (which DOES have a registry)
        # is exempt via `allow_sibling_sources!`.
        def check_supported_source!(source)
          return unless source.is_a?(Symbol)
          return if defined?(@allow_sibling_sources) && @allow_sibling_sources

          raise ArgumentError,
            "Unsupported DerivableInputObject source: #{source.inspect}. " \
            'Symbol (sibling action) sources are not supported outside ' \
            'ControllerConcern context (SPEC.md §11.1).'
        end

        # SPEC.md §6.2: inline `argument` declarations may coexist with
        # `derive_from`, but if an inline argument names a field also
        # present in the derivation's selections, that is a
        # ConfigurationError raised at resolution time.
        def check_collisions!(pre_existing_names, derived_arguments)
          collisions = derived_arguments.map(&:graphql_name) & pre_existing_names
          return if collisions.empty?

          raise GraphQL::Derivation::ConfigurationError,
            "derive_from on #{self} collides with inline argument(s) already declared: " \
            "#{collisions.inspect}"
        end
      end
    end
  end
end
