# frozen_string_literal: true

require 'graphql'

module FixtureSchema
  # Plain nested ObjectType fixture. Used as the return type of
  # ExpenseType#billing_address, to exercise:
  #   - SPEC.md §4.3: nested Object-type fields are not eligible as argument
  #     candidates without an explicit `pick.override(name, input_type: ...)`.
  #   - SPEC.md §5.2/§5.3: a plain nested-field copy case for Field
  #     Derivation (Case 1 default method resolver).
  class AddressType < GraphQL::Schema::Object
    field :street, String, null: false
    field :city, String, null: false
    field :postal_code, String, null: true
  end
end
