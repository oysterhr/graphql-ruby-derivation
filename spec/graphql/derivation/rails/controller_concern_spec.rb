# frozen_string_literal: true

require 'action_controller'
require 'graphql/derivation/rails'

RSpec.describe GraphQL::Derivation::Rails::ControllerConcern do
  before { GraphQL::Derivation::Rails::ArgumentSchema.reset! }
  after { GraphQL::Derivation::Rails::ArgumentSchema.reset! }

  # Builds a real ActionController::Base subclass with the concern. We never
  # route or dispatch a request; instead each example stubs `action_name` and
  # `params` on an instance, which is all `#arguments` consults.
  def build_controller(namespace: :test, &class_body)
    klass = Class.new(ActionController::Base) do
      include GraphQL::Derivation::Rails::ControllerConcern
    end
    klass.argument_namespace(namespace)
    klass.class_eval(&class_body) if class_body
    klass
  end

  def instance_for(controller_class, action:, params: {})
    instance = controller_class.new
    allow(instance).to receive_messages(action_name: action.to_s, params: params)
    instance
  end

  describe '#arguments' do
    context 'with an inline-argument-only action' do
      let(:controller) do
        build_controller do
          argument :title, String, required: true
          argument :count, GraphQL::Types::Int, required: false
          def create; end
        end
      end

      it 'returns the coerced argument hash' do
        instance = instance_for(controller, action: :create, params: {'title' => 'Hi', 'count' => 3})

        expect(instance.arguments).to eq(title: 'Hi', count: 3)
      end

      it 'memoizes the result across calls' do
        instance = instance_for(controller, action: :create, params: {'title' => 'Hi'})

        expect(instance.arguments).to equal(instance.arguments)
      end
    end

    context 'with an arguments_from ObjectType source' do
      let(:controller) do
        build_controller do
          arguments_from FixtureSchema::ExpenseType do |pick|
            pick.required :title
            pick.optional :amount_cents
          end
          def create; end
        end
      end

      it 'returns the coerced hash derived from the ObjectType fields' do
        instance = instance_for(
          controller, action: :create, params: {'title' => 'Lunch', 'amountCents' => 1200},
        )

        expect(instance.arguments).to eq(title: 'Lunch', amount_cents: 1200)
      end
    end

    context 'with an action that declared nothing' do
      let(:controller) do
        build_controller do
          def index; end
        end
      end

      it 'raises MissingInputTypeError' do
        instance = instance_for(controller, action: :index)

        expect { instance.arguments }
          .to raise_error(GraphQL::Derivation::Rails::MissingInputTypeError, /index/)
      end
    end

    context 'with input that fails coercion' do
      let(:controller) do
        build_controller do
          argument :title, String, required: true
          def create; end
        end
      end

      it 'raises ArgumentParsingError when a required argument is absent' do
        instance = instance_for(controller, action: :create, params: {})

        expect { instance.arguments }
          .to raise_error(GraphQL::Derivation::Rails::ArgumentParsingError)
      end

      it 'is not a ConfigurationError (request-time, not load-time, per SPEC.md §2)' do
        expect(GraphQL::Derivation::Rails::ArgumentParsingError.ancestors)
          .not_to include(GraphQL::Derivation::ConfigurationError)
      end
    end
  end

  describe 'class DSL validation' do
    it 'rejects loads: on an inline argument' do
      expect do
        build_controller do
          argument :widget, GraphQL::Types::ID, loads: Object
          def create; end
        end
      end.to raise_error(GraphQL::Derivation::ConfigurationError, /loads:/)
    end

    it 'rejects a second arguments_from for the same action' do
      expect do
        build_controller do
          arguments_from(FixtureSchema::ExpenseType) { |pick| pick.required(:title) }
          arguments_from(FixtureSchema::ExpenseBaseInput) { |pick| pick.required(:title) }
          def create; end
        end
      end.to raise_error(GraphQL::Derivation::ConfigurationError, /at most once/)
    end
  end

  describe 'collision between inline argument and arguments_from' do
    let(:controller) do
      build_controller do
        argument :title, String, required: true
        arguments_from(FixtureSchema::ExpenseType) { |pick| pick.required(:title) }
        def create; end
      end
    end

    it 'raises ConfigurationError at resolution time' do
      instance = instance_for(controller, action: :create, params: {'title' => 'x'})

      expect { instance.arguments }
        .to raise_error(GraphQL::Derivation::ConfigurationError, /collides/)
    end
  end

  describe 'sibling (Symbol) sources' do
    it 'resolves a sibling action declared on the same controller' do
      controller = build_controller do
        argument :title, String, required: true
        argument :category, String, required: false
        def create; end

        arguments_from :create do |pick|
          pick.required :title
        end
        def update; end
      end

      instance = instance_for(controller, action: :update, params: {'title' => 'Renamed'})

      expect(instance.arguments).to eq(title: 'Renamed')
    end

    it 'resolves a sibling action declared on an ancestor controller' do
      base = build_controller do
        argument :title, String, required: true
        def create; end
      end
      child = Class.new(base) do
        arguments_from :create do |pick|
          pick.required :title
        end
        def update; end
      end

      instance = instance_for(child, action: :update, params: {'title' => 'X'})

      expect(instance.arguments).to eq(title: 'X')
    end
  end

  describe '.eager_load_argument_sources!' do
    it 'resolves all registered sources without error when acyclic' do
      controller = build_controller do
        argument :title, String, required: true
        def create; end

        arguments_from :create do |pick|
          pick.required :title
        end
        def update; end
      end

      expect { controller.eager_load_argument_sources! }.not_to raise_error
    end

    it 'raises CyclicDependencyError with the full cycle path on a two-action sibling cycle' do
      controller = build_controller do
        arguments_from(:update) { |pick| pick.optional(:title) }
        def create; end

        arguments_from(:create) { |pick| pick.optional(:title) }
        def update; end
      end

      expect { controller.eager_load_argument_sources! }
        .to raise_error(
          GraphQL::Derivation::CyclicDependencyError,
          /create → update → create|update → create → update/,
        )
    end

    it 'detects a three-action cycle' do
      controller = build_controller do
        arguments_from(:b) { |pick| pick.optional(:title) }
        def a; end

        arguments_from(:c) { |pick| pick.optional(:title) }
        def b; end

        arguments_from(:a) { |pick| pick.optional(:title) }
        def c; end
      end

      expect { controller.eager_load_argument_sources! }
        .to raise_error(GraphQL::Derivation::CyclicDependencyError)
    end
  end
end
