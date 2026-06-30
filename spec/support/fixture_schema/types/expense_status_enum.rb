# frozen_string_literal: true

require 'graphql'

module FixtureSchema
  # Simple enum fixture used to exercise the enum row of SPEC.md §4.3's
  # ObjectType field -> Argument type mapping table, and as the type of
  # ExpenseType#status.
  class ExpenseStatusEnum < GraphQL::Schema::Enum
    value 'PENDING'
    value 'APPROVED'
    value 'REJECTED'
  end
end
