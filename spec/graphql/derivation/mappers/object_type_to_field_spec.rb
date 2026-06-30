# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::Mappers::ObjectTypeToField do
  subject(:candidates) { described_class.candidates(FixtureSchema::ExpenseType) }

  describe '.candidates' do
    it 'detects Case 1 (default method resolver) for a field with no method: option' do
      expect(candidates[:title].resolver_case).to eq(:default)
    end

    it 'does not set a method override for a Case 1 candidate' do
      expect(candidates[:title].method_override).to be_nil
    end

    it 'detects Case 2 (method: option) for a field whose method_sym differs from its name' do
      expect(candidates[:memo].resolver_case).to eq(:method)
    end

    it 'carries the method: option forward for a Case 2 candidate' do
      expect(candidates[:memo].method_override).to eq(:internal_memo)
    end

    it 'detects Case 3 (custom class resolver) for a field with a resolve_* class method' do
      expect(candidates[:full_name].resolver_case).to eq(:custom_resolver)
    end

    it 'does not set a method override for a Case 3 candidate' do
      expect(candidates[:full_name].method_override).to be_nil
    end

    it 'excludes connection-type fields from the candidate set' do
      expect(candidates).not_to have_key(:related_expenses)
    end

    it 'includes a list-of-Object field as a candidate (unlike argument derivation)' do
      expect(candidates).to have_key(:attachments)
    end

    it 'includes a nested Object-type field as a candidate (unlike argument derivation)' do
      expect(candidates).to have_key(:billing_address)
    end

    it 'preserves the original (fully wrapped) field type for a candidate' do
      expect(candidates[:title].type).to eq(FixtureSchema::ExpenseType.fields['title'].type)
    end

    it 'preserves list-ness for a list-of-scalar field' do
      expect(candidates[:tags].type.list?).to be(true)
    end

    it 'carries the original GraphQL::Schema::Field for later use (e.g. error messages)' do
      expect(candidates[:title].field).to eq(FixtureSchema::ExpenseType.fields['title'])
    end
  end
end
