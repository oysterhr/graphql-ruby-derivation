# frozen_string_literal: true

require 'graphql'
require_relative 'expense_type'

module FixtureSchema
  # Connection type fixture, built from ExpenseType via graphql-ruby's Relay
  # connection helpers (`ExpenseType.connection_type`). Used as the return
  # type of ExpenseType#related_expenses to exercise the connection
  # exclusion rule in SPEC.md §4.2 ("class name ends in `Connection`, or the
  # type includes `GraphQL::Types::Relay::BaseConnection` in its ancestors")
  # and §5.2 (same exclusion for Field Derivation candidates).
  class ExpenseConnection < ExpenseType.connection_type
  end

  class ExpenseType < GraphQL::Schema::Object
    field :related_expenses, ExpenseConnection, null: false
  end
end
