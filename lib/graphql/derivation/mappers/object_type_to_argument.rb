# frozen_string_literal: true

module GraphQL
  module Derivation
    module Mappers
      # Maps an ObjectType's candidate fields to argument types per
      # SPEC.md §4.2 (candidate enumeration) and §4.3 (type mapping table).
      #
      # Connection-type fields and List<Object> fields are excluded from the
      # candidate set entirely -- they are never offered to the pick block.
      #
      # Non-connection Object-type fields (e.g. a nested ObjectType) are a
      # special case: they are only eligible if the pick block supplies
      # `pick.override(name, input_type: SomeInputObjectClass)`. Because the
      # override is only known *after* the pick block has run (SPEC.md §4.4's
      # `enumerate_candidates` happens before `pick_block.call(pick)`), this
      # mapper cannot raise immediately when it sees such a field -- it has
      # no way to know yet whether an `input_type:` override is coming.
      #
      # Instead, candidates for nested Object-type fields are represented by
      # `NestedObjectCandidate`, a marker carrying the field's name (for error
      # messages) instead of a resolved `type`. The candidate is still
      # offered to `PickArguments`, so it can be selected like any other
      # field. Resolution of whether the selection is actually legal is
      # deferred to `ArgumentDerivation#build_argument`, which runs after
      # `pick.validate!` and therefore has the final override hash: it checks
      # `NestedObjectCandidate#eligible?(overrides)` and raises
      # `ConfigurationError` if `input_type:` is absent.
      class ObjectTypeToArgument
        # Marker candidate for a nested (non-connection) Object-type field.
        # Not eligible as an argument unless the caller's overrides supply
        # `input_type:`; see ObjectTypeToArgument's class comment for why
        # this check is deferred rather than raised at enumeration time.
        class NestedObjectCandidate
          attr_reader :name

          def initialize(name)
            @name = name
          end

          # True if the given overrides hash (as produced by PickArguments)
          # supplies an explicit `input_type:` for this candidate.
          def eligible?(overrides)
            overrides.key?(:input_type)
          end

          # The resolved argument type, given overrides known to satisfy
          # `eligible?`.
          def resolved_type(overrides)
            overrides.fetch(:input_type)
          end
        end

        # A regular (eagerly-mapped) candidate: scalar, enum, or list
        # thereof. `type` is already the final argument type.
        Candidate = Struct.new(:type)

        def self.candidates(source)
          new(source).candidates
        end

        def initialize(source)
          @source = source
        end

        # Returns `{name => Candidate or NestedObjectCandidate}` for every
        # field eligible to be offered to the pick block (SPEC.md §4.2).
        def candidates
          source.fields.each_with_object({}) do |(_graphql_name, field), result|
            next if excluded?(field)

            name = field.original_name
            result[name] = candidate_for(field, name)
          end
        end

        private

        attr_reader :source

        def excluded?(field)
          type = field.type.unwrap

          connection_type?(type) || list_of_object_type?(field)
        end

        def connection_type?(type)
          return true if type.respond_to?(:graphql_name) && type.graphql_name.to_s.end_with?('Connection')

          type.respond_to?(:ancestors) && type.ancestors.include?(GraphQL::Types::Relay::BaseConnection)
        end

        def list_of_object_type?(field)
          field.type.list? && field.type.unwrap < GraphQL::Schema::Object
        end

        def candidate_for(field, name)
          type = field.type.unwrap

          if type < GraphQL::Schema::Object
            NestedObjectCandidate.new(name)
          else
            Candidate.new(mapped_type(field))
          end
        end

        # Maps a field's return type to an argument type per §4.3's table.
        # Nullability is ignored (handled separately via required:).
        def mapped_type(field)
          type = field.type.unwrap

          field.type.list? ? [type] : type
        end
      end
    end
  end
end
