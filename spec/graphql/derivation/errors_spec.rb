# frozen_string_literal: true

# This file covers five sibling error classes (SPEC.md §2) in one spec, so the
# top-level group describes the set of them rather than a single class.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'GraphQL::Derivation error types' do
  # rubocop:enable RSpec/DescribeClass
  describe GraphQL::Derivation::Error do
    it 'is a StandardError' do
      expect(described_class).to be < StandardError
    end
  end

  describe GraphQL::Derivation::ConfigurationError do
    it 'inherits from GraphQL::Derivation::Error' do
      expect(described_class).to be < GraphQL::Derivation::Error
    end
  end

  describe GraphQL::Derivation::CyclicDependencyError do
    it 'inherits from GraphQL::Derivation::ConfigurationError' do
      expect(described_class).to be < GraphQL::Derivation::ConfigurationError
    end

    it 'inherits from GraphQL::Derivation::Error' do
      expect(described_class).to be < GraphQL::Derivation::Error
    end
  end

  describe GraphQL::Derivation::UnresolvableFieldError do
    it 'inherits from GraphQL::Derivation::ConfigurationError' do
      expect(described_class).to be < GraphQL::Derivation::ConfigurationError
    end

    it 'inherits from GraphQL::Derivation::Error' do
      expect(described_class).to be < GraphQL::Derivation::Error
    end
  end

  describe GraphQL::Derivation::UnsupportedColumnTypeError do
    it 'inherits from GraphQL::Derivation::Error' do
      expect(described_class).to be < GraphQL::Derivation::Error
    end

    it 'does not inherit from GraphQL::Derivation::ConfigurationError' do
      expect(described_class).not_to be < GraphQL::Derivation::ConfigurationError
    end
  end
end
