# frozen_string_literal: true

require 'graphql/derivation/engines/argument_derivation'
require 'graphql/derivation/derivation_resolution_guard'

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
        # happened (or if `derive_from` was never called). The early-return
        # check above happens BEFORE the cycle guard is engaged, so
        # resolving an already-finished dependency never touches the
        # in-progress stack -- only a derivation that is genuinely being
        # computed right now participates in cycle detection.
        #
        # If `@derivation_source` is itself Derivable (i.e. responds to
        # `resolve_derivation!` -- another `DerivableInputObject` or
        # `DerivableObjectType` class), its own derivation is resolved
        # FIRST, recursively, before `ArgumentDerivation.resolve` reads its
        # `.arguments`. This makes resolution order-independent: a source
        # always finishes resolving before its dependent does, regardless of
        # which class happened to be included/declared first. Both this
        # recursive call and this class's own resolution are wrapped in
        # `DerivationResolutionGuard.guard`, which shares its in-progress
        # stack with `DerivableObjectType` -- so a cycle is caught even if it
        # crosses both mixins (e.g. an ArgumentDerivation ObjectType-source
        # that is itself a pending DerivableObjectType).
        #
        # @param context [#resolve_sibling_arguments, nil] forwarded to
        #   ArgumentDerivation for Symbol (sibling action) sources. Only the
        #   Rails ControllerConcern (SPEC.md §8) supplies this -- ordinary
        #   InputObjects never use Symbol sources (SPEC.md §11.1), so the
        #   default of nil keeps non-Rails callers unchanged. Also forwarded
        #   to a Derivable source's own recursive `resolve_derivation!` call,
        #   in case that source is itself part of the same Rails-generated,
        #   context-carrying chain -- harmless (defaults to nil) for the
        #   ordinary ObjectType/InputObject-source case.
        def resolve_derivation!(context: nil)
          return unless defined?(@derivation_pick_block) && @derivation_pick_block

          GraphQL::Derivation::DerivationResolutionGuard.guard(self) { resolve_pending_derivation!(context) }
        end

        private

        # The guarded body of `resolve_derivation!`, split out so the public
        # method itself stays a short guard-then-delegate wrapper.
        def resolve_pending_derivation!(context)
          resolve_source_derivation!(context)

          pre_existing_names = arguments.keys

          derived_arguments = GraphQL::Derivation::ArgumentDerivation.resolve(
            @derivation_source, @derivation_pick_block, context: context,
          )

          check_collisions!(pre_existing_names, derived_arguments)
          derived_arguments.each { |argument| register_derived_argument(argument) }

          @derivation_pick_block = nil
        end

        # Ensures `@derivation_source`'s own derivation (if it is Derivable)
        # has resolved before this class reads its `.arguments`. Runs BEFORE
        # `ArgumentDerivation.resolve` is called, from inside the cycle
        # guard, so a source that is mid-resolution (a true cycle) raises
        # `CyclicDependencyError` from `DerivationResolutionGuard.guard`
        # instead of this class silently reading the source's
        # not-yet-registered (i.e. empty) arguments.
        def resolve_source_derivation!(context)
          return unless @derivation_source.respond_to?(:resolve_derivation!)

          @derivation_source.resolve_derivation!(context: context)
        end

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

        # PR #11 review (khamusa) questioned whether this restriction should
        # be relaxed -- e.g. to allow re-opening a class and calling
        # `derive_from` again before resolution has happened, since reopening
        # classes is common in Ruby. Deliberately deferred: SPEC.md §6.2
        # states derive_from may be called at most once per class, and
        # relaxing that is a spec-level behavior change that needs a real
        # use case, not something to slip in as a message-quality fix. Only
        # the error message below was improved.
        def check_not_already_derived!
          return unless defined?(@derivation_source) && @derivation_source

          raise GraphQL::Derivation::ConfigurationError,
            "#{self} already called derive_from(#{@derivation_source.inspect}). " \
            'derive_from may be called at most once per class (SPEC.md §6.2) -- remove the ' \
            'duplicate call, or fold any extra fields into the existing derive_from block ' \
            '(or into inline `argument` declarations alongside it).'
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
