# frozen_string_literal: true

module FixtureSchema
  # Plain Ruby stand-in for an ActiveRecord model -- deliberately NOT a
  # `< ActiveRecord::Base` subclass and not backed by a real DB connection
  # (SPEC.md §10.5: "AR tests stub `.columns`/`.defined_enums` directly").
  #
  # `.columns` returns column-like value objects exposing `name`/`type`/
  # `null`, matching the subset of `ActiveRecord::ConnectionAdapters::Column`
  # that the ActiveRecord adapter (§9) reads. The set below is chosen to
  # cover every row of §9.1's column type mapping table that the adapter
  # must support, plus the unsupported/array rows it must reject:
  #
  #   id          :integer  not null   -- excluded by default (§9.4)
  #   created_at  :datetime not null   -- excluded by default (§9.4)
  #   updated_at  :datetime not null   -- excluded by default (§9.4)
  #   title       :string   not null   -- maps to String, null: false
  #   description :text     nullable   -- maps to String, null: true
  #   amount_cents :integer  not null  -- maps to GraphQL::Types::Int
  #   reimbursement_rate :float nullable -- maps to Float
  #   reimbursable :boolean not null   -- maps to GraphQL::Types::Boolean
  #   expense_date :date     not null  -- maps to GraphQL::Types::ISO8601Date
  #   submitted_at :datetime nullable  -- maps to GraphQL::Types::ISO8601DateTime
  #   external_uuid :uuid    nullable  -- maps to GraphQL::Types::ID
  #   category     :integer  not null  -- Rails-enum column (integer-backed; see
  #                                        `defined_enums`, exercises the "column name
  #                                        matches a defined_enums key" branch of §9.2,
  #                                        as distinct from a native Postgres :enum column)
  #   metadata     :jsonb    nullable  -- unsupported -> UnsupportedColumnTypeError
  #   approver_ids :array    nullable  -- array of unsupported element -> UnsupportedColumnTypeError
  Column = Struct.new(:name, :type, :null)

  class Expense
    COLUMNS = [
      Column.new('id', :integer, false),
      Column.new('created_at', :datetime, false),
      Column.new('updated_at', :datetime, false),
      Column.new('title', :string, false),
      Column.new('description', :text, true),
      Column.new('amount_cents', :integer, false),
      Column.new('reimbursement_rate', :float, true),
      Column.new('reimbursable', :boolean, false),
      Column.new('expense_date', :date, false),
      Column.new('submitted_at', :datetime, true),
      Column.new('external_uuid', :uuid, true),
      Column.new('category', :integer, false),
      Column.new('metadata', :jsonb, true),
      Column.new('approver_ids', :array, true),
    ].freeze

    DEFINED_ENUMS = {
      'category' => {'food' => 0, 'travel' => 1, 'paid_time_off' => 2},
    }.freeze

    def self.columns
      COLUMNS
    end

    def self.defined_enums
      DEFINED_ENUMS
    end

    def self.name
      'Expense'
    end
  end
end
