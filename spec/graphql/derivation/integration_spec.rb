# frozen_string_literal: true

require 'action_controller'
require 'graphql/derivation/rails/active_record'

# Full-stack composition proof: an ActiveRecord model's columns flow through
# the ActiveRecord adapter (SPEC.md §9) and `FieldDerivation` (§5) into a
# `DerivableObjectType` (§7), which is then used as an `arguments_from`
# source (§4/§8) on a Rails controller, all the way through to a coerced
# Ruby argument hash via `ArgumentSchema` (§8). Every layer here already has
# its own dedicated spec file with exhaustive coverage of its own rules
# (column type mapping, pick DSL validation, collision detection, cyclic
# sibling detection, etc.) -- this spec exists solely to prove the layers
# genuinely compose end-to-end, not to re-test any single layer's rules.
#
# rubocop:disable RSpec/DescribeClass -- there is no single class under test
# here (the point of this spec is that several classes across the AR
# adapter, FieldDerivation, DerivableObjectType, and the Rails plugin
# compose correctly); every other integration-style spec in this repo
# describes one real class, but this one is deliberately cross-cutting.
RSpec.describe 'Full-stack integration (AR -> DerivableObjectType -> ControllerConcern)' do
  # `DerivableObjectType.included_classes` and `ArgumentSchema`'s registry
  # are module-level state shared with `derivable_object_type_spec.rb` and
  # `controller_concern_spec.rb` in the same run -- reset around every
  # example (not just before/after all) so a failure mid-example can't leak
  # a half-registered class into a sibling spec file's `resolve_all!`.
  around do |example|
    original_included_classes = GraphQL::Derivation::DerivableObjectType.included_classes.dup
    GraphQL::Derivation::DerivableObjectType.included_classes.clear
    GraphQL::Derivation::Rails::ArgumentSchema.reset!
    example.run
    GraphQL::Derivation::DerivableObjectType.included_classes.replace(original_included_classes)
    GraphQL::Derivation::Rails::ArgumentSchema.reset!
  end

  # `FixtureSchema::Expense` (SPEC.md §10.5) is deliberately a plain Ruby
  # stand-in, not a real `ActiveRecord::Base` subclass -- so it cannot be
  # passed directly to `derive_from` (which dispatches on `source <
  # ActiveRecord::Base`, per `FieldDerivation.active_record_source?`). As
  # `field_derivation_spec.rb`'s "real ActiveRecord model source" context
  # already does, a tiny real `ActiveRecord::Base` subclass is defined here
  # purely to satisfy that ancestry check, delegating `.columns`/
  # `.defined_enums` to the existing stub.
  let(:expense_model) do
    Class.new(ActiveRecord::Base) do
      def self.columns
        FixtureSchema::Expense.columns
      end

      def self.defined_enums
        FixtureSchema::Expense.defined_enums
      end

      def self.name
        'Expense'
      end
    end
  end

  def build_object_type(model)
    Class.new(GraphQL::Schema::Object) do
      include GraphQL::Derivation::DerivableObjectType

      graphql_name "IntegrationExpenseType#{object_id}"

      derive_from model do |pick|
        pick.fields :title, :amount_cents, :category, :team_member_id
      end
    end
  end

  def build_controller_class
    Class.new(ActionController::Base) do
      include GraphQL::Derivation::Rails::ControllerConcern
    end
  end

  def build_controller(object_type, namespace:)
    klass = build_controller_class
    klass.argument_namespace(namespace)
    klass.class_eval do
      arguments_from(object_type) do |pick|
        pick.required :title
        pick.optional :amount_cents, :category
      end
      def create; end
    end
    klass
  end

  def instance_for(controller_class, action:, params: {})
    instance = controller_class.new
    allow(instance).to receive_messages(action_name: action.to_s, params: params)
    instance
  end

  describe 'happy path' do
    it 'resolves the coerced argument hash through the full stack' do
      object_type = build_object_type(expense_model)
      GraphQL::Derivation::DerivableObjectType.resolve_all!

      controller = build_controller(object_type, namespace: :integration_happy)
      controller.eager_load_argument_sources!

      instance = instance_for(
        controller,
        action: :create,
        params: {'title' => 'Team offsite', 'amountCents' => 50_000, 'category' => 'TRAVEL'},
      )

      # Empirically confirmed (not assumed): the ActiveRecord adapter builds
      # its generated enum values via `value(value.upcase)` with no
      # explicit `value:` keyword (active_record_mapper.rb), so graphql-ruby
      # defaults the Ruby-side value to the enum value's `graphql_name`
      # itself -- coercion yields the upcased *String* "TRAVEL", not a
      # lowercase Symbol.
      expect(instance.arguments).to eq(
        title: 'Team offsite',
        amount_cents: 50_000,
        category: 'TRAVEL',
      )
    end

    describe 'argument value Ruby types' do
      subject(:result) do
        object_type = build_object_type(expense_model)
        GraphQL::Derivation::DerivableObjectType.resolve_all!

        controller = build_controller(object_type, namespace: :integration_types)
        instance_for(
          controller,
          action: :create,
          params: {'title' => 'Lunch', 'amountCents' => 1200, 'category' => 'FOOD'},
        ).arguments
      end

      it 'coerces title to a String' do
        expect(result[:title]).to be_a(String)
      end

      it 'coerces amount_cents to an Integer' do
        expect(result[:amount_cents]).to be_a(Integer)
      end

      it 'coerces category to a String' do
        expect(result[:category]).to be_a(String)
      end
    end
  end

  describe 'failure path' do
    it 'raises ArgumentParsingError when the required title argument is missing' do
      object_type = build_object_type(expense_model)
      GraphQL::Derivation::DerivableObjectType.resolve_all!

      controller = build_controller(object_type, namespace: :integration_failure)
      instance = instance_for(
        controller, action: :create, params: {'amountCents' => 1200},
      )

      expect { instance.arguments }
        .to raise_error(GraphQL::Derivation::Rails::ArgumentParsingError)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
