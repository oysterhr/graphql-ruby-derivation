# frozen_string_literal: true

require 'graphql/derivation/engines/field_derivation'

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
        # happened (or if `derive_from` was never called).
        def resolve_derivation!
          return unless defined?(@derivation_pick_block) && @derivation_pick_block

          pre_existing_names = fields.keys

          derived_fields = GraphQL::Derivation::FieldDerivation.resolve(
            @derivation_source, @derivation_pick_block,
          )

          check_collisions!(pre_existing_names, derived_fields)
          derived_fields.each { |field| add_field(field) }

          @derivation_pick_block = nil
        end

        private

        def check_not_already_derived!
          return unless defined?(@derivation_source) && @derivation_source

          raise GraphQL::Derivation::ConfigurationError,
            "derive_from has already been called on #{self}. " \
            'derive_from may be called at most once per class (SPEC.md §7.2).'
        end

        # SPEC.md §7.2: inline `field` declarations may coexist with
        # `derive_from`, but if an inline field names a field also present
        # in the derivation's selections, that is a ConfigurationError
        # raised at resolution time.
        def check_collisions!(pre_existing_names, derived_fields)
          collisions = derived_fields.map(&:graphql_name) & pre_existing_names
          return if collisions.empty?

          raise GraphQL::Derivation::ConfigurationError,
            "derive_from on #{self} collides with inline field(s) already declared: " \
            "#{collisions.inspect}"
        end
      end
    end
  end
end
