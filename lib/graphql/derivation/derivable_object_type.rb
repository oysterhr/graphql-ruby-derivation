# frozen_string_literal: true

require 'graphql/derivation/engines/field_derivation'
require 'graphql/derivation/derivation_resolution_guard'

module GraphQL
  module Derivation
    # Implements SPEC.md §7, a mixin for `GraphQL::Schema::Object`
    # subclasses that adds `derive_from`. The derivation is stored
    # unevaluated at declaration time (SPEC.md §3.1) and only resolved once
    # `resolve_all!` (or the per-class `resolve_derivation!`) fires.
    module DerivableObjectType
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

        # SPEC.md §7.3: resolves every pending derivation across every class
        # that has included this mixin. Idempotent -- classes whose
        # derivation was already resolved (or that never called
        # `derive_from`) are left untouched.
        def resolve_all!
          included_classes.each(&:resolve_derivation!)
        end

        # Reload-safety seam (not part of the ordinary runtime API): forgets
        # every class registered via the `included` hook. See
        # `DerivableInputObject.clear!` for the full rationale (identical
        # leak shape, mirrored here for `DerivableObjectType`). Called from
        # `GraphQL::Derivation::Rails.reset_for_reload!`.
        def clear!
          @included_classes = []
        end
      end

      # Class-level API mixed into `GraphQL::Schema::Object` subclasses.
      module ClassMethods
        # SPEC.md §7.1/§7.2: declares a derivation source and an unevaluated
        # pick block. Validates the at-most-once constraint immediately; the
        # derivation itself is deferred until `resolve_derivation!` fires.
        # Unlike `DerivableInputObject`, §7 has no Symbol-source exclusion --
        # source validation is left entirely to `FieldDerivation` at
        # resolution time.
        def derive_from(source, &pick_block)
          check_not_already_derived!

          @derivation_source = source
          @derivation_pick_block = pick_block
        end

        # SPEC.md §7.3: resolves this class's pending derivation, if any.
        # Idempotent -- a second call is a no-op once resolution has
        # happened (or if `derive_from` was never called). The early-return
        # check above happens BEFORE the cycle guard is engaged, so
        # resolving an already-finished dependency never touches the
        # in-progress stack -- only a derivation that is genuinely being
        # computed right now participates in cycle detection.
        #
        # If `@derivation_source` is itself Derivable (i.e. responds to
        # `resolve_derivation!` -- another `DerivableObjectType` or
        # `DerivableInputObject` class), its own derivation is resolved
        # FIRST, recursively, before `FieldDerivation.resolve` reads its
        # `.fields`. This makes resolution order-independent: a source
        # always finishes resolving before its dependent does, regardless of
        # which class happened to be included/declared first. Both this
        # recursive call and this class's own resolution are wrapped in
        # `DerivationResolutionGuard.guard`, which shares its in-progress
        # stack with `DerivableInputObject` -- so a cycle is caught even if
        # it crosses both mixins.
        #
        # @param context [#resolve_sibling_arguments, nil] `FieldDerivation`
        #   itself never consults `context:` -- SPEC.md §5.1 has no Symbol
        #   source for ObjectTypes -- but a Derivable *source* reached via
        #   `derive_from` might itself be a `DerivableInputObject` with a
        #   pending Symbol-sourced derivation (unusual, but not forbidden by
        #   the Appendix's direction rules), so `context:` is accepted here
        #   purely to forward to that recursive call. Defaults to nil, so
        #   ordinary (non-Rails) callers are unaffected.
        def resolve_derivation!(context: nil)
          return unless defined?(@derivation_pick_block) && @derivation_pick_block

          @resolving_derivation = true
          GraphQL::Derivation::DerivationResolutionGuard.guard(self) { resolve_pending_derivation!(context) }
        ensure
          @resolving_derivation = false
        end

        # graphql-ruby reads `.fields` whenever it builds the schema, runs
        # introspection, dumps the SDL, or resolves a selection. Resolving a
        # pending `derive_from` here means the derivation is applied the first
        # time the class is actually used -- the "resolves lazily on first use"
        # behaviour that USAGE.CAVEKIT.md's "Resolution timing" already
        # promises. So a consumer no longer has to call `resolve_all!` (or hook
        # every `Schema.execute`) for derived fields to appear in the schema.
        # `resolve_all!` still works as an eager warm-up (e.g. a Rails
        # `to_prepare`), it is just no longer required for correctness.
        def fields(*args)
          resolve_derivation_lazily!
          super
        end

        private

        # First-use trigger behind `fields`, guarded twice so it stays safe:
        #   * `@resolving_derivation` -- `resolve_pending_derivation!` itself
        #     reads `fields.keys` (the pre-existing names) mid-resolution.
        #     Without this guard that read would re-enter resolution, and the
        #     cycle guard would wrongly flag the class as a self-cycle.
        #   * `@derivation_resolution_attempted` -- a resolution that already
        #     ran (or already raised, e.g. an inline/derived collision) is never
        #     retried from the `fields` path. A misconfigured class therefore
        #     behaves exactly as it did under explicit `resolve_derivation!`:
        #     the error surfaces once, and later `.fields` reads return whatever
        #     was registered rather than re-raising on every access.
        def resolve_derivation_lazily!
          return if @resolving_derivation
          return if @derivation_resolution_attempted

          resolve_derivation!
        end

        # The guarded body of `resolve_derivation!`, split out so the public
        # method itself stays a short guard-then-delegate wrapper.
        def resolve_pending_derivation!(context)
          @derivation_resolution_attempted = true

          resolve_source_derivation!(context)

          pre_existing_names = fields.keys

          derived_fields = GraphQL::Derivation::FieldDerivation.resolve(
            @derivation_source, @derivation_pick_block,
          )

          check_collisions!(pre_existing_names, derived_fields)
          derived_fields.each { |field| add_field(field) }

          @derivation_pick_block = nil
        end

        # Ensures `@derivation_source`'s own derivation (if it is Derivable)
        # has resolved before this class reads its `.fields`. Runs BEFORE
        # `FieldDerivation.resolve` is called, from inside the cycle guard,
        # so a source that is mid-resolution (a true cycle) raises
        # `CyclicDependencyError` from `DerivationResolutionGuard.guard`
        # instead of this class silently reading the source's
        # not-yet-registered (i.e. empty) fields.
        def resolve_source_derivation!(context)
          return unless @derivation_source.respond_to?(:resolve_derivation!)

          @derivation_source.resolve_derivation!(context: context)
        end

        # PR #13 review (khamusa) questioned whether this restriction should
        # be relaxed, mirroring the same question raised on
        # DerivableInputObject (PR #11). Deliberately deferred, for the same
        # reason: SPEC.md §7.2 states derive_from may be called at most once
        # per class, and relaxing that is a spec-level behavior change that
        # needs a real use case, not something to slip in as a
        # message-quality fix. Only the error message below was improved.
        def check_not_already_derived!
          return unless defined?(@derivation_source) && @derivation_source

          raise GraphQL::Derivation::ConfigurationError,
            "#{self} already called derive_from(#{@derivation_source.inspect}). " \
            'derive_from may be called at most once per class (SPEC.md §7.2) -- remove the ' \
            'duplicate call, or fold any extra fields into the existing derive_from block ' \
            '(or into inline `field` declarations alongside it).'
        end

        # SPEC.md §7.2: inline `field` declarations may coexist with
        # `derive_from`, but if an inline field names a field also present
        # in the derivation's selections, that is a ConfigurationError
        # raised at resolution time.
        def check_collisions!(pre_existing_names, derived_fields)
          collisions = derived_fields.map(&:graphql_name) & pre_existing_names
          return if collisions.empty?

          names = collisions.sort.join(', ')
          raise GraphQL::Derivation::ConfigurationError,
            "#{self} already defines #{collisions.size == 1 ? 'a field' : 'fields'} named " \
            "#{names} inline, so derive_from(#{@derivation_source.inspect}) cannot also derive " \
            "#{collisions.size == 1 ? 'a field' : 'fields'} with that name. Remove the inline " \
            'declaration, or exclude that name from the derive_from pick block.'
        end
      end
    end
  end
end
