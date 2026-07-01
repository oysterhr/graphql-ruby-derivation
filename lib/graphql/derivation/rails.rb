# frozen_string_literal: true

# SPEC.md §1.1: the Rails plugin require path. Loads `graphql/derivation`
# (core) first, then the Rails-only pieces. Requiring this file explicitly opts
# into Rails -- it pulls in ActiveSupport/ActionPack via the files below, which
# is expected here (core, `graphql/derivation`, stays Rails-free per AGENTS.md's
# require-guard rule).
require 'graphql/derivation'

require 'graphql/derivation/rails/errors'
require 'graphql/derivation/rails/argument_schema'
require 'graphql/derivation/rails/controller_concern'

module GraphQL
  module Derivation
    module Rails
      class << self
        # Reload-safety utility for apps running with Rails class reloading
        # enabled (dev/test -- `config.cache_classes = false` /
        # `config.reloading = true`). NOT auto-wired into anything: this gem
        # adds no `Rails::Engine` and does not hook itself into the reloader
        # automatically. Call this explicitly from a Rails initializer, e.g.:
        #
        #   Rails.application.reloader.before_class_unload do
        #     GraphQL::Derivation::Rails.reset_for_reload!
        #   end
        #
        # `before_class_unload` runs immediately before Zeitwerk unloads
        # autoloaded constants, i.e. before the OLD class objects this gem
        # may be holding onto become orphaned. Clearing these registries
        # there (rather than, say, `to_prepare`, which runs AFTER reload) is
        # what lets `to_prepare`-driven re-resolution (see SPEC.md §6.3/§7.3)
        # start from a clean slate instead of accumulating stale entries.
        #
        # In production (`config.cache_classes = true` / no reloading),
        # nothing ever unloads, so this never needs to run -- it is a no-op
        # to call it, but there is no reason to wire it up there at all.
        #
        # Clears three registries/caches, each documented at its own finding:
        #   1. `DerivableInputObject.included_classes` / `.clear!`
        #   2. `DerivableObjectType.included_classes` / `.clear!`
        #   3. `ArgumentSchema.reset!` (forgets all cached per-namespace
        #      schemas -- next `ArgumentSchema.for(namespace)` call rebuilds
        #      a fresh one; PR #15 introduced this originally for test
        #      isolation, and forgetting the whole schema on every reload is
        #      exactly the intended reload-time behaviour too, not just a
        #      test-only concern, since a reload replaces every InputObject
        #      class registered on it anyway)
        #   4. `GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper.enum_cache`
        #      (only if the optional ActiveRecord adapter has been required --
        #      `graphql/derivation/rails` alone does not load it, so this is
        #      guarded with `defined?` rather than an unconditional require)
        def reset_for_reload!
          GraphQL::Derivation::DerivableInputObject.clear!
          GraphQL::Derivation::DerivableObjectType.clear!
          ArgumentSchema.reset!

          return unless defined?(GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper)

          GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper.enum_cache.clear
        end
      end
    end
  end
end
