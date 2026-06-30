# frozen_string_literal: true

require 'graphql/derivation/pick_dsl/fields'
require 'graphql/derivation/mappers/object_type_to_field'

module GraphQL
  module Derivation
    # Implements SPEC.md §5, the Field Derivation Engine. Accepts a source
    # and an unevaluated pick block, and returns an array of configured
    # `GraphQL::Schema::Field` instances (unregistered -- the caller
    # registers them on the destination ObjectType).
    module FieldDerivation
      module_function

      # @param source [Class] An ObjectType class (`< GraphQL::Schema::
      #   Object`) or an ActiveRecord model class (`< ActiveRecord::Base`,
      #   SPEC.md §5.1/§9 -- requires `graphql/derivation/rails/active_record`).
      # @param pick_block [Proc] Called with a `PickFields` instance.
      # @return [Array<GraphQL::Schema::Field>]
      def resolve(source, pick_block)
        candidates = enumerate_candidates(source)

        pick = PickDsl::PickFields.new(candidates.keys)
        pick_block.call(pick)
        pick.validate!

        pick.selections.map do |name, overrides|
          candidate = candidates.fetch(name)
          check_resolver!(name, candidate, overrides)
          build_field(candidate, overrides)
        end
      end

      # SPEC.md §5.1/§5.2: dispatches to the appropriate mapper based on the
      # source's type. AR-model sources are detected without referencing
      # `ActiveRecord` unless it is already loaded (core must load/run with
      # neither Rails nor ActiveRecord present -- AGENTS.md). Any other
      # source raises `ArgumentError` immediately (i.e. at declaration time).
      def enumerate_candidates(source)
        if object_type_source?(source)
          Mappers::ObjectTypeToField.candidates(source)
        elsif active_record_source?(source)
          active_record_candidates(source)
        else
          raise_unsupported_source_error(source)
        end
      end

      def object_type_source?(source)
        source.is_a?(Class) && source < GraphQL::Schema::Object
      end

      # Safe even when ActiveRecord is not loaded: `defined?` short-circuits
      # before `source < ActiveRecord::Base` is ever evaluated.
      def active_record_source?(source)
        source.is_a?(Class) && defined?(ActiveRecord::Base) && source < ActiveRecord::Base
      end

      # SPEC.md §5.1/§5.2/§9: dispatches AR-model sources to the
      # ActiveRecord adapter. Only reachable once `graphql/derivation/rails/
      # active_record` has been required -- `active_record_source?` already
      # guards on `ActiveRecord::Base` being defined, but core itself never
      # requires the adapter file, so if a host app loads ActiveRecord
      # without opting into this gem's AR integration, surface a clear error
      # instead of a bare NameError on the adapter constant.
      def active_record_candidates(source)
        unless defined?(GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper)
          raise_active_record_adapter_not_loaded_error(source)
        end

        GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper.candidates(source)
      end

      def raise_active_record_adapter_not_loaded_error(source)
        raise NotImplementedError,
          "ActiveRecord source #{source.inspect} requires the ActiveRecord adapter " \
          "(SPEC.md §9), which has not been loaded. Add `require 'graphql/derivation/rails/" \
          "active_record'` to opt in."
      end

      def raise_unsupported_source_error(source)
        raise ArgumentError,
          "Unsupported FieldDerivation source: #{source.inspect}. " \
          'Expected an ObjectType class (`< GraphQL::Schema::Object`).'
      end

      # SPEC.md §5.4's `check_resolver!` step. Raises `UnresolvableFieldError`
      # for an unresolved Case 3 (custom class resolver) candidate unless
      # the pick block's override supplies an explicit `method:` or
      # `resolver:`. AR-model candidates (SPEC.md §9) have no resolver case
      # at all -- columns always resolve via the default method resolver --
      # so this is a no-op for them.
      def check_resolver!(name, candidate, overrides)
        return unless candidate.respond_to?(:resolver_case)
        return unless candidate.resolver_case == :custom_resolver
        return if overrides.key?(:method) || overrides.key?(:resolver)

        raise GraphQL::Derivation::UnresolvableFieldError,
          "#{name.inspect} resolves via a custom class resolver method on " \
          "#{candidate.field.owner.inspect} and cannot be copied without an explicit " \
          'pick.override(name, method: ...) or pick.override(name, resolver: ...)'
      end

      # SPEC.md §5.4's `build_field` step: merges the candidate's own
      # resolver option (Case 2's `method:`, if any) with the pick block's
      # overrides, then constructs an unregistered `GraphQL::Schema::Field`.
      #
      # `resolver:` (SPEC.md §5.3's example: `pick.override(:full_name,
      # resolver: ->(obj, args, ctx) { ... })`) is not itself a
      # `GraphQL::Schema::Field.new` keyword -- graphql-ruby has no kwarg
      # that accepts an arbitrary resolver Proc directly (`resolve_static:`/
      # `resolve_batch:`/etc. all dispatch via `public_send` to a *method
      # name*, not a Proc). To honor the override exactly as documented, we
      # build the field without `resolver:` and then define a singleton
      # `#resolve` on the instance that calls the Proc, matching the
      # `#resolve(object, args, query_ctx)` signature `GraphQL::Schema::
      # Field` itself uses.
      def build_field(candidate, overrides)
        resolver = overrides[:resolver]
        opts = candidate_opts(candidate).merge(overrides.except(:resolver))

        field = GraphQL::Schema::Field.new(name: candidate.name, type: candidate.type, owner: nil, **opts)
        attach_resolver!(field, resolver) if resolver
        field
      end

      def attach_resolver!(field, resolver)
        field.define_singleton_method(:resolve) do |object, args, query_ctx|
          resolver.call(object.object, args, query_ctx)
        end
      end

      # Case 2 candidates carry their source `method:` forward by default,
      # so a destination type whose underlying object also responds to
      # that method needs no override. AR-model candidates (SPEC.md §9.3)
      # carry their NOT-NULL-derived `null:` default forward the same way.
      # The pick block's overrides (merged afterwards in `build_field`)
      # take precedence over either default.
      def candidate_opts(candidate)
        opts = {}
        if candidate.respond_to?(:resolver_case) && candidate.resolver_case == :method
          opts[:method] = candidate.method_override
        end
        opts[:null] = candidate.null if candidate.respond_to?(:null)

        opts
      end

      private_class_method :object_type_source?,
        :active_record_source?,
        :active_record_candidates,
        :raise_active_record_adapter_not_loaded_error,
        :raise_unsupported_source_error,
        :check_resolver!,
        :build_field,
        :attach_resolver!,
        :candidate_opts
    end
  end
end
