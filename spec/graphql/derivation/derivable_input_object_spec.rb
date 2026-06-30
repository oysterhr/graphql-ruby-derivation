# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::DerivableInputObject do
  # The registry (`included_classes`) is module-level state that
  # accumulates across the whole spec run. Reset it around each example so
  # one test's dynamically-defined class (especially ones left in a
  # deliberately-unresolvable, colliding state) cannot leak into another
  # test's `resolve_all!` call.
  around do |example|
    original = described_class.included_classes.dup
    described_class.included_classes.clear
    example.run
    described_class.included_classes.replace(original)
  end

  def build_input_object_class(&block)
    Class.new(GraphQL::Schema::InputObject) do
      include GraphQL::Derivation::DerivableInputObject

      graphql_name "TestInput#{object_id}"

      class_eval(&block) if block
    end
  end

  describe 'derivation resolution (§10.4 integration: introspection)' do
    it 'registers derived arguments on the class after resolve_all! fires' do
      input_class = build_input_object_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.required(:title, :amount_cents)
          pick.optional(:description)
        end
      end

      described_class.resolve_all!

      expect(input_class.arguments.keys).to contain_exactly('title', 'amountCents', 'description')
    end

    it 'marks a required selection as non-null' do
      input_class = build_input_object_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.required(:title)
          pick.optional(:description)
        end
      end

      described_class.resolve_all!

      expect(input_class.arguments['title'].type).to be_non_null
    end

    it "keeps a required selection's underlying type" do
      input_class = build_input_object_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.required(:title)
          pick.optional(:description)
        end
      end

      described_class.resolve_all!

      expect(input_class.arguments['title'].type.unwrap).to eq(GraphQL::Types::String)
    end

    it 'marks an optional selection as nullable' do
      input_class = build_input_object_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.required(:title)
          pick.optional(:description)
        end
      end

      described_class.resolve_all!

      expect(input_class.arguments['description'].type).not_to be_non_null
    end

    it 'allows inline argument declarations to coexist with derive_from' do
      input_class = build_input_object_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.required(:title)
        end

        argument :receipt_id, GraphQL::Types::ID, required: true
      end

      described_class.resolve_all!

      expect(input_class.arguments.keys).to contain_exactly('title', 'receiptId')
    end

    it 'does not raise when resolving a class that never calls derive_from' do
      build_input_object_class { argument :receipt_id, GraphQL::Types::ID, required: true }

      expect { described_class.resolve_all! }.not_to raise_error
    end

    it 'leaves a class that never calls derive_from with only its inline arguments' do
      input_class = build_input_object_class do
        argument :receipt_id, GraphQL::Types::ID, required: true
      end

      described_class.resolve_all!

      expect(input_class.arguments.keys).to contain_exactly('receiptId')
    end
  end

  describe 'collision detection (§10.4 integration)' do
    it 'raises ConfigurationError at resolution time when an inline argument collides with a derived one' do
      input_class = build_input_object_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.required(:title)
        end

        argument :title, String, required: true
      end

      expect { input_class.resolve_derivation! }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /title/,
      )
    end

    it 'does not register any derived arguments when a collision is detected' do
      input_class = build_input_object_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.required(:title, :amount_cents)
        end

        argument :title, String, required: true
      end

      begin
        input_class.resolve_derivation!
      rescue GraphQL::Derivation::ConfigurationError
        nil
      end

      expect(input_class.arguments.keys).to contain_exactly('title')
    end
  end

  describe 'derive_from validation' do
    it 'raises ConfigurationError immediately when called a second time on the same class' do
      input_class = build_input_object_class do
        derive_from(FixtureSchema::ExpenseType) { |pick| pick.required(:title) }
      end

      expect do
        input_class.derive_from(FixtureSchema::ExpenseType) { |pick| pick.required(:description) }
      end.to raise_error(GraphQL::Derivation::ConfigurationError, /at most once/)
    end

    it 'raises ArgumentError immediately when given a Symbol source' do
      expect do
        build_input_object_class { derive_from(:create) { |pick| pick.required(:title) } }
      end.to raise_error(ArgumentError, /Symbol/)
    end
  end

  describe 'resolve_all! idempotency' do
    it 'does not raise when resolve_all! is called twice' do
      build_input_object_class do
        derive_from(FixtureSchema::ExpenseType) { |pick| pick.required(:title) }
      end

      described_class.resolve_all!

      expect { described_class.resolve_all! }.not_to raise_error
    end

    it 'does not duplicate arguments when resolve_all! is called twice' do
      input_class = build_input_object_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.required(:title)
        end
      end

      described_class.resolve_all!
      described_class.resolve_all!

      expect(input_class.arguments.keys).to contain_exactly('title')
    end

    it 'does not re-run the pick block on a second resolve_derivation! call' do
      call_count = 0
      input_class = build_input_object_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          call_count += 1
          pick.required(:title)
        end
      end

      input_class.resolve_derivation!
      input_class.resolve_derivation!

      expect(call_count).to eq(1)
    end
  end
end
