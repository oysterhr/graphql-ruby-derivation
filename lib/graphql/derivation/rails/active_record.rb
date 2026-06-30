# frozen_string_literal: true

# SPEC.md §1.1: the ActiveRecord adapter require path. Loads
# `graphql/derivation/rails` (which in turn loads core, `graphql/derivation`)
# first, then the adapter itself. Requiring this file explicitly opts into
# ActiveRecord -- core and the plain Rails plugin stay ActiveRecord-free per
# AGENTS.md's require-guard rule.
require 'graphql/derivation/rails'
require 'active_record'

require 'graphql/derivation/rails/adapters/active_record_mapper'

module GraphQL
  module Derivation
    module Rails
      module Adapters
      end
    end
  end
end
