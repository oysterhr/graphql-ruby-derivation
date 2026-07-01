# frozen_string_literal: true

require 'graphql'

module FixtureSchema
  # InputObject fixture used as an InputObject source for ArgumentDerivation
  # (§4.2 "InputObject source" -- identity type mapping, no exclusions). Mix
  # of required and optional arguments so ArgumentDerivation tests can verify
  # required/optional propagation (§10.3).
  class ExpenseBaseInput < GraphQL::Schema::InputObject
    argument :title, String, required: true
    argument :description, String, required: false
    argument :amount_cents, Integer, required: true
    argument :category, String, required: false
    argument :reimbursable, GraphQL::Types::Boolean, required: false, default_value: true
  end
end
