# frozen_string_literal: true

# Smoke test for spec/support/fixture_schema/* (SPEC.md §10.2). This is
# test-support infrastructure, not a single class under test, so the
# top-level group describes the fixture set rather than one described_class.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'fixture schema' do
  # rubocop:enable RSpec/DescribeClass
  describe FixtureSchema::ExpenseType do
    it 'defines the expected scalar, enum, nested, list, and connection fields' do
      expect(described_class.fields.keys).to include(
        'id',
        'title',
        'description',
        'amountCents',
        'amount',
        'reimbursementRate',
        'reimbursable',
        'status',
        'billingAddress',
        'tags',
        'attachments',
        'memo',
        'fullName',
        'relatedExpenses',
      )
    end

    it 'maps the status field to ExpenseStatusEnum' do
      expect(described_class.fields['status'].type.unwrap).to eq(FixtureSchema::ExpenseStatusEnum)
    end

    it 'maps the amount field to the custom MoneyAmountType scalar' do
      expect(described_class.fields['amount'].type.unwrap).to eq(FixtureSchema::MoneyAmountType)
    end

    it 'maps the billingAddress field to the nested AddressType' do
      expect(described_class.fields['billingAddress'].type.unwrap).to eq(FixtureSchema::AddressType)
    end

    it 'maps relatedExpenses to a type with BaseConnection in its ancestors' do
      type = described_class.fields['relatedExpenses'].type.unwrap
      expect(type.ancestors).to include(GraphQL::Types::Relay::BaseConnection)
    end

    it 'maps relatedExpenses to a type whose name ends in Connection' do
      type = described_class.fields['relatedExpenses'].type.unwrap
      expect(type.graphql_name).to end_with('Connection')
    end

    it 'exposes a Case 2 (method:) resolver for memo via internal_memo' do
      expect(described_class.fields['memo'].method_sym).to eq(:internal_memo)
    end

    it 'exposes a Case 3 custom class resolver for full_name' do
      expect(described_class.respond_to?(:resolve_full_name)).to be(true)
    end
  end

  describe FixtureSchema::ExpenseStatusEnum do
    it 'defines PENDING, APPROVED, and REJECTED' do
      expect(described_class.values.keys).to contain_exactly('PENDING', 'APPROVED', 'REJECTED')
    end
  end

  describe FixtureSchema::AddressType do
    it 'defines street, city, and postalCode fields' do
      expect(described_class.fields.keys).to contain_exactly('street', 'city', 'postalCode')
    end
  end

  describe FixtureSchema::ExpenseConnection do
    it 'has BaseConnection in its ancestors' do
      expect(described_class.ancestors).to include(GraphQL::Types::Relay::BaseConnection)
    end

    it 'is named ExpenseConnection' do
      expect(described_class.graphql_name).to eq('ExpenseConnection')
    end
  end

  describe FixtureSchema::ExpenseBaseInput do
    it 'defines the expected required and optional arguments' do
      expect(described_class.arguments.keys).to contain_exactly(
        'title', 'description', 'amountCents', 'category', 'reimbursable',
      )
    end

    it 'marks title as required (non-null type)' do
      expect(described_class.arguments['title'].type).to be_non_null
    end

    it 'marks amountCents as required (non-null type)' do
      expect(described_class.arguments['amountCents'].type).to be_non_null
    end

    it 'marks description as optional (nullable type)' do
      expect(described_class.arguments['description'].type).not_to be_non_null
    end

    it 'marks category as optional (nullable type)' do
      expect(described_class.arguments['category'].type).not_to be_non_null
    end
  end

  describe FixtureSchema::Expense do
    it 'reports the expected columns' do
      expect(described_class.columns.map(&:name)).to include(
        'id',
        'created_at',
        'updated_at',
        'title',
        'description',
        'amount_cents',
        'reimbursement_rate',
        'reimbursable',
        'expense_date',
        'submitted_at',
        'external_uuid',
        'category',
        'metadata',
        'approver_ids',
      )
    end

    it 'reports the title column as not-null' do
      title_column = described_class.columns.find { |column| column.name == 'title' }
      expect(title_column.null).to be(false)
    end

    it 'reports the description column as nullable' do
      description_column = described_class.columns.find { |column| column.name == 'description' }
      expect(description_column.null).to be(true)
    end

    it 'defines a defined_enums entry for category' do
      expect(described_class.defined_enums).to have_key('category')
    end

    it 'lists food, travel, and paid_time_off as category enum values' do
      expect(described_class.defined_enums['category'].keys).to contain_exactly(
        'food', 'travel', 'paid_time_off',
      )
    end
  end
end
