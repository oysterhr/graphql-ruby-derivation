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
      # SPEC.md §4.2 "Sibling source": a candidate carrying an already-resolved
      # `GraphQL::Schema::Argument` from the sibling action's argument set. Type
      # mapping is identity -- the sibling argument's own type is reused
      # directly (the sibling has already gone through derivation, so its type
      # is final). Mirrors the other mappers' `Candidate.type` contract so
      # `resolve_type` can treat it uniformly.
      SiblingCandidate = Struct.new(:type)

      module_function

      # @param source [Class, Symbol] An ObjectType class
      #   (`< GraphQL::Schema::Object`), an InputObject class
      #   (`< GraphQL::Schema::InputObject`), a Mutation class
      #   (`< GraphQL::Schema::Mutation`), or a Symbol naming a sibling
      #   action (SPEC.md §4.1).
      # @param pick_block [Proc] Called with a `PickArguments` instance.
      # @param context [#resolve_sibling_arguments, nil] Only consulted when
      #   `source` is a Symbol (sibling action). The contract: `context` must
      #   respond to `resolve_sibling_arguments(symbol)` and return an Array of
      #   already-resolved `GraphQL::Schema::Argument` instances (the sibling
      #   action's argument set). The Rails ControllerConcern passes the
      #   controller class here, since that class holds the action registry
      #   (SPEC.md §4.2, §8). Callers deriving from ObjectType/InputObject
      #   sources need not pass it (it defaults to nil, keeping existing
      #   non-Rails callers unchanged).
      # @return [Array<GraphQL::Schema::Argument>]
      def resolve(source, pick_block, context: nil)
        candidates = enumerate_candidates(source, context)

        pick = PickDsl::PickArguments.new(candidates.keys, source_name: source_name(source))
        pick_block.call(pick)
        pick.validate!

        pick.selections.map do |name, (required, overrides)|
          build_argument(name, candidates.fetch(name), required: required, overrides: overrides)
        end
      end

      # SPEC.md §4.2: dispatches to the appropriate mapper based on the
      # source's type. Any source type other than ObjectType, InputObject,
      # Mutation, or Symbol raises a plain `ArgumentError` immediately (i.e.
      # at declaration time, not at resolution time -- there is nothing to
      # defer here since the source's class is already known).
      def enumerate_candidates(source, context)
        if object_type_source?(source)
          Mappers::ObjectTypeToArgument.candidates(source)
        elsif input_object_source?(source) || mutation_source?(source)
          # Mutation classes declare their arguments the same way InputObjects
          # do (both extend `GraphQL::Schema::Member::HasArguments`, so
          # `.arguments` returns the same shape of `{name => Argument}`), so
          # `InputObjectToArgument` -- despite its name -- already produces
          # correct identity-mapped candidates for a Mutation source without
          # any changes. This is the "reconduct to the existing case" that
          # SPEC.md §4.2 describes: no separate mapper needed.
          Mappers::InputObjectToArgument.candidates(source)
        elsif source.is_a?(Symbol)
          sibling_candidates(source, context)
        else
          raise_unsupported_source_error(source)
        end
      end

      def raise_unsupported_source_error(source)
        raise ArgumentError,
          "Unsupported ArgumentDerivation source: #{source.inspect}. Expected an ObjectType " \
          'class, an InputObject class, a Mutation class, or a Symbol naming a sibling action.'
      end

      # A human-readable identifier for +source+, used only for error
      # messages raised by the Pick DSL (e.g. "unknown field" errors). Named
      # classes use their name; anonymous classes (common in specs, e.g.
      # `Class.new(GraphQL::Schema::Object) { ... }`) fall back to their
      # graphql_name (if the source responds to it) or `#inspect`, since
      # `Class#name` is nil for them.
      def source_name(source)
        return source.inspect if source.is_a?(Symbol)

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

      def object_type_source?(source)
        source.is_a?(Class) && source < GraphQL::Schema::Object
      end

      def input_object_source?(source)
        source.is_a?(Class) && source < GraphQL::Schema::InputObject
      end

      # SPEC.md §4.1/§4.2 "Mutation source": a mutation class with arguments
      # declared directly on it (the common graphql-ruby style), rather than
      # a separate InputObject. Covers `GraphQL::Schema::Mutation` and its
      # subclasses (e.g. `GraphQL::Schema::RelayClassicMutation`).
      def mutation_source?(source)
        source.is_a?(Class) && source < GraphQL::Schema::Mutation
      end

      # SPEC.md §4.1/§4.2: Symbol sources name a sibling action. Resolution is
      # deferred -- the sibling's argument set is looked up at resolution time
      # via the `context` object's `resolve_sibling_arguments` contract (see
      # `.resolve`'s docs). The ControllerConcern (SPEC.md §8) passes the
      # controller class as `context`; the controller walks its own
      # action registry (and ancestors') to produce the sibling's resolved
      # `GraphQL::Schema::Argument` instances. Each becomes an identity-mapped
      # candidate keyed by its Ruby keyword.
      def sibling_candidates(source, context)
        unless context.respond_to?(:resolve_sibling_arguments)
          raise GraphQL::Derivation::ConfigurationError,
            "Cannot resolve sibling source #{source.inspect}: no sibling resolver was supplied. " \
            'Symbol sources are only usable from the Rails ControllerConcern, which passes the ' \
            'controller class as `context:` (SPEC.md §4.2, §8).'
        end

        context.resolve_sibling_arguments(source).each_with_object({}) do |argument, result|
          # `required:` from this pick block (re)controls nullability, so the
          # sibling argument's own NonNull wrapper must not leak through; only
          # the unwrapped (and re-listed, if a list) type is reused -- the same
          # treatment InputObjectToArgument applies to identity-mapped types.
          type = argument.type.list? ? [argument.type.unwrap] : argument.type.unwrap
          result[argument.keyword] = SiblingCandidate.new(type)
        end
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
        return candidate.type if candidate.is_a?(SiblingCandidate)

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
        :mutation_source?,
        :raise_unsupported_source_error,
        :source_name,
        :sibling_candidates,
        :build_argument,
        :resolve_type
    end
  end
end
