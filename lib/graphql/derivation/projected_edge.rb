# frozen_string_literal: true

module GraphQL
  module Derivation
    # The return type given to a derived field whose source field returns an
    # Object, Interface or Union type (an "edge"). It is a
    # `GraphQL::Schema::LateBoundType`: graphql-ruby resolves it by GraphQL
    # name against the types of whichever schema the derived type is added
    # to, during `Schema.add_type_and_traverse` (i.e. at schema definition
    # time, not at query time).
    #
    # This is what lets a derived type ("projection") pick an edge without
    # naming the target type: `Expense.account` on a surface
    # schema resolves to *that schema's* `Account`, whatever class that
    # is -- a projection of the canonical type, or a legacy type still
    # mounted during a transition. If the schema has no type of that name at
    # all, graphql-ruby raises `UnresolvedLateBoundTypeError` while the
    # schema is being defined; `ProjectionSchema` turns that into a
    # `MissingProjectionError` that names this edge.
    #
    # The subclass exists only to remember where the edge came from, so that
    # error messages can point at the derived field, the source field and the
    # canonical type. graphql-ruby itself only reads `name`.
    class ProjectedEdge < GraphQL::Schema::LateBoundType
      # @return [Class, Module] the source field's (unwrapped) return type
      attr_reader :canonical_type
      # @return [GraphQL::Schema::Field] the field on the derivation source
      attr_reader :source_field
      # @return [Class, nil] the derived type the edge was created for
      attr_reader :destination

      def initialize(canonical_type, source_field:, destination: nil)
        super(canonical_type.graphql_name)
        @canonical_type = canonical_type
        @source_field = source_field
        @destination = destination
      end

      # "Expense.account" -- the derived field, as a GraphQL path.
      def derived_field_path
        "#{destination_name}.#{source_field.graphql_name}"
      end

      def destination_name
        return 'an anonymous projection' if destination.nil?

        destination.name || destination.graphql_name
      end

      # "Billing::Contracts::ExpenseType#account" -- the source
      # field, as Ruby. Anonymous source types (e.g. generated collection
      # types) are named by their GraphQL name instead of `#<Class:0x...>`.
      def source_field_path
        owner = source_field.owner
        "#{owner.name || owner.graphql_name}##{source_field.original_name}"
      end

      def inspect
        "#<#{self.class.name} #{name} for #{derived_field_path} " \
          "(#{source_field_path} returns #{canonical_type.inspect})>"
      end
    end
  end
end
