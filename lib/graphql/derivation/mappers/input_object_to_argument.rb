# frozen_string_literal: true

module GraphQL
  module Derivation
    module Mappers
      # Maps an InputObject's arguments to argument candidates per SPEC.md
      # §4.2 ("InputObject source"). The mapping is an identity map: every
      # argument is a candidate (no exclusions), and the argument's type is
      # reused directly.
      #
      # Also used, unchanged, for Mutation-class sources (SPEC.md §4.2
      # "Mutation source"): a `GraphQL::Schema::Mutation` subclass exposes
      # `.arguments` in the exact same shape as an InputObject (both extend
      # `GraphQL::Schema::Member::HasArguments`), so `ArgumentDerivation`
      # routes both source types here rather than duplicating this mapper.
      class InputObjectToArgument
        # A regular candidate carrying an already-resolved type, plus the
        # source `GraphQL::Schema::Argument` itself. `type` keeps this
        # struct's shape aligned with ObjectTypeToArgument::Candidate so
        # ArgumentDerivation can treat both mappers' candidates uniformly;
        # `argument` is the extra piece InputObject/Mutation sources carry
        # that a plain ObjectType field candidate does not -- it lets
        # ArgumentDerivation#build_argument copy the source argument's own
        # option metadata (`prepare:`, `description:`, ...) across the
        # derivation instead of dropping everything but the type (SPEC.md
        # §4.4).
        Candidate = Struct.new(:type, :argument)

        def self.candidates(source)
          new(source).candidates
        end

        def initialize(source)
          @source = source
        end

        # Returns `{name => Candidate}` for every argument on the source
        # InputObject, including inherited arguments.
        def candidates
          source.arguments.each_with_object({}) do |(_graphql_name, argument), result|
            # `required:` (passed separately by ArgumentDerivation, driven by
            # the pick block) controls the derived argument's nullability, so
            # the source argument's own NonNull wrapper -- if any -- must not
            # leak through; only the unwrapped (and re-listed, if a list)
            # type is reused.
            type = argument.type.list? ? [argument.type.unwrap] : argument.type.unwrap
            result[argument.keyword] = Candidate.new(type, argument)
          end
        end

        private

        attr_reader :source
      end
    end
  end
end
