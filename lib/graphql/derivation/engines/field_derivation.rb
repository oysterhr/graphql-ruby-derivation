# frozen_string_literal: true

require 'graphql/derivation/pick_dsl/fields'
require 'graphql/derivation/mappers/object_type_to_field'
require 'graphql/derivation/projected_edge'
require 'graphql/derivation/source_resolver_extension'

module GraphQL
  module Derivation
    # Implements SPEC.md §5, the Field Derivation Engine. Accepts a source
    # and an unevaluated pick block, and returns an array of configured
    # `GraphQL::Schema::Field` instances (unregistered -- the caller
    # registers them on the destination ObjectType).
    module FieldDerivation
      # Extension classes graphql-ruby adds to fields on its own (from
      # `connection:`/`scope:` settings). They are re-created by the copy's
      # own settings, so copying them across would double them up.
      BUILT_IN_EXTENSIONS = [
        GraphQL::Schema::Field::ConnectionExtension,
        GraphQL::Schema::Field::ScopeExtension,
      ].freeze

      module_function

      # @param source [Class] An ObjectType class (`< GraphQL::Schema::
      #   Object`) or an ActiveRecord model class (`< ActiveRecord::Base`,
      #   SPEC.md §5.1/§9 -- requires `graphql/derivation/rails/active_record`).
      # @param pick_block [Proc] Called with a `PickFields` instance.
      # @param destination [Class, nil] The ObjectType the fields are being
      #   derived for. Used to build fields with its `field_class`, to base
      #   nested projections on its superclass, and for error messages.
      # @return [Array<GraphQL::Schema::Field>]
      def resolve(source, pick_block, destination: nil)
        candidates = enumerate_candidates(source)

        pick = PickDsl::PickFields.new(candidates.keys, source_name: source_name(source))
        pick_block.call(pick)
        pick.validate!

        pick.selections.map do |name, overrides|
          candidate = candidates.fetch(name)
          check_resolver!(name, candidate, overrides)
          build_field(candidate, overrides, pick.projections[name], destination)
        end
      end

      # SPEC.md §5.1/§5.2: dispatches to the appropriate mapper based on the
      # source's type. AR-model sources are detected without referencing
      # `ActiveRecord` unless it is already loaded (core must load/run with
      # neither Rails nor ActiveRecord present -- AGENTS.md). Any other
      # source raises `ArgumentError` immediately, as soon as `.resolve` runs.
      # Note this is at *resolution* time for `DerivableObjectType#derive_from`
      # sources (SPEC.md §3.1: the source/pick block are stored unevaluated
      # at declaration time and only checked once resolution fires) -- not at
      # `derive_from`'s own declaration-time call, which does no source-type
      # validation of its own.
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

      # A human-readable identifier for +source+, used only for error
      # messages raised by the Pick DSL (e.g. "unknown field" errors). Named
      # classes use their name; anonymous classes (common in specs, e.g.
      # `Class.new(GraphQL::Schema::Object) { ... }`) fall back to their
      # graphql_name (if the source responds to it) or `#inspect`, since
      # `Class#name` is nil for them.
      def source_name(source)
        # `graphql_name` is declared via `respond_to?` on every GraphQL::Schema
        # member, but calling it raises `RequiredImplementationMissingError`
        # for anonymous types that never set one -- rescue so the `#inspect`
        # fallback below is actually reachable in that case.
        source.name || begin
          source.graphql_name if source.respond_to?(:graphql_name)
        rescue GraphQL::RequiredImplementationMissingError
          nil
        end || source.inspect
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
      # overrides, works out the copy's return type (see `derived_type`),
      # then constructs an unregistered field owned by the destination (so
      # `field.path` and graphql-ruby's own error messages name the derived
      # type) using the destination's `field_class` (so host-app field
      # subclasses -- custom options, argument classes -- apply to derived
      # fields exactly as to inline ones).
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
      def build_field(candidate, overrides, nested_block, destination)
        resolver = overrides[:resolver]
        opts = candidate_opts(candidate).merge(overrides.except(:resolver, :type, :expose_full))
        type = derived_type(candidate, overrides, nested_block, destination)

        field = field_class_for(destination).new(name: candidate.name, type: type, owner: destination, **opts)
        copy_definition!(field, candidate)
        attach_source_resolver!(field, candidate) if source_resolver?(candidate, overrides)
        attach_resolver!(field, resolver) if resolver
        field
      end

      def field_class_for(destination)
        destination.respond_to?(:field_class) ? destination.field_class : GraphQL::Schema::Field
      end

      # The copy's return type, keeping the source's List/NonNull wrapping
      # and substituting the innermost type as follows (first match wins):
      #
      #   1. `type:` override            -> exactly that type
      #   2. `pick.project` block        -> a new anonymous derived type
      #   3. `expose_full:` override     -> the source type, unchanged
      #   4. Object/Interface/Union type -> `ProjectedEdge` (late-bound by
      #                                     GraphQL name, resolved per schema)
      #   5. anything else (leaf types)  -> the source type, unchanged
      #
      # AR-model candidates carry a fully built leaf type and never hit 2-4.
      def derived_type(candidate, overrides, nested_block, destination)
        return candidate.type unless candidate.respond_to?(:field)

        rewrap(candidate.type, replacement_type(candidate, overrides, nested_block, destination))
      end

      def replacement_type(candidate, overrides, nested_block, destination)
        unwrapped = candidate.type.unwrap
        if overrides.key?(:type)
          overrides[:type]
        elsif nested_block
          build_nested_projection(unwrapped, nested_block, candidate, destination)
        elsif overrides[:expose_full] || !edge_type?(unwrapped)
          unwrapped
        else
          ProjectedEdge.new(unwrapped, source_field: candidate.field, destination: destination)
        end
      end

      def edge_type?(type)
        return false unless type.respond_to?(:kind)

        kind = type.kind
        kind.object? || kind.interface? || kind.union?
      end

      # Re-applies +wrapped+'s List/NonNull layers around +inner+.
      def rewrap(wrapped, inner)
        case wrapped
        when GraphQL::Schema::NonNull
          rewrap(wrapped.of_type, inner).to_non_null_type
        when GraphQL::Schema::List
          rewrap(wrapped.of_type, inner).to_list_type
        else
          inner
        end
      end

      # `pick.project name do |nested| ... end`: builds an anonymous
      # `DerivableObjectType` deriving from the source field's own return
      # type, under the same GraphQL name, so the nested type never has to be
      # referenced by constant from the destination's side. It is based on
      # the destination's superclass so it shares the destination's
      # `field_class` and any other base behaviour, and its own edges follow
      # the same rules recursively.
      def build_nested_projection(canonical, nested_block, candidate, destination)
        check_projectable!(canonical, candidate, destination)

        base = destination.nil? ? GraphQL::Schema::Object : destination.superclass
        Class.new(base) do
          include GraphQL::Derivation::DerivableObjectType unless include?(GraphQL::Derivation::DerivableObjectType)

          graphql_name canonical.graphql_name
          description canonical.description if canonical.description
          derive_from(canonical, &nested_block)
        end
      end

      def check_projectable!(canonical, candidate, destination)
        return if canonical.is_a?(Class) && canonical < GraphQL::Schema::Object

        raise GraphQL::Derivation::ConfigurationError,
          "Cannot pick.project(#{candidate.name.inspect}) on #{destination_name(destination)}: " \
          "#{candidate.field.owner.inspect}##{candidate.name} returns #{canonical.inspect}, " \
          'and only Object types can be projected inline. Interfaces, unions and late-bound ' \
          'types need their own projection in the schema (or pick.override(name, type: ...)).'
      end

      def destination_name(destination)
        return 'an anonymous projection' if destination.nil?

        destination.name || destination.graphql_name
      end

      # Everything about the source field that is part of its definition
      # (not its type or resolver) and that `GraphQL::Schema::Field.new`
      # cannot take as a plain option: arguments, extras and custom
      # extensions. Without this, a copied field with arguments would reject
      # every query that passes them.
      def copy_definition!(field, candidate)
        return unless candidate.respond_to?(:field)

        source_field = candidate.field
        source_field.all_argument_definitions.each { |arg| field.add_argument(arg) }
        field.extras(source_field.extras) unless source_field.extras.empty?
        copy_extensions!(field, source_field)
      end

      def copy_extensions!(field, source_field)
        source_field.extensions.each do |ext|
          next if BUILT_IN_EXTENSIONS.include?(ext.class)

          field.extension(ext.class, **ext.options)
        end
      end

      # Case 4 (SPEC.md §5.3): the source type defines an instance method
      # for this field, and the pick block did not replace it.
      def source_resolver?(candidate, overrides)
        candidate.respond_to?(:resolver_case) &&
          candidate.resolver_case == :instance_method &&
          !overrides.key?(:method) && !overrides.key?(:resolver)
      end

      def attach_source_resolver!(field, candidate)
        field.extension(SourceResolverExtension, source: candidate.field.owner)
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
      # ObjectType candidates also carry the source field's description,
      # deprecation reason and explicit `connection:` setting. The pick
      # block's overrides (merged afterwards in `build_field`) take
      # precedence over any of these.
      def candidate_opts(candidate)
        opts = {}
        if candidate.respond_to?(:resolver_case) && candidate.resolver_case == :method
          opts[:method] = candidate.method_override
        end
        opts[:null] = candidate.null if candidate.respond_to?(:null)
        opts.merge!(source_field_opts(candidate.field)) if candidate.respond_to?(:field)

        opts
      end

      def source_field_opts(source_field)
        opts = {}
        opts[:description] = source_field.description if source_field.description
        opts[:deprecation_reason] = source_field.deprecation_reason if source_field.deprecation_reason
        # graphql-ruby guesses `connection:` from the return type's *name*
        # (`...Connection`); a source field that overrode the guess must keep
        # its answer, or a copy returning e.g. `SyncConnection` would grow
        # Relay pagination arguments.
        opts[:connection] = source_field.connection?
        # Likewise `scope:` defaults from the *shape* of the type expression
        # (an Array literal means a list) -- the copy receives a built type
        # object, so it has to be told explicitly.
        opts[:scope] = source_field.scoped?
        opts
      end

      private_class_method :object_type_source?,
        :active_record_source?,
        :active_record_candidates,
        :raise_active_record_adapter_not_loaded_error,
        :raise_unsupported_source_error,
        :source_name,
        :check_resolver!,
        :build_field,
        :field_class_for,
        :derived_type,
        :replacement_type,
        :edge_type?,
        :rewrap,
        :build_nested_projection,
        :check_projectable!,
        :destination_name,
        :copy_definition!,
        :copy_extensions!,
        :source_resolver?,
        :attach_source_resolver!,
        :attach_resolver!,
        :candidate_opts,
        :source_field_opts
    end
  end
end
