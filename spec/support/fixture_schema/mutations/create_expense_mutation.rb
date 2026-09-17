# frozen_string_literal: true

require 'graphql'

module FixtureSchema
  # Mutation fixture used as a Mutation-class source for ArgumentDerivation
  # (SPEC.md §4.2 "Mutation source"). Arguments declared directly on the
  # mutation class, the way graphql-ruby mutations normally look -- no
  # separate InputObject exists for this mutation.
  class CreateExpenseMutation < GraphQL::Schema::Mutation
    argument :title, String, required: true
    argument :description, String, required: false
    argument :amount_cents, Integer, required: true
    # `category`'s `prepare:`/`description:` let ArgumentDerivation specs
    # verify that a Mutation source (which routes through the same
    # `InputObjectToArgument` mapper as an InputObject source) also carries
    # the source argument's option metadata across, not just its type
    # (SPEC.md §4.4).
    argument :category, String, required: false, prepare: :strip, description: 'Expense category'

    field :success, GraphQL::Types::Boolean, null: false

    def resolve(**_args)
      raise NotImplementedError, 'fixture mutation is only used for argument derivation, never executed'
    end
  end
end
