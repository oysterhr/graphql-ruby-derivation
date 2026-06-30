# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::FieldDerivation do
  def resolve(source, &pick_block)
    described_class.resolve(source, pick_block)
  end

  describe '.resolve' do
    context 'with an ObjectType source' do
      it 'returns configured fields for the selected fields' do
        fields = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.fields(:title, :amount_cents)
        end

        expect(fields.map(&:graphql_name)).to contain_exactly('title', 'amountCents')
      end

      it 'copies a Case 1 (default method resolver) field as-is' do
        fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:title) }
        title = fields.find { |field| field.graphql_name == 'title' }

        expect(title.method_sym).to eq(:title)
      end

      it 'copies a Case 2 (method: option) field with the same method:' do
        fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:memo) }
        memo = fields.find { |field| field.graphql_name == 'memo' }

        expect(memo.method_sym).to eq(:internal_memo)
      end

      it 'raises UnresolvableFieldError for an unresolved Case 3 (custom resolver) field' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:full_name) }
        end.to raise_error(GraphQL::Derivation::UnresolvableFieldError, /full_name/)
      end

      it 'resolves a Case 3 field when the pick block supplies a method: override' do
        fields = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.fields(:full_name)
          pick.override(:full_name, method: :computed_full_name)
        end
        full_name = fields.find { |field| field.graphql_name == 'fullName' }

        expect(full_name.method_sym).to eq(:computed_full_name)
      end

      it 'resolves a Case 3 field when the pick block supplies a resolver: override' do
        resolver = ->(obj, _args, _ctx) { obj.full_name }

        fields = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.fields(:full_name)
          pick.override(:full_name, resolver: resolver)
        end

        expect(fields.map(&:graphql_name)).to include('fullName')
      end

      it 'mixes Case 1, Case 2, and overridden Case 3 fields in one resolution' do
        fields = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.fields(:title, :memo, :full_name)
          pick.override(:full_name, method: :computed_full_name)
        end

        expect(fields.map(&:graphql_name)).to contain_exactly('title', 'memo', 'fullName')
      end

      it 'does not offer a connection-type field as a candidate' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:related_expenses) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /related_expenses/)
      end
    end

    context 'with an ActiveRecord model source' do
      # `FixtureSchema::Expense` is deliberately a plain Ruby stand-in, not a
      # real `ActiveRecord::Base` subclass (SPEC.md §10.5) -- the gem's own
      # test suite never loads ActiveRecord. To exercise the
      # `source < ActiveRecord::Base` branch of `FieldDerivation`, this
      # context defines a minimal `ActiveRecord::Base` stand-in for the
      # duration of the example, simulating a host app where ActiveRecord
      # is loaded, then removes it so other examples are unaffected.
      before do
        stub_const('ActiveRecord::Base', Class.new)
      end

      it 'raises a clear deferred-feature error pointing at the future require path' do
        model = Class.new(ActiveRecord::Base)

        expect do
          resolve(model) { |pick| pick.fields(:title) }
        end.to raise_error(NotImplementedError, %r{graphql/derivation/rails/active_record})
      end
    end

    context 'with an unsupported source type' do
      it 'raises ArgumentError immediately' do
        expect do
          resolve('not a valid source') { |_pick| nil }
        end.to raise_error(ArgumentError, /Unsupported FieldDerivation source/)
      end

      it 'raises ArgumentError for nil' do
        expect { resolve(nil) { |_pick| nil } }.to raise_error(ArgumentError)
      end
    end

    context 'when the pick block selects nothing' do
      it 'raises ConfigurationError via PickFields#validate!' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |_pick| nil }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /selected/)
      end
    end
  end
end
