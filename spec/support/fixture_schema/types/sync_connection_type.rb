# frozen_string_literal: true

require 'graphql'

module FixtureSchema
  # A plain Object type whose GraphQL name ends in `Connection` without being
  # a Relay connection (no `GraphQL::Types::Relay::BaseConnection` ancestor).
  # Real schemas have these (e.g. an integration "connection" record). Used
  # to prove that Field Derivation excludes connections by ancestry, not by
  # name, and that a source field's explicit `connection: false` survives
  # the copy (graphql-ruby would otherwise guess `connection: true` from the
  # name and add Relay pagination arguments).
  class SyncConnectionType < GraphQL::Schema::Object
    graphql_name 'SyncConnection'

    field :provider, String, null: false
  end
end
