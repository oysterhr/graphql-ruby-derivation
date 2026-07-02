# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::Mappers::InputObjectToArgument do
  subject(:candidates) { described_class.candidates(FixtureSchema::ExpenseBaseInput) }

  describe '.candidates' do
    it 'returns a candidate for every argument on the InputObject' do
      expect(candidates.keys).to contain_exactly(
        :title, :description, :amount_cents, :category, :reimbursable,
      )
    end

    it 'reuses the argument type directly (identity mapping, modulo nullability)' do
      source_type = FixtureSchema::ExpenseBaseInput.arguments['title'].type
      expect(candidates[:title].type).to eq(source_type.unwrap)
    end

    it 'unwraps a required (non-null) source argument so required: can control nullability' do
      # ArgumentDerivation builds the final GraphQL::Schema::Argument with an
      # explicit `required:` driven by the pick block (`pick.required` /
      # `pick.optional`), independent of the source InputObject's own
      # nullability -- so the candidate's type must not carry a NonNull
      # wrapper itself.
      expect(candidates[:title].type).not_to be_non_null
    end

    it 'leaves an already-nullable source argument type unwrapped the same way' do
      expect(candidates[:description].type).not_to be_non_null
    end
  end

  describe '.candidates with a Mutation class source (SPEC.md §4.2 "Mutation source")' do
    subject(:candidates) { described_class.candidates(FixtureSchema::CreateExpenseMutation) }

    it 'returns a candidate for every argument declared on the mutation, unchanged' do
      expect(candidates.keys).to contain_exactly(:title, :description, :amount_cents, :category)
    end

    it 'reuses the mutation argument type directly, the same as an InputObject source' do
      source_type = FixtureSchema::CreateExpenseMutation.arguments['title'].type
      expect(candidates[:title].type).to eq(source_type.unwrap)
    end
  end
end
