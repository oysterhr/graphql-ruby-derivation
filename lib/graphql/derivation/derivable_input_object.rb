# frozen_string_literal: true

require 'graphql/derivation/engines/argument_derivation'
require 'graphql/derivation/derivation_resolution_guard'

module GraphQL
  module Derivation
    # Implements SPEC.md §6, a mixin for `GraphQL::Schema::InputObject`
    # subclasses that adds `derive_from`. The derivation is stored
    # unevaluated at declaration time (SPEC.md §3.1) and resolved lazily, the
    # first time graphql-ruby reads the class's arguments -- or earlier, if
    # `resolve_all!` (or the per-class `resolve_derivation!`) fires first.
    module DerivableInputObject
      class << self
        # @return [Array<Class>] every class that has included this mixin,
        #   in inclusion order. Used by `resolve_all!` to know what to
        #   resolve -- deliberately not `ObjectSpace`-based (slow, fragile).
        def included_classes
          @included_classes ||= []
        end

        def included(base)
          super
          included_classes << base
          base.extend(ClassMethods)
        end

        # SPEC.md §6.3: resolves every pending derivation across every class
        # that has included this mixin. Idempotent -- classes whose
        # derivation was already resolved (or that never called
        # `derive_from`) are left untouched.
        def resolve_all!
          included_classes.each(&:resolve_derivation!)
        end

        # Reload-safety seam (not part of the ordinary runtime API): forgets
        # every class registered via the `included` hook. `included_classes`
        # is a plain module-level Array with no unload hook, so under Rails
        # class reloading, every reload of a class that includes this mixin
        # leaves the OLD class object here forever (an unbounded leak across
        # the process lifetime) -- and keeps it reachable, which is what lets
        # stale generated types (e.g. `ActiveRecordMapper`'s enum classes)
        # linger long enough to collide with their reloaded replacements. See
        # `GraphQL::Derivation::Rails.reset_for_reload!`, which calls this
        # from a Rails app's `Rails.application.reloader.before_class_unload`.
        def clear!
          @included_classes = []
        end
      end

      # Class-level API mixed into `GraphQL::Schema::InputObject` subclasses.
      module ClassMethods
        # SPEC.md §6.1/§6.2: declares a derivation source and an unevaluated
        # pick block. Validates the source and the at-most-once constraint
        # immediately; the derivation itself is deferred until
        # `resolve_derivation!` fires.
        def derive_from(source, &pick_block)
          check_not_already_derived!
          check_supported_source!(source)

          @derivation_source = source
          @derivation_pick_block = pick_block
        end

        # SPEC.md §6.3: resolves this class's pending derivation, if any.
        # Idempotent -- a second call is a no-op once resolution has
        # happened (or if `derive_from` was never called). The early-return
        # check happens BEFORE the cycle guard is engaged, so resolving an
        # already-finished dependency never touches the in-progress stack --
        # only a derivation that is genuinely being computed right now
        # participates in cycle detection.
        #
        # If `@derivation_source` is itself Derivable (i.e. responds to
        # `resolve_derivation!` -- another `DerivableInputObject` or
        # `DerivableObjectType` class), its own derivation is resolved
        # FIRST, recursively, before `ArgumentDerivation.resolve` reads its
        # `.arguments`. This makes resolution order-independent: a source
        # always finishes resolving before its dependent does, regardless of
        # which class happened to be included/declared first. Both this
        # recursive call and this class's own resolution are wrapped in
        # `DerivationResolutionGuard.guard`, which shares its in-progress
        # stack with `DerivableObjectType` -- so a cycle is caught even if it
        # crosses both mixins (e.g. an ArgumentDerivation ObjectType-source
        # that is itself a pending DerivableObjectType).
        #
        # A resolution that raises (a collision, a cycle, a pick block that
        # blows up) leaves the derivation pending, so the next read -- lazy
        # or explicit -- runs it again and raises again. The failure stays
        # loud on every access instead of surfacing once and then quietly
        # serving a type with its derived arguments missing.
        #
        # @param context [#resolve_sibling_arguments, nil] forwarded to
        #   ArgumentDerivation for Symbol (sibling action) sources. Only the
        #   Rails ControllerConcern (SPEC.md §8) supplies this -- ordinary
        #   InputObjects never use Symbol sources (SPEC.md §11.1), so the
        #   default of nil keeps non-Rails callers unchanged. When nil, the
        #   resolver registered via `allow_sibling_sources!` (if any) is used
        #   instead, so a lazy first read of a controller-generated
        #   InputObject can still resolve its Symbol source. Also forwarded
        #   to a Derivable source's own recursive `resolve_derivation!` call,
        #   in case that source is itself part of the same Rails-generated,
        #   context-carrying chain -- harmless (defaults to nil) for the
        #   ordinary ObjectType/InputObject-source case.
        def resolve_derivation!(context: nil)
          return unless pending_derivation?

          GraphQL::Derivation::DerivationResolutionGuard.guard(self) do
            resolve_pending_derivation!(context || sibling_resolver)
          end
        end

        # Lazy resolution on first use. These are the only methods
        # graphql-ruby reads an InputObject's arguments through -- schema
        # build (`Schema::Addition`), `Visibility`, the legacy `Warden`,
        # introspection, SDL dump, static validation, variable validation and
        # coercion all end up in `arguments`, `get_argument`,
        # `all_argument_definitions` or `any_arguments?`. Resolving a pending
        # `derive_from` right before delegating means the derived arguments
        # are in place the first time the type is used, with no
        # `resolve_all!` required. `resolve_all!` still works as an eager
        # warm-up (e.g. a Rails `to_prepare`) that fails at boot instead of
        # on the first request.
        #
        # `own_arguments` is deliberately NOT the hook, even though every
        # reader above goes through it: mirroring `DerivableObjectType`, the
        # hooks sit on the read API so that declaring members in the class
        # body never triggers a resolution.
        def arguments(...)
          resolve_pending_derivations_in_ancestry!
          super
        end

        def get_argument(...)
          resolve_pending_derivations_in_ancestry!
          super
        end

        def all_argument_definitions
          resolve_pending_derivations_in_ancestry!
          super
        end

        def any_arguments?
          resolve_pending_derivations_in_ancestry!
          super
        end

        private

        def pending_derivation?
          defined?(@derivation_pick_block) && @derivation_pick_block ? true : false
        end

        # The read hooks resolve every Derivable class in the ancestry, not
        # just `self`: graphql-ruby walks `ancestors` and reads each one's
        # `own_arguments` directly, so a subclass of a derivable type would
        # otherwise never trigger its parent's pending derivation. A class
        # the current thread is already resolving is skipped -- that read is
        # the re-entrant one from inside `resolve_pending_derivation!`, and
        # must fall through to the pre-derivation members rather than start
        # a second resolution.
        def resolve_pending_derivations_in_ancestry!
          derivable_ancestry.each do |klass|
            next if GraphQL::Derivation::DerivationResolutionGuard.resolving?(klass)

            klass.resolve_derivation!
          end
        end

        # Memoized: a class's superclass chain never changes after it is
        # defined, and modules included later can't respond to
        # `resolve_derivation!`, so this cannot go stale. Keeps the hot
        # `get_argument` path to a walk over one to three classes instead of
        # a fresh `ancestors` array per call.
        def derivable_ancestry
          @derivable_ancestry ||= ancestors.select { |ancestor| ancestor.respond_to?(:resolve_derivation!) }
        end

        # The guarded body of `resolve_derivation!`, split out so the public
        # method itself stays a short guard-then-delegate wrapper. Re-checks
        # `pending_derivation?` because the guard's lock may have been held
        # by another thread that finished this exact resolution meanwhile.
        def resolve_pending_derivation!(context)
          return unless pending_derivation?

          resolve_source_derivation!(context)

          # `all_argument_definitions` rather than `arguments.keys`: same
          # names (inherited ones included), but without the visibility pass
          # and without graphql-ruby's "Input Object types must have
          # arguments" warning, which a derive-only type would otherwise emit
          # mid-resolution.
          pre_existing_names = all_argument_definitions.map(&:graphql_name)

          derived_arguments = GraphQL::Derivation::ArgumentDerivation.resolve(
            @derivation_source, @derivation_pick_block, context: context,
          )

          check_collisions!(pre_existing_names, derived_arguments)
          derived_arguments.each { |argument| register_derived_argument(argument) }

          @derivation_pick_block = nil
        end

        # Ensures `@derivation_source`'s own derivation (if it is Derivable)
        # has resolved before this class reads its `.arguments`. Runs BEFORE
        # `ArgumentDerivation.resolve` is called, from inside the cycle
        # guard, so a source that is mid-resolution (a true cycle) raises
        # `CyclicDependencyError` from `DerivationResolutionGuard.guard`
        # instead of this class silently reading the source's
        # not-yet-registered (i.e. empty) arguments.
        def resolve_source_derivation!(context)
          return unless @derivation_source.respond_to?(:resolve_derivation!)

          @derivation_source.resolve_derivation!(context: context)
        end

        # Internal escape hatch for the Rails ControllerConcern: its
        # auto-generated InputObjects DO have an action registry (the
        # controller class) to resolve Symbol siblings against, so they opt
        # into Symbol sources by calling this (via `send`, since it's private)
        # before `derive_from`, passing that registry as +resolver+. It is
        # remembered as the default `context:` so that a lazy first read (one
        # graphql-ruby makes with no `context:` to give) can still resolve a
        # Symbol source. User-defined DerivableInputObjects have no way to
        # reach this, so §11.1's rejection still applies to them.
        def allow_sibling_sources!(resolver = nil)
          @allow_sibling_sources = true
          @sibling_resolver = resolver
        end

        def sibling_resolver
          defined?(@sibling_resolver) ? @sibling_resolver : nil
        end

        # ArgumentDerivation builds arguments unattached (`owner: nil`) -- it
        # has no way to know which class will register them (SPEC.md §4.4:
        # "the caller registers it on the target InputObject"). graphql-ruby's
        # coercion path, however, calls `owner.validate_directive_argument`
        # during `coerce_input`, so the argument MUST know its owner before it
        # can coerce input. `GraphQL::Schema::Argument#owner` is read-only (set
        # only in the constructor), so attaching here means setting the ivar
        # directly -- a deliberate, scoped exception to "no instance_variable_set
        # on third-party objects", because there is no public setter and
        # rebuilding the argument would drop configured options.
        def register_derived_argument(argument)
          argument.instance_variable_set(:@owner, self)
          add_argument(argument)
        end

        # PR #11 review (khamusa) questioned whether this restriction should
        # be relaxed -- e.g. to allow re-opening a class and calling
        # `derive_from` again before resolution has happened, since reopening
        # classes is common in Ruby. Deliberately deferred: SPEC.md §6.2
        # states derive_from may be called at most once per class, and
        # relaxing that is a spec-level behavior change that needs a real
        # use case, not something to slip in as a message-quality fix. Only
        # the error message below was improved.
        def check_not_already_derived!
          return unless defined?(@derivation_source) && @derivation_source

          raise GraphQL::Derivation::ConfigurationError,
            "#{self} already called derive_from(#{@derivation_source.inspect}). " \
            'derive_from may be called at most once per class (SPEC.md §6.2) -- remove the ' \
            'duplicate call, or fold any extra fields into the existing derive_from block ' \
            '(or into inline `argument` declarations alongside it).'
        end

        # SPEC.md §11.1: sibling (Symbol) sources have no natural
        # equivalent outside ControllerConcern's action registry --
        # disallow them immediately, the same as §4.1's "any other invalid
        # source" treatment. The ControllerConcern (which DOES have a registry)
        # is exempt via `allow_sibling_sources!`.
        def check_supported_source!(source)
          return unless source.is_a?(Symbol)
          return if defined?(@allow_sibling_sources) && @allow_sibling_sources

          raise ArgumentError,
            "Unsupported DerivableInputObject source: #{source.inspect}. " \
            'Symbol (sibling action) sources are not supported outside ' \
            'ControllerConcern context (SPEC.md §11.1).'
        end

        # SPEC.md §6.2: inline `argument` declarations may coexist with
        # `derive_from`, but if an inline argument names a field also
        # present in the derivation's selections, that is a
        # ConfigurationError raised at resolution time.
        def check_collisions!(pre_existing_names, derived_arguments)
          collisions = derived_arguments.map(&:graphql_name) & pre_existing_names
          return if collisions.empty?

          raise GraphQL::Derivation::ConfigurationError,
            "derive_from on #{self} collides with inline argument(s) already declared: " \
            "#{collisions.inspect}"
        end
      end
    end
  end
end
