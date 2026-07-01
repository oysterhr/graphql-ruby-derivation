# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::PickDsl::PickFields do
  subject(:pick) { described_class.new(%i[name email age]) }

  describe '#fields' do
    it 'selects the named fields' do
      pick.fields(:name)
      pick.validate!

      expect(pick.selections).to eq(name: {})
    end

    it 'accepts multiple field names' do
      pick.fields(:name, :email)
      pick.validate!

      expect(pick.selections.keys).to contain_exactly(:name, :email)
    end

    it 'accumulates selections across multiple calls' do
      pick.fields(:name)
      pick.fields(:email)
      pick.validate!

      expect(pick.selections.keys).to contain_exactly(:name, :email)
    end

    it 'raises ConfigurationError for an unknown field name' do
      expect { pick.fields(:bogus) }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /bogus/,
      )
    end
  end

  describe '#override' do
    it 'merges options onto an already-selected field' do
      pick.fields(:name)
      pick.override(:name, method: :full_name)
      pick.validate!

      expect(pick.selections[:name]).to eq(method: :full_name)
    end

    it 'accumulates options across multiple override calls' do
      pick.fields(:name)
      pick.override(:name, method: :full_name)
      pick.override(:name, null: false)
      pick.validate!

      expect(pick.selections[:name]).to eq(method: :full_name, null: false)
    end

    it 'raises ConfigurationError when the field was not selected' do
      expect { pick.override(:name, null: false) }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /name/,
      )
    end

    it 'raises ConfigurationError for an unknown field name' do
      expect { pick.override(:bogus, null: false) }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /bogus/,
      )
    end
  end

  describe '#validate!' do
    it 'raises ConfigurationError when nothing was selected' do
      expect { pick.validate! }.to raise_error(GraphQL::Derivation::ConfigurationError, /selected/)
    end

    it 'does not raise when at least one field is selected' do
      pick.fields(:name)

      expect { pick.validate! }.not_to raise_error
    end
  end

  describe '#selections' do
    it 'returns a hash of name => overrides' do
      pick.fields(:name, :email)
      pick.override(:email, name: :email_address)
      pick.validate!

      expect(pick.selections).to eq(
        name: {},
        email: {name: :email_address},
      )
    end
  end
end
