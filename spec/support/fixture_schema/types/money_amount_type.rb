# frozen_string_literal: true

require 'graphql'

module FixtureSchema
  # Custom scalar fixture (a decimal-as-string money representation). Used as
  # the type of ExpenseType#amount to exercise SPEC.md §4.3's "any custom
  # scalar (< GraphQL::Schema::Scalar)" row, which maps to the same scalar
  # class unchanged.
  class MoneyAmountType < GraphQL::Schema::Scalar
    def self.coerce_input(value, _ctx)
      value.to_s
    end

    def self.coerce_result(value, _ctx)
      value.to_s
    end
  end
end
