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

    context 'with a Mutation source' do
      it 'returns configured arguments using identity type mapping' do
        arguments = resolve(FixtureSchema::CreateExpenseMutation) do |pick|
          pick.required(:title)
          pick.optional(:category)
        end

        expect(arguments.map(&:graphql_name)).to contain_exactly('title', 'category')
      end

      it 'reuses the mutation argument type directly' do
        arguments = resolve(FixtureSchema::CreateExpenseMutation) { |pick| pick.optional(:title) }
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type.unwrap).to eq(FixtureSchema::CreateExpenseMutation.arguments['title'].type.unwrap)
      end

      it 'lets the pick block re-control nullability regardless of the mutation argument nullability' do
        arguments = resolve(FixtureSchema::CreateExpenseMutation) { |pick| pick.optional(:title) }
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type).not_to be_non_null
      end
    end

    context 'with a Symbol (sibling action) source' do
      # SPEC.md §4.2: Symbol sources are resolved via a `context:` object that
      # responds to `resolve_sibling_arguments(symbol)`. This is the seam the
      # Rails ControllerConcern plugs the controller class into. The engine
      # stays Rails-free, so this is tested with a lightweight fake resolver
      # rather than a real controller.
      let(:sibling_resolver) do
        sibling_arguments = [
          GraphQL::Schema::Argument.new(:title, String, owner: nil, required: true),
          GraphQL::Schema::Argument.new(:category, String, owner: nil, required: false),
        ]
        Class.new do
          define_method(:resolve_sibling_arguments) do |name|
            raise "unexpected sibling #{name.inspect}" unless name == :create

            sibling_arguments
          end
        end.new
      end

      let(:tags) do
        arguments = described_class.resolve(
          :create, ->(pick) { pick.required(:tags) }, context: list_resolver,
        )
        arguments.find { |argument| argument.graphql_name == 'tags' }
      end
      let(:list_resolver) do
        Class.new do
          define_method(:resolve_sibling_arguments) do |_name|
            [GraphQL::Schema::Argument.new(:tags, [String], owner: nil, required: true)]
          end
        end.new
      end

      it 'resolves the named sibling action via the context resolver' do
        arguments = described_class.resolve(
          :create, ->(pick) { pick.required(:title) }, context: sibling_resolver,
        )

        expect(arguments.map(&:graphql_name)).to contain_exactly('title')
      end

      it 'maps the sibling argument type by identity' do
        arguments = described_class.resolve(
          :create, ->(pick) { pick.optional(:title) }, context: sibling_resolver,
        )
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type.unwrap).to eq(GraphQL::Types::String)
      end

      it 'lets the pick block re-control nullability of an identity-mapped sibling argument' do
        arguments = described_class.resolve(
          :create, ->(pick) { pick.optional(:title) }, context: sibling_resolver,
        )
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type).not_to be_non_null
      end

      it 'raises ConfigurationError when no sibling resolver is supplied' do
        expect do
          resolve(:create) { |pick| pick.optional(:title) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /no sibling resolver/)
      end

      it 're-lists a list-typed sibling argument after unwrapping its element type' do
        expect(tags.type).to have_attributes(list?: true, unwrap: GraphQL::Types::String)
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

    context 'with a bare anonymous ObjectType source (no graphql_name declared)' do
      it 'falls back to #inspect instead of raising RequiredImplementationMissingError' do
        anonymous_type = Class.new(GraphQL::Schema::Object) do
          field :title, String, null: true
        end

        expect do
          resolve(anonymous_type) { |pick| pick.required(:bogus) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /does not define it/)
      end
    end
  end

  describe '#source_name (private)' do
    # `enumerate_candidates` rejects any source that isn't an ObjectType,
    # InputObject, Mutation, or Symbol before `source_name` is ever reached
    # via `.resolve`, so every real source responds to `graphql_name`. This
    # exercises the defensive `respond_to?(:graphql_name)` guard directly, for
    # a source type `.resolve` could never actually pass it -- called via
    # `send` since `source_name` is a `private_class_method`.
    let(:fake_source) do
      source = Object.new
      def source.name
        nil
      end
      source
    end

    it 'falls back to #inspect for a source with no #name and no #graphql_name' do
      expect(described_class.send(:source_name, fake_source)).to eq(fake_source.inspect)
    end
  end
end
