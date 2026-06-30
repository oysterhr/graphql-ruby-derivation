# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::ArgumentDerivation do
  def resolve(source, &pick_block)
    described_class.resolve(source, pick_block)
  end

  describe '.resolve' do
    context 'with an ObjectType source' do
      it 'returns configured arguments for the selected fields' do
        arguments = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.required(:title, :amount_cents)
          pick.optional(:description, :status)
        end

        expect(arguments.map(&:graphql_name)).to contain_exactly(
          'title', 'amountCents', 'description', 'status',
        )
      end

      it 'marks required selections as non-null' do
        arguments = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.required(:title)
          pick.optional(:description)
        end
        by_name = arguments.to_h { |argument| [argument.graphql_name, argument] }

        expect(by_name['title'].type).to be_non_null
      end

      it 'marks optional selections as nullable' do
        arguments = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.required(:title)
          pick.optional(:description)
        end
        by_name = arguments.to_h { |argument| [argument.graphql_name, argument] }

        expect(by_name['description'].type).not_to be_non_null
      end

      it 'passes a custom scalar field type through unchanged' do
        arguments = resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:amount) }
        amount = arguments.find { |argument| argument.graphql_name == 'amount' }

        expect(amount.type).to eq(FixtureSchema::MoneyAmountType)
      end

      it 'passes an enum field type through unchanged' do
        arguments = resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:status) }
        status = arguments.find { |argument| argument.graphql_name == 'status' }

        expect(status.type).to eq(FixtureSchema::ExpenseStatusEnum)
      end

      it 'keeps a list-of-scalar field as a list' do
        arguments = resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:tags) }
        tags = arguments.find { |argument| argument.graphql_name == 'tags' }

        expect(tags.type.list?).to be(true)
      end

      it 'keeps a list-of-scalar field wrapping the same scalar type' do
        arguments = resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:tags) }
        tags = arguments.find { |argument| argument.graphql_name == 'tags' }

        expect(tags.type.unwrap).to eq(GraphQL::Types::String)
      end

      it 'does not offer a connection-type field as a candidate' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:related_expenses) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /related_expenses/)
      end

      it 'does not offer a list-of-Object field as a candidate' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:attachments) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /attachments/)
      end

      it 'raises ConfigurationError when a nested Object-type field is selected without input_type:' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:billing_address) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /billing_address/)
      end

      it 'allows a nested Object-type field when input_type: is supplied via override' do
        arguments = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.optional(:billing_address)
          pick.override(:billing_address, input_type: FixtureSchema::ExpenseBaseInput)
        end
        billing_address = arguments.find { |argument| argument.graphql_name == 'billingAddress' }

        expect(billing_address.type).to eq(FixtureSchema::ExpenseBaseInput)
      end

      it 'does not forward input_type: itself as a GraphQL::Schema::Argument option' do
        arguments = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.optional(:billing_address)
          pick.override(:billing_address, input_type: FixtureSchema::ExpenseBaseInput)
        end
        billing_address = arguments.find { |argument| argument.graphql_name == 'billingAddress' }

        expect(billing_address.type).not_to be_non_null
      end
    end

    context 'with an InputObject source' do
      it 'returns configured arguments using identity type mapping' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) do |pick|
          pick.required(:title)
          pick.optional(:category)
        end

        expect(arguments.map(&:graphql_name)).to contain_exactly('title', 'category')
      end

      it 'reuses the source argument type directly' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.optional(:title) }
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type.unwrap).to eq(FixtureSchema::ExpenseBaseInput.arguments['title'].type.unwrap)
      end

      it 'marks a pick.optional selection as nullable regardless of source nullability' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.optional(:title) }
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type).not_to be_non_null
      end

      it 'marks a pick.required selection as non-null regardless of source nullability' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.required(:category) }
        category = arguments.find { |argument| argument.graphql_name == 'category' }

        expect(category.type).to be_non_null
      end
    end

    context 'with a Symbol (sibling action) source' do
      it 'raises NotImplementedError because the ControllerConcern registry does not exist yet' do
        expect do
          resolve(:create) { |pick| pick.optional(:title) }
        end.to raise_error(NotImplementedError, /Sibling source resolution/)
      end
    end

    context 'with an unsupported source type' do
      it 'raises ArgumentError immediately' do
        expect do
          resolve('not a valid source') { |_pick| nil }
        end.to raise_error(ArgumentError, /Unsupported ArgumentDerivation source/)
      end

      it 'raises ArgumentError for nil' do
        expect { resolve(nil) { |_pick| nil } }.to raise_error(ArgumentError)
      end
    end

    context 'when the pick block selects nothing' do
      it 'raises ConfigurationError via PickArguments#validate!' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |_pick| nil }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /selected/)
      end
    end
  end
end
