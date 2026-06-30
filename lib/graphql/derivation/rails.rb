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
    end
  end
end
