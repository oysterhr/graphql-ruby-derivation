# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::PickDsl::PickArguments do
  subject(:pick) { described_class.new(%i[name email age]) }

  describe 'error messages referencing the source' do
    it 'names the source and lists its available names, sorted, for an unknown field' do
      named_pick = described_class.new(%i[name email age], source_name: 'SomeType')

      expect { named_pick.required(:bogus) }.to raise_error(
        GraphQL::Derivation::ConfigurationError,
        /:bogus.*SomeType.*age, :email, :name/m,
      )
    end

    it 'falls back to a generic label when no source_name is given' do
      expect { pick.required(:bogus) }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /derivation source/i,
      )
    end
  end

  describe '#required' do
    it 'selects the named fields as required' do
      pick.required(:name)
      pick.validate!

      expect(pick.selections[:name]).to eq([true, {}])
    end

    it 'accepts multiple field names' do
      pick.required(:name, :email)
      pick.validate!

      expect(pick.selections.keys).to contain_exactly(:name, :email)
    end

    it 'is idempotent when the same field is selected again as required' do
      pick.required(:name)
      pick.required(:name)

      expect { pick.validate! }.not_to raise_error
    end

    it 'raises ConfigurationError for an unknown field name' do
      expect { pick.required(:bogus) }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /bogus.*available names.*age.*email.*name/im,
      )
    end
  end

  describe '#optional' do
    it 'selects the named fields as optional' do
      pick.optional(:name)
      pick.validate!

      expect(pick.selections[:name]).to eq([false, {}])
    end

    it 'is idempotent when the same field is selected again as optional' do
      pick.optional(:name)
      pick.optional(:name)

      expect { pick.validate! }.not_to raise_error
    end

    it 'raises ConfigurationError for an unknown field name' do
      expect { pick.optional(:bogus) }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /bogus.*available names.*age.*email.*name/im,
      )
    end
  end

  describe '#override' do
    it 'merges options onto an already-selected field' do
      pick.required(:name)
      pick.override(:name, description: 'The name')
      pick.validate!

      expect(pick.selections[:name]).to eq([true, {description: 'The name'}])
    end

    it 'accumulates options across multiple override calls' do
      pick.required(:name)
      pick.override(:name, description: 'The name')
      pick.override(:name, default_value: 'anon')
      pick.validate!

      expect(pick.selections[:name]).to eq(
        [true, {description: 'The name', default_value: 'anon'}],
      )
    end

    it 'raises ConfigurationError when the field was not selected' do
      expect { pick.override(:name, description: 'The name') }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /name.*has not been picked yet.*pick\.required/im,
      )
    end

    it 'raises ConfigurationError for an unknown field name' do
      expect { pick.override(:bogus, description: 'x') }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /bogus.*available names.*age.*email.*name/im,
      )
    end

    it 'accepts every documented override option (SPEC.md §3.2) without raising' do
      pick.required(:name)

      expect do
        pick.override(
          :name,
          description: 'd',
          default_value: 'v',
          prepare: :prep,
          validates: {},
          as: :aka,
          deprecation_reason: 'why',
          input_type: nil,
        )
      end.not_to raise_error
    end

    it 'raises ConfigurationError immediately for an unknown override option' do
      pick.required(:name)

      expect { pick.override(:name, descriptoin: 'typo') }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /descriptoin.*description/im,
      )
    end

    it 'does not accumulate a partially-applied unknown override option' do
      pick.required(:name)

      begin
        pick.override(:name, descriptoin: 'typo')
      rescue GraphQL::Derivation::ConfigurationError
        nil
      end
      pick.validate!

      expect(pick.selections[:name]).to eq([true, {}])
    end
  end

  describe '#validate!' do
    it 'raises ConfigurationError when nothing was selected' do
      expect { pick.validate! }.to raise_error(
        GraphQL::Derivation::ConfigurationError, %r{selected.*pick\.required/optional.*available}im,
      )
    end

    it 'raises ConfigurationError when a field is both required and optional' do
      pick.required(:name)
      pick.optional(:name)

      expect { pick.validate! }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /name.*pick\.required.*pick\.optional/im,
      )
    end

    it 'raises ConfigurationError when a field is optional then required' do
      pick.optional(:email)
      pick.required(:email)

      expect { pick.validate! }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /email.*pick\.required.*pick\.optional/im,
      )
    end

    it 'uses plural phrasing when more than one field is both required and optional' do
      pick.required(:name, :email)
      pick.optional(:name, :email)

      expect { pick.validate! }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /:email, :name were passed to both/,
      )
    end

    it 'does not raise when distinct fields are required and optional' do
      pick.required(:name)
      pick.optional(:email)

      expect { pick.validate! }.not_to raise_error
    end
  end

  describe '#selections' do
    it 'returns a hash of name => [required, overrides]' do
      pick.required(:name)
      pick.optional(:email)
      pick.override(:email, description: 'Email address')
      pick.validate!

      expect(pick.selections).to eq(
        name: [true, {}],
        email: [false, {description: 'Email address'}],
      )
    end
  end
end
