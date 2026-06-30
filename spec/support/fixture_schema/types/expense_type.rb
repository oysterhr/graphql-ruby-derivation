# frozen_string_literal: true

require 'graphql'
require_relative 'expense_status_enum'
require_relative 'address_type'
require_relative 'money_amount_type'

module FixtureSchema
  # Primary fixture ObjectType for Argument Derivation Engine (§4) and Field
  # Derivation Engine (§5) unit/integration tests. Covers:
  #
  #   - Scalar fields for every row of §4.3's type mapping table: String,
  #     Int, Float, Boolean, ID, and a custom scalar (MoneyAmountType).
  #   - An enum field (`status`).
  #   - A nested Object-type field (`billing_address`) -- not eligible as an
  #     argument candidate without `input_type:` (§4.3); plain field-copy
  #     case for Field Derivation.
  #   - A connection-type field (`related_expenses`) -- excluded from
  #     candidates entirely (§4.2/§5.2).
  #   - A list-of-scalar field (`tags`) -- kept as `[String]` (§4.3).
  #   - A list-of-Object field (`attachments`) -- excluded entirely (§4.3).
  #   - Resolver Case 1/2/3 fixtures for Field Derivation (§5.3):
  #       Case 1 (default method resolver): `title`
  #       Case 2 (`method:` option):        `memo` -> `internal_memo`
  #       Case 3 (custom class resolver):   `full_name` -> `self.resolve_full_name`
  class ExpenseType < GraphQL::Schema::Object
    # --- Scalars (§4.3 type mapping table) ---
    field :id, GraphQL::Types::ID, null: false
    field :title, String, null: false # Case 1 resolver
    field :description, String, null: true
    field :amount_cents, Integer, null: false
    field :amount, MoneyAmountType, null: false
    field :reimbursement_rate, Float, null: true
    field :reimbursable, GraphQL::Types::Boolean, null: false

    # --- Enum ---
    field :status, ExpenseStatusEnum, null: false

    # --- Nested Object type ---
    field :billing_address, AddressType, null: true

    # --- Lists ---
    field :tags, [String], null: false # list of scalar: kept
    field :attachments, [AddressType], null: false # list of Object: excluded

    # --- Resolver Case 2: `method:` option ---
    field :memo, String, null: true, method: :internal_memo

    # --- Resolver Case 3: custom class resolver method ---
    field :full_name, String, null: true

    def internal_memo
      object.respond_to?(:internal_memo) ? object.internal_memo : nil
    end

    def self.resolve_full_name(obj, _args, _ctx)
      obj.full_name
    end
  end
end
