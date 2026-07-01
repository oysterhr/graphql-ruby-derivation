# frozen_string_literal: true

module GraphQL
  module Derivation
    # Shared cycle detection for `derive_from` resolution, spanning BOTH
    # `DerivableInputObject` and `DerivableObjectType`. A `derive_from` chain
    # can cross the two mixins (an `ArgumentDerivation` ObjectType-source can
    # point at a class that itself includes `DerivableObjectType` with a
    # pending derivation -- SPEC.md §4.1/§4.2), so cycle detection cannot be
    # scoped to just one mixin's registry; both must consult the same
    # in-progress stack for a true cycle to be caught regardless of which
    # mixin(s) are involved.
    #
    # This is deliberately a DIFFERENT registry from the Rails
    # ControllerConcern's `sibling_resolution_stack` (SPEC.md §8.1): that one
    # detects cycles in the controller-action graph (Symbol sibling sources,
    # keyed by action name string); this one detects cycles in the
    # class-derivation graph (`derive_from` sources, keyed by class). Merging
    # them would conflate two different kinds of nodes/graphs.
    module DerivationResolutionGuard
      class << self
        # @return [Array<Class>] classes whose `resolve_derivation!` is
        #   currently on the call stack, in call order. Empty outside of an
        #   active resolution -- each `guard` call pops its entry via
        #   `ensure`, so this naturally drains back to empty once the
        #   outermost `resolve_derivation!` call returns, even after a raise.
        def in_progress
          @in_progress ||= []
        end

        # Wraps a single class's derivation resolution. Raises
        # `GraphQL::Derivation::CyclicDependencyError` if +klass+ is already
        # mid-resolution (i.e. resolving it would recurse back into itself
        # through one or more `derive_from` sources) instead of silently
        # reading a partially-resolved (or entirely empty) source.
        def guard(klass)
          raise_cyclic_dependency_error(klass) if in_progress.include?(klass)

          in_progress.push(klass)
          begin
            yield
          ensure
            in_progress.pop
          end
        end

        private

        def raise_cyclic_dependency_error(klass)
          cycle = in_progress[in_progress.index(klass)..] + [klass]
          raise GraphQL::Derivation::CyclicDependencyError,
            "Cyclic derive_from dependency: #{cycle.map { |k| class_name(k) }.join(' → ')}"
        end

        # Mirrors the `source_name` fallback already established in the
        # engines (ArgumentDerivation/FieldDerivation) for anonymous-class
        # handling: `graphql_name` is declared via `respond_to?` on every
        # GraphQL::Schema member, but raises `RequiredImplementationMissingError`
        # for anonymous types that never set one, so fall back to `#inspect`.
        def class_name(klass)
          klass.name || begin
            klass.graphql_name if klass.respond_to?(:graphql_name)
          rescue GraphQL::RequiredImplementationMissingError
            nil
          end || klass.inspect
        end
      end
    end
  end
end
