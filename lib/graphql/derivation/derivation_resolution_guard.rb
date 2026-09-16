# frozen_string_literal: true

require 'monitor'

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
    #
    # Resolution is also serialized here. Derivations resolve lazily, on the
    # first graphql-ruby read of a class (see the mixins), and that first read
    # can happen on any request thread. A single process-wide re-entrant
    # `Monitor` makes the whole resolution (including the recursive
    # source-first resolution of a chain) one critical section: a second
    # thread reading the same class blocks until the first finishes, then
    # sees the class fully resolved. One process-wide lock, rather than one
    # per class, is what keeps two threads that start at opposite ends of the
    # same chain from deadlocking on each other's class lock.
    module DerivationResolutionGuard
      @in_progress = []
      @monitor = Monitor.new

      class << self
        # @return [Array<Class>] classes whose `resolve_derivation!` is
        #   currently on the call stack, in call order. Empty outside of an
        #   active resolution -- each `guard` call pops its entry via
        #   `ensure`, so this naturally drains back to empty once the
        #   outermost `resolve_derivation!` call returns, even after a raise.
        attr_reader :in_progress

        # Wraps a single class's derivation resolution. Raises
        # `GraphQL::Derivation::CyclicDependencyError` if +klass+ is already
        # mid-resolution (i.e. resolving it would recurse back into itself
        # through one or more `derive_from` sources) instead of silently
        # reading a partially-resolved (or entirely empty) source.
        def guard(klass)
          @monitor.synchronize do
            raise_cyclic_dependency_error(klass) if in_progress.include?(klass)

            in_progress.push(klass)
            begin
              yield
            ensure
              in_progress.pop
            end
          end
        end

        # True when the CURRENT thread is mid-resolution of +klass+. The lazy
        # read hooks use this to tell a re-entrant read apart from a first
        # read: resolving a derivation reads the class's own pre-existing
        # members (and graphql-ruby's `add_field` reads them again), and those
        # reads must fall straight through to graphql-ruby rather than start a
        # second resolution. The owner check matters: for ANOTHER thread the
        # same class is simply not resolved yet, so its read must block on
        # `guard` and wait, not skip ahead and observe a half-registered set.
        def resolving?(klass)
          @monitor.mon_owned? && in_progress.include?(klass)
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
