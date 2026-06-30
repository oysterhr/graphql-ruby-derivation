# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::Mappers::ObjectTypeToArgument do
  subject(:candidates) { described_class.candidates(FixtureSchema::ExpenseType) }

  describe '.candidates' do
    it 'maps String fields to GraphQL::Types::String' do
      expect(candidates[:title].type).to eq(GraphQL::Types::String)
    end

    it 'maps Integer fields to GraphQL::Types::Int' do
      expect(candidates[:amount_cents].type).to eq(GraphQL::Types::Int)
    end

    it 'maps Float fields to GraphQL::Types::Float' do
      expect(candidates[:reimbursement_rate].type).to eq(GraphQL::Types::Float)
    end

    it 'maps Boolean fields to GraphQL::Types::Boolean' do
      expect(candidates[:reimbursable].type).to eq(GraphQL::Types::Boolean)
    end

    it 'maps ID fields to GraphQL::Types::ID' do
      expect(candidates[:id].type).to eq(GraphQL::Types::ID)
    end

    it 'passes a custom scalar class through unchanged' do
      expect(candidates[:amount].type).to eq(FixtureSchema::MoneyAmountType)
    end

    it 'passes an enum class through unchanged' do
      expect(candidates[:status].type).to eq(FixtureSchema::ExpenseStatusEnum)
    end

    it 'keeps a list of scalar as [type]' do
      expect(candidates[:tags].type).to eq([GraphQL::Types::String])
    end

    it 'excludes connection-type fields from the candidate set' do
      expect(candidates).not_to have_key(:related_expenses)
    end

    it 'excludes list-of-Object fields from the candidate set' do
      expect(candidates).not_to have_key(:attachments)
    end

    it 'represents a nested (non-connection) Object-type field as a NestedObjectCandidate' do
      expect(candidates[:billing_address]).to be_a(
        described_class::NestedObjectCandidate,
      )
    end
  end

  describe described_class::NestedObjectCandidate do
    subject(:candidate) { described_class.new(:billing_address) }

    describe '#eligible?' do
      it 'is false without an input_type: override' do
        expect(candidate.eligible?({})).to be(false)
      end

      it 'is true with an input_type: override' do
        expect(candidate.eligible?(input_type: FixtureSchema::ExpenseBaseInput)).to be(true)
      end
    end

    describe '#resolved_type' do
      it 'returns the input_type: override value' do
        expect(candidate.resolved_type(input_type: FixtureSchema::ExpenseBaseInput))
          .to eq(FixtureSchema::ExpenseBaseInput)
      end
    end
  end
end
