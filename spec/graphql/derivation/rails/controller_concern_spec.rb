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

    context 'with an arguments_from Mutation class source' do
      let(:controller) do
        build_controller do
          arguments_from FixtureSchema::CreateExpenseMutation do |pick|
            pick.required :title
            pick.optional :amount_cents
          end
          def create; end
        end
      end

      it 'returns the coerced hash derived from the mutation arguments, same as an ObjectType source' do
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

      it 'raises ArgumentCoercionError when a required argument is absent' do
        instance = instance_for(controller, action: :create, params: {})

        expect { instance.arguments }
          .to raise_error(GraphQL::Derivation::Rails::ArgumentCoercionError)
      end

      it 'is not a ConfigurationError (request-time, not load-time, per SPEC.md §2)' do
        expect(GraphQL::Derivation::Rails::ArgumentCoercionError.ancestors)
          .not_to include(GraphQL::Derivation::ConfigurationError)
      end
    end

    context 'with input that passes validation but raises during coercion (e.g. a prepare: proc)' do
      let(:controller) do
        build_controller do
          argument :quantity,
            GraphQL::Types::Int,
            required: true,
            prepare: lambda { |value, _ctx|
              raise GraphQL::ExecutionError, 'must be positive' if value <= 0

              value
            }
          def create; end
        end
      end

      it 'wraps the GraphQL::ExecutionError raised mid-coercion as ArgumentCoercionError' do
        instance = instance_for(controller, action: :create, params: {'quantity' => -1})

        expect { instance.arguments }.to raise_error(
          GraphQL::Derivation::Rails::ArgumentCoercionError,
          /Could not coerce arguments for "create": must be positive/,
        )
      end
    end
  end

  describe '#arguments with resource_arguments (SPEC.md §8.1)' do
    context 'with a flat argument mixed with a nested resource scope' do
      let(:controller) do
        build_controller do
          argument :page, GraphQL::Types::Int, required: false

          resource_arguments :expense do
            arguments_from FixtureSchema::ExpenseType do |pick|
              pick.required :title, :amount_cents
            end
          end

          def create; end
        end
      end

      it 'returns a nested Hash for the resource scope and a flat value for the flat argument' do
        instance = instance_for(
          controller,
          action: :create,
          params: {'page' => 2, 'expense' => {'title' => 'Lunch', 'amountCents' => 1200}},
        )

        expect(instance.arguments).to eq(page: 2, expense: {title: 'Lunch', amount_cents: 1200})
      end

      it 'raises ArgumentCoercionError when a required field inside the resource scope is missing' do
        instance = instance_for(
          controller, action: :create, params: {'expense' => {'title' => 'Lunch'}},
        )

        expect { instance.arguments }.to raise_error(GraphQL::Derivation::Rails::ArgumentCoercionError)
      end

      it 'raises ArgumentCoercionError when the resource key itself is absent (required: true default)' do
        instance = instance_for(controller, action: :create, params: {'page' => 2})

        expect { instance.arguments }.to raise_error(GraphQL::Derivation::Rails::ArgumentCoercionError)
      end
    end

    # Reproduces a real production failure (not caught by any other spec here,
    # since every other example stubs `params` as a bare Hash containing only
    # the fields under test). A real Rails `params` always includes routing
    # internals (`controller`, `action`) and every dynamic route segment
    # (e.g. `engagement_id` for a nested resource route), regardless of
    # whether any of them are declared as arguments -- SPEC.md §8.1
    # "Unknown top-level keys are silently ignored, not a validation error".
    context 'with real-Rails-style extraneous top-level params (controller/action/route segments)' do
      let(:controller) do
        build_controller do
          resource_arguments :time_off_request do
            argument :start_date, String, required: true
          end
          def create; end
        end
      end

      it 'ignores controller/action/route-segment keys instead of raising ArgumentCoercionError' do
        params = ActionController::Parameters.new(
          'controller' => 'team_members/time_offs',
          'action' => 'create',
          'engagement_id' => '123',
          'timeOffRequest' => {'startDate' => '2024-01-01'},
        )
        instance = instance_for(controller, action: :create, params: params)

        expect(instance.arguments).to eq(time_off_request: {start_date: '2024-01-01'})
      end
    end

    context 'with required: false' do
      let(:controller) do
        build_controller do
          resource_arguments :expense, required: false do
            argument :title, String, required: true
          end
          def create; end
        end
      end

      it 'omits the resource key from #arguments when the client sends nothing for it' do
        instance = instance_for(controller, action: :create, params: {})

        expect(instance.arguments).to eq({})
      end
    end

    describe 'the auto-generated resource_params helper' do
      let(:controller) do
        build_controller do
          resource_arguments :expense do
            argument :title, String, required: true
          end
          def create; end
        end
      end

      it 'is equivalent to arguments[key]' do
        instance = instance_for(controller, action: :create, params: {'expense' => {'title' => 'Lunch'}})

        expect(instance.send(:expense_params)).to eq(title: 'Lunch')
      end

      it 'is private, matching the Rails strong-parameters naming convention' do
        expect(controller.private_method_defined?(:expense_params)).to be(true)
      end
    end

    it 'raises ConfigurationError when nesting a resource_arguments block inside another' do
      expect do
        build_controller do
          resource_arguments :outer do
            resource_arguments :inner do
              argument :title, String, required: true
            end
          end
          def create; end
        end
      end.to raise_error(GraphQL::Derivation::ConfigurationError, /nested resource_arguments/)
    end

    it 'raises ConfigurationError when the same resource_arguments key is declared twice for one action' do
      expect do
        build_controller do
          resource_arguments(:expense) { argument :title, String, required: true }
          resource_arguments(:expense) { argument :description, String, required: false }
          def create; end
        end
      end.to raise_error(GraphQL::Derivation::ConfigurationError, /already declared/)
    end

    it 'raises ConfigurationError when a resource_arguments key collides with a flat argument' do
      expect do
        build_controller do
          argument :expense, String, required: false
          resource_arguments(:expense) { argument :title, String, required: true }
          def create; end
        end
      end.to raise_error(GraphQL::Derivation::ConfigurationError, /collides/)
    end

    it 'makes the nested InputObject and its arguments visible in the ArgumentSchema SDL' do
      controller = build_controller(namespace: :resource_sdl) do
        resource_arguments :expense do
          argument :title, String, required: true
          argument :amount_cents, GraphQL::Types::Int, required: true
        end
        def create; end
      end
      controller.eager_load_argument_sources!

      sdl = GraphQL::Derivation::Rails::ArgumentSchema.for(:resource_sdl).to_definition

      expect(sdl).to include('title: String!').and include('amountCents: Int!')
    end
  end

  describe '#arguments on a host with no #params method (SPEC.md §8.1 "controllers may override this")' do
    it 'treats the request input as empty instead of raising' do
      klass = Class.new do
        include GraphQL::Derivation::Rails::ControllerConcern
      end
      klass.argument_namespace(:no_params_host)
      klass.class_eval do
        argument :nickname, String, required: false
        def create; end
        def action_name = 'create'
      end

      instance = klass.new

      expect(instance.arguments).to eq({})
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

  describe '.resolve_sibling_arguments' do
    it 'raises ConfigurationError when the referenced sibling action is not registered' do
      controller = build_controller do
        arguments_from(:nonexistent) { |pick| pick.optional(:title) }
        def create; end
      end

      expect { controller.resolve_sibling_arguments(:nonexistent) }.to raise_error(
        GraphQL::Derivation::ConfigurationError,
        /arguments_from references sibling action "nonexistent".*no such action is registered/m,
      )
    end
  end

  describe '.resolve_action_input_object!' do
    it 'is a no-op for an action with no registered InputObject' do
      controller = build_controller do
        def create; end
      end

      expect { controller.resolve_action_input_object!(:create) }.not_to raise_error
    end
  end

  describe 'argument_namespace inheritance' do
    it 'falls back to :default when neither the class nor any ancestor called argument_namespace' do
      klass = Class.new(ActionController::Base) do
        include GraphQL::Derivation::Rails::ControllerConcern
      end

      expect(klass.resolved_argument_namespace).to eq(:default)
    end

    it 'inherits the ancestor-resolved namespace when a subclass never calls argument_namespace itself' do
      base = build_controller(namespace: :inherited_namespace)
      child = Class.new(base)

      expect(child.resolved_argument_namespace).to eq(:inherited_namespace)
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
