# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::Mappers::ObjectTypeToField do
  subject(:candidates) { described_class.candidates(FixtureSchema::ExpenseType) }

  describe 'Case 4 (instance resolver method)' do
    it 'detects a field whose source type defines an instance method of the same name' do
      expect(candidates[:display_title].resolver_case).to eq(:instance_method)
    end

    it 'detects it for a field with arguments too' do
      expect(candidates[:notes].resolver_case).to eq(:instance_method)
    end

    it 'does not count methods every GraphQL::Schema::Object instance already has' do
      source = Class.new(GraphQL::Schema::Object) do
        graphql_name 'Printable'
        field :display, String, null: true, resolver_method: :to_s
      end

      expect(described_class.candidates(source)[:display].resolver_case).to eq(:default)
    end
  end

  describe 'connection detection' do
    it 'keeps a plain Object field whose type is merely named like a connection' do
      expect(candidates).to have_key(:sync_connection)
    end

    it 'skips the ancestry check for a late-bound field type' do
      source = Class.new(GraphQL::Schema::Object) do
        include GraphQL::Derivation::DerivableObjectType

        graphql_name 'ExpenseA'
        derive_from(FixtureSchema::ExpenseType) { |pick| pick.fields(:billing_address) }
      end

      expect(described_class.candidates(source)).to have_key(:billing_address)
    end
  end
end
