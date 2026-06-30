# frozen_string_literal: true

require 'graphql/derivation/rails/active_record'

RSpec.describe GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper do
  subject(:candidates) { described_class.candidates(FixtureSchema::Expense) }

  def candidate_type(name)
    candidates.fetch(name).type
  end

  describe '.candidates' do
    describe 'SPEC.md §9.1 column type mapping' do
      it 'maps :string to String' do
        expect(candidate_type(:title)).to eq(String)
      end

      it 'maps :text to String' do
        expect(candidate_type(:description)).to eq(String)
      end

      it 'maps :integer to GraphQL::Types::Int' do
        expect(candidate_type(:amount_cents)).to eq(GraphQL::Types::Int)
      end

      it 'maps :float to Float' do
        expect(candidate_type(:reimbursement_rate)).to eq(Float)
      end

      it 'maps :boolean to GraphQL::Types::Boolean' do
        expect(candidate_type(:reimbursable)).to eq(GraphQL::Types::Boolean)
      end

      it 'maps :date to GraphQL::Types::ISO8601Date' do
        expect(candidate_type(:expense_date)).to eq(GraphQL::Types::ISO8601Date)
      end

      it 'maps :datetime to GraphQL::Types::ISO8601DateTime' do
        expect(candidate_type(:submitted_at)).to eq(GraphQL::Types::ISO8601DateTime)
      end

      it 'maps :uuid to GraphQL::Types::ID' do
        expect(candidate_type(:external_uuid)).to eq(GraphQL::Types::ID)
      end

      it 'raises UnsupportedColumnTypeError for :jsonb' do
        expect { candidate_type(:metadata) }.to raise_error(
          GraphQL::Derivation::UnsupportedColumnTypeError, /metadata/,
        )
      end

      it 'maps an array of a supported element type to [type]' do
        expect(candidate_type(:tag_names)).to eq([String])
      end

      it 'raises UnsupportedColumnTypeError for an array of an unsupported element type' do
        expect { candidate_type(:approver_ids) }.to raise_error(
          GraphQL::Derivation::UnsupportedColumnTypeError, /approver_ids/,
        )
      end

      it 'does not raise for an unrelated unsupported column when it is not accessed' do
        expect { candidates }.not_to raise_error
      end
    end

    describe 'SPEC.md §9.2 Rails enum handling' do
      it 'generates a GraphQL::Schema::Enum subclass for a defined_enums column' do
        expect(candidate_type(:category)).to be < GraphQL::Schema::Enum
      end

      it 'names the generated enum "model_name + camelized column name + Enum"' do
        expect(candidate_type(:category).graphql_name).to eq('ExpenseCategoryEnum')
      end

      it 'upcases and underscores the enum values' do
        expect(candidate_type(:category).values.keys).to contain_exactly('FOOD', 'TRAVEL', 'PAID_TIME_OFF')
      end

      it 'memoizes the generated enum class across separate .candidates calls' do
        first = described_class.candidates(FixtureSchema::Expense).fetch(:category).type
        second = described_class.candidates(FixtureSchema::Expense).fetch(:category).type

        expect(first).to equal(second)
      end

      it 'raises UnsupportedColumnTypeError when enum values cannot be determined' do
        model = Class.new do
          def self.columns
            [FixtureSchema::Column.new('status', :enum, false)]
          end

          def self.defined_enums
            {}
          end

          def self.name
            'Widget'
          end
        end

        expect { described_class.candidates(model).fetch(:status).type }.to raise_error(
          GraphQL::Derivation::UnsupportedColumnTypeError,
        )
      end
    end

    describe 'SPEC.md §9.3 null handling' do
      it 'defaults to null: false for a NOT NULL column' do
        expect(candidates.fetch(:title).null).to be(false)
      end

      it 'defaults to null: true for a nullable column' do
        expect(candidates.fetch(:description).null).to be(true)
      end
    end

    describe 'SPEC.md §9.4 excluded columns' do
      it 'excludes id from the candidate set' do
        expect(candidates).not_to have_key(:id)
      end

      it 'excludes created_at from the candidate set' do
        expect(candidates).not_to have_key(:created_at)
      end

      it 'excludes updated_at from the candidate set' do
        expect(candidates).not_to have_key(:updated_at)
      end

      it 'includes other columns, including foreign keys, as candidates' do
        expect(candidates).to have_key(:team_member_id)
      end
    end

    describe 'foreign-key naming override (§9.1 type table vs §9.4 FK note)' do
      it 'maps a *_id column whose underlying type is :bigint to GraphQL::Types::ID, not Int' do
        expect(candidate_type(:team_member_id)).to eq(GraphQL::Types::ID)
      end

      it 'still maps a non-FK :integer/:bigint column to GraphQL::Types::Int' do
        expect(candidate_type(:amount_cents)).to eq(GraphQL::Types::Int)
      end
    end
  end
end
