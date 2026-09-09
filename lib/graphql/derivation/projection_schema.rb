# frozen_string_literal: true

require 'graphql/derivation/projected_edge'

module GraphQL
  module Derivation
    # `extend` this onto a `GraphQL::Schema` subclass that mounts derived
    # types ("projections"). It adds nothing at query time. It only makes two
    # definition-time failures explicit, so they surface at boot with a
    # message that says what to do:
    #
    # 1. An edge picked by a projection has no type of that name in this
    #    schema. graphql-ruby raises `UnresolvedLateBoundTypeError` with just
    #    the type name; this re-raises it as `MissingProjectionError` naming
    #    the derived field, the source field and the canonical type.
    #
    # 2. Two different classes share one GraphQL name in this schema (for
    #    example a legacy type and its projection, both called
    #    `Expense`). graphql-ruby stores both and only raises
    #    `DuplicateNamesError` later, when something asks for the type. This
    #    raises `DuplicateTypeNameError` as soon as the second one is added,
    #    listing which fields reach each class, so the swap can be completed
    #    in one change.
    #
    #   class Mobile::Schema < GraphQL::Schema
    #     extend GraphQL::Derivation::ProjectionSchema
    #     query Mobile::Types::QueryType
    #   end
    module ProjectionSchema
      def add_type_and_traverse(types, root:)
        super
        check_duplicate_type_names!
      rescue GraphQL::Schema::UnresolvedLateBoundTypeError => e
        raise e unless e.type.is_a?(ProjectedEdge)

        raise MissingProjectionError.new(e.type, schema: self)
      end

      private

      def check_duplicate_type_names!
        # graphql-ruby keeps an Array under a name only when distinct classes
        # were registered for it (it de-duplicates re-visits of one class).
        own_types.each do |name, entry|
          raise DuplicateTypeNameError.new(name, entry, schema: self) if entry.is_a?(Array)
        end
      end
    end

    # Raised by `ProjectionSchema` when a `ProjectedEdge` finds no type of
    # its name in the schema being defined.
    class MissingProjectionError < ConfigurationError
      attr_reader :edge, :schema

      def initialize(edge, schema:)
        @edge = edge
        @schema = schema
        super(build_message)
      end

      private

      def build_message
        "#{schema_name} has no type named \"#{edge.name}\", but #{edge.derived_field_path} needs one: " \
          "it is derived from #{edge.source_field_path}, which returns #{canonical}.\n#{ways_out}"
      end

      def ways_out
        "Either add a projection of #{canonical} named \"#{edge.name}\" to #{schema_name} " \
          '(a class deriving from it, reachable from a root field or listed in `orphan_types`), ' \
          'or, inside the pick block, point the edge at an explicit type with ' \
          "`pick.override(:#{picked_name}, type: SomeType)`, " \
          "or expose the source type as-is with `pick.expose_full(:#{picked_name})`."
      end

      def picked_name
        edge.source_field.original_name
      end

      def canonical
        edge.canonical_type.inspect
      end

      def schema_name
        schema.name || schema.inspect
      end
    end

    # Raised by `ProjectionSchema` when two distinct classes are added to
    # one schema under the same GraphQL name.
    class DuplicateTypeNameError < ConfigurationError
      attr_reader :type_name, :classes, :schema

      def initialize(type_name, classes, schema:)
        @type_name = type_name
        @classes = classes
        @schema = schema
        super(build_message)
      end

      private

      def build_message
        details = classes.map { |klass| "  - #{klass.inspect}#{referenced_by(klass)}" }.join("\n")
        <<~MSG.strip
          #{schema_name} has #{classes.size} different types named "#{type_name}":
          #{details}
          One GraphQL name maps to one class per schema. Remove one of them, or make every field \
          that returns "#{type_name}" in this schema return the same class.
        MSG
      end

      def referenced_by(klass)
        refs = schema.references_to(klass)
        return ' (root or orphan type)' if refs.nil? || refs.empty?

        " (returned by #{refs.map(&:path).sort.join(', ')})"
      end

      def schema_name
        schema.name || schema.inspect
      end
    end
  end
end
