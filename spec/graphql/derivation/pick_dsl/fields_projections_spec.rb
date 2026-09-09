# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::PickDsl::PickFields do
  subject(:pick) { described_class.new(%i[title billing_address attachments], source_name: 'ExpenseType') }

  describe '#project' do
    it 'selects the field and records the nested block' do
      block = ->(nested) { nested.fields(:city) }
      pick.project(:billing_address, &block)

      expect([pick.selections.keys, pick.projections]).to eq([[:billing_address], {billing_address: block}])
    end

    it 'requires a block' do
      expect { pick.project(:billing_address) }.to raise_error(
        ArgumentError, /pick\.project\(:billing_address\) requires a block/,
      )
    end

    it 'raises ConfigurationError for an unknown field' do
      expect { pick.project(:bogus) { |nested| nested.fields(:city) } }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /:bogus.*ExpenseType/m,
      )
    end
  end

  describe '#fields with nested shorthand' do
    it 'records a projection picking the given names' do
      pick.fields(:title, billing_address: %i[city street])
      nested = described_class.new(%i[city street postal_code])
      pick.projections[:billing_address].call(nested)

      expect([pick.selections.keys, nested.selections.keys]).to eq([%i[title billing_address], %i[city street]])
    end

    it 'accepts a single name instead of an array' do
      pick.fields(billing_address: :city)
      nested = described_class.new(%i[city street])
      pick.projections[:billing_address].call(nested)

      expect(nested.selections.keys).to eq([:city])
    end
  end

  describe '#expose_full' do
    it 'selects the fields with the expose_full override set' do
      pick.expose_full(:billing_address, :attachments)

      expect(pick.selections).to eq(billing_address: {expose_full: true}, attachments: {expose_full: true})
    end
  end

  describe '#override' do
    it 'accepts type:' do
      pick.fields(:billing_address)
      pick.override(:billing_address, type: FixtureSchema::SyncConnectionType)

      expect(pick.selections[:billing_address]).to eq(type: FixtureSchema::SyncConnectionType)
    end
  end
end
