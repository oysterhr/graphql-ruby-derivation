# frozen_string_literal: true

require 'graphql'

module FixtureSchema
  # InputObject fixture used as an InputObject source for ArgumentDerivation
  # (§4.2 "InputObject source" -- identity type mapping, no exclusions). Mix
  # of required and optional arguments so ArgumentDerivation tests can verify
  # required/optional propagation (§10.3).
  #
  # `title`'s `validates:`, `category`'s `prepare:`/`description:` and
  # `notes`'s `deprecation_reason:` exist so ArgumentDerivation specs can
  # verify that a derived argument preserves the source argument's option
  # metadata, not just its type (SPEC.md §4.4).
  class ExpenseBaseInput < GraphQL::Schema::InputObject
    argument :title, String, required: true, validates: {length: {maximum: 40}}
    argument :description, String, required: false
    argument :amount_cents, Integer, required: true
    argument :category, String, required: false, prepare: :strip, description: 'Expense category'
    argument :reimbursable, GraphQL::Types::Boolean, required: false, default_value: true
    argument :notes, String, required: false, deprecation_reason: 'Use description instead'
  end
end
