# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::ProjectedEdge do
  let(:source_field) { FixtureSchema::ExpenseType.fields['billingAddress'] }

  def build_edge(destination:)
    described_class.new(FixtureSchema::AddressType, source_field: source_field, destination: destination)
  end

  it 'is a LateBoundType named after the canonical type' do
    edge = build_edge(destination: nil)

    expect(edge).to be_a(GraphQL::Schema::LateBoundType).and(have_attributes(name: 'Address', graphql_name: 'Address'))
  end

  it 'wraps like any other type' do
    edge = build_edge(destination: nil)

    expect(edge.to_list_type.to_non_null_type.to_type_signature).to eq('[Address]!')
  end

  describe '#derived_field_path' do
    it 'uses the destination class name when it has one' do
      stub_const('Surface::ExpenseType', Class.new(GraphQL::Schema::Object) { graphql_name 'Expense' })

      expect(build_edge(destination: Surface::ExpenseType).derived_field_path).to eq('Surface::ExpenseType.billingAddress')
    end

    it 'falls back to the destination graphql_name for an anonymous class' do
      anonymous = Class.new(GraphQL::Schema::Object) { graphql_name 'Expense' }

      expect(build_edge(destination: anonymous).derived_field_path).to eq('Expense.billingAddress')
    end

    it 'says so when there is no destination' do
      expect(build_edge(destination: nil).derived_field_path).to eq('an anonymous projection.billingAddress')
    end
  end

  describe '#source_field_path' do
    it 'names an anonymous source type by its GraphQL name' do
      holder = Class.new(GraphQL::Schema::Object) do
        graphql_name 'Holder'
        field :thing, FixtureSchema::AddressType, null: true
      end
      edge = described_class.new(FixtureSchema::AddressType, source_field: holder.fields['thing'])

      expect(edge.source_field_path).to eq('Holder#thing')
    end
  end

  describe '#inspect' do
    it 'names the edge, the derived field, the source field and the canonical type' do
      anonymous = Class.new(GraphQL::Schema::Object) { graphql_name 'Expense' }

      expect(build_edge(destination: anonymous).inspect).to eq(
        '#<GraphQL::Derivation::ProjectedEdge Address for Expense.billingAddress ' \
        '(FixtureSchema::ExpenseType#billing_address returns FixtureSchema::AddressType)>',
      )
    end
  end
end
