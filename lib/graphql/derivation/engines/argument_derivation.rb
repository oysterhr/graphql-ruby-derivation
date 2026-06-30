# frozen_string_literal: true

require 'graphql/derivation/pick_dsl/arguments'
require 'graphql/derivation/mappers/object_type_to_argument'
require 'graphql/derivation/mappers/input_object_to_argument'

module GraphQL
  module Derivation
    # Implements SPEC.md §4, the Argument Derivation Engine. Accepts a
    # source and an unevaluated pick block, and returns an array of
    # configured `GraphQL::Schema::Argument` instances (unregistered -- the
    # caller registers them on the target InputObject).
    module ArgumentDerivation
      module_function

      # @param source [Class, Symbol] An ObjectType class
      #   (`< GraphQL::Schema::Object`), an InputObject class
      #   (`< GraphQL::Schema::InputObject`), or a Symbol naming a sibling
      #   action (SPEC.md §4.1).
      # @param pick_block [Proc] Called with a `PickArguments` instance.
      # @return [Array<GraphQL::Schema::Argument>]
      def resolve(source, pick_block, context: nil)
        candidates = enumerate_candidates(source, context)

        pick = PickDsl::PickArguments.new(candidates.keys)
        pick_block.call(pick)
        pick.validate!

        pick.selections.map do |name, (required, overrides)|
          build_argument(name, candidates.fetch(name), required: required, overrides: overrides)
        end
      end

      # SPEC.md §4.2: dispatches to the appropriate mapper based on the
      # source's type. Any source type other than ObjectType, InputObject,
      # or Symbol raises a plain `ArgumentError` immediately (i.e. at
      # declaration time, not at resolution time -- there is nothing to
      # defer here since the source's class is already known).
      def enumerate_candidates(source, context)
        if object_type_source?(source)
          Mappers::ObjectTypeToArgument.candidates(source)
        elsif input_object_source?(source)
          Mappers::InputObjectToArgument.candidates(source)
        elsif source.is_a?(Symbol)
          sibling_candidates(source, context)
        else
          raise_unsupported_source_error(source)
        end
      end

      def raise_unsupported_source_error(source)
        raise ArgumentError,
          "Unsupported ArgumentDerivation source: #{source.inspect}. " \
          'Expected an ObjectType class, an InputObject class, or a Symbol naming a sibling action.'
      end

      def object_type_source?(source)
        source.is_a?(Class) && source < GraphQL::Schema::Object
      end

      def input_object_source?(source)
        source.is_a?(Class) && source < GraphQL::Schema::InputObject
      end

      # SPEC.md §4.1/§4.2: Symbol sources are resolved via the
      # ControllerConcern's class-level sibling registry (SPEC.md §8, Rails
      # Plugin). That registry does not exist yet -- it is built as part of
      # the §8 Rails Plugin PR, not this one (see PR description for the
      # §4 status rationale). Resolving a Symbol source here is therefore
      # deferred and currently unsupported.
      def sibling_candidates(_source, _context)
        raise NotImplementedError,
          'Sibling source resolution (Symbol sources) is deferred to the Rails Plugin ' \
          '(SPEC.md §8, ControllerConcern registry), which does not exist yet. ' \
          'This is a known gap tracked against SPEC.md §4\'s "In Progress" status.'
      end

      # SPEC.md §4.4's `build_argument` step. `candidate` is either a plain
      # `Candidate` (type already resolved at enumeration time) or an
      # `ObjectTypeToArgument::NestedObjectCandidate` (type resolution
      # deferred until overrides are known -- see that class's docs).
      def build_argument(name, candidate, required:, overrides:)
        type = resolve_type(name, candidate, overrides)
        # `input_type:` is consumed above to resolve `type` for nested
        # Object-type candidates; it is not itself a `GraphQL::Schema::
        # Argument` keyword, so it must not be forwarded.
        argument_opts = overrides.except(:input_type)
        opts = {required: required}.merge(argument_opts)

        GraphQL::Schema::Argument.new(name, type, owner: nil, **opts)
      end

      def resolve_type(name, candidate, overrides)
        return candidate.type if candidate.is_a?(Mappers::ObjectTypeToArgument::Candidate)
        return candidate.type if candidate.is_a?(Mappers::InputObjectToArgument::Candidate)

        # NestedObjectCandidate: only eligible if `input_type:` was supplied
        # via `pick.override` (SPEC.md §4.3's Object-type row).
        unless candidate.eligible?(overrides)
          raise GraphQL::Derivation::ConfigurationError,
            "#{name.inspect} is a nested Object-type field and is not eligible as an argument " \
            'without pick.override(name, input_type: SomeInputObjectClass)'
        end

        candidate.resolved_type(overrides)
      end

      private_class_method :object_type_source?,
        :input_object_source?,
        :raise_unsupported_source_error,
        :sibling_candidates,
        :build_argument,
        :resolve_type
    end
  end
end
