# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::PickDsl::PickFields do
  subject(:pick) { described_class.new(%i[name email age]) }

  describe 'error messages referencing the source' do
    it 'names the source and lists its available names, sorted, for an unknown field' do
      named_pick = described_class.new(%i[name email age], source_name: 'SomeType')

      expect { named_pick.fields(:bogus) }.to raise_error(
        GraphQL::Derivation::ConfigurationError,
        /:bogus.*SomeType.*age, :email, :name/m,
      )
    end

    it 'falls back to a generic label when no source_name is given' do
      expect { pick.fields(:bogus) }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /derivation source/i,
      )
    end
  end

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
        GraphQL::Derivation::ConfigurationError, /bogus.*available names.*age.*email.*name/im,
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
        GraphQL::Derivation::ConfigurationError, /name.*has not been picked yet.*pick\.fields/im,
      )
    end

    it 'raises ConfigurationError for an unknown field name' do
      expect { pick.override(:bogus, null: false) }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /bogus.*available names.*age.*email.*name/im,
      )
    end

    it 'accepts every documented override option (SPEC.md §3.3) without raising' do
      pick.fields(:name)

      expect do
        pick.override(
          :name,
          description: 'd',
          deprecation_reason: 'why',
          null: false,
          method: :m,
          resolver: ->(_o, _a, _c) {},
          name: :aka,
          camelize: false,
        )
      end.not_to raise_error
    end

    it 'raises ConfigurationError immediately for an unknown override option' do
      pick.fields(:name)

      expect { pick.override(:name, dercription: 'typo') }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /dercription.*description/im,
      )
    end

    it 'does not accumulate a partially-applied unknown override option' do
      pick.fields(:name)

      begin
        pick.override(:name, dercription: 'typo')
      rescue GraphQL::Derivation::ConfigurationError
        nil
      end
      pick.validate!

      expect(pick.selections[:name]).to eq({})
    end

    it 'rejects an override option that is valid for PickArguments but not PickFields' do
      pick.fields(:name)

      expect { pick.override(:name, default_value: 'x') }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /default_value/,
      )
    end
  end

  describe '#validate!' do
    it 'raises ConfigurationError when nothing was selected' do
      expect { pick.validate! }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /selected.*pick\.fields.*available/im,
      )
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
