# frozen_string_literal: true

require 'action_controller'
require 'graphql/derivation/rails'

# Proves that a pending `derive_from` resolves on the paths graphql-ruby
# REALLY reads a type through -- schema build, SDL dump, introspection,
# validation, execution -- under both the legacy `Warden` and
# `GraphQL::Schema::Visibility`, with no `resolve_all!` anywhere. The mixin
# spec files cover the per-class `.fields` / `.arguments` reads; this file
# exists because those direct reads are exactly the thing graphql-ruby does
# NOT do internally (it walks `own_fields` / `own_arguments` on each
# ancestor), so a hook that only worked for them would pass every unit spec
# and still ship a schema with the derived members missing.
#
# rubocop:disable RSpec/DescribeClass -- cross-cutting: the subject is the
# interaction between both mixins, the guard and graphql-ruby's schema
# machinery, not one class.
RSpec.describe 'Lazy derivation resolution on first use' do
  around do |example|
    original_inputs = GraphQL::Derivation::DerivableInputObject.included_classes.dup
    original_objects = GraphQL::Derivation::DerivableObjectType.included_classes.dup
    GraphQL::Derivation::DerivableInputObject.included_classes.clear
    GraphQL::Derivation::DerivableObjectType.included_classes.clear
    GraphQL::Derivation::Rails::ArgumentSchema.reset!
    example.run
    GraphQL::Derivation::DerivableInputObject.included_classes.replace(original_inputs)
    GraphQL::Derivation::DerivableObjectType.included_classes.replace(original_objects)
    GraphQL::Derivation::Rails::ArgumentSchema.reset!
  end

  def build_object_type(name, &block)
    Class.new(GraphQL::Schema::Object) do
      include GraphQL::Derivation::DerivableObjectType

      graphql_name name
      class_eval(&block) if block
    end
  end

  def build_input_object(name, &block)
    Class.new(GraphQL::Schema::InputObject) do
      include GraphQL::Derivation::DerivableInputObject

      graphql_name name
      class_eval(&block) if block
    end
  end

  def build_schema(query_type, mutation_type: nil, visibility: false)
    Class.new(GraphQL::Schema) do
      query(query_type)
      mutation(mutation_type) if mutation_type
      use GraphQL::Schema::Visibility if visibility
    end
  end

  def skip_unless_visibility_available
    return if defined?(GraphQL::Schema::Visibility)

    skip 'GraphQL::Schema::Visibility is not available on this graphql-ruby version'
  end

  shared_examples 'a schema that resolves derivations on first use' do |visibility:|
    # `status` (an enum) and `amount` (a custom scalar) are referenced by
    # NOTHING else in this schema. If the derivation ran after graphql-ruby
    # built its type map, both types would be missing from the schema and
    # the fields would be silently dropped as unreachable.
    let(:pick_calls) { Hash.new(0) }
    let(:derived_expense) do
      calls = pick_calls
      build_object_type('LazyExpense') do
        field :inline_only, String, null: true

        derive_from FixtureSchema::ExpenseType do |pick|
          calls[:object] += 1
          pick.fields(:title, :description, :status)
        end
      end
    end
    let(:derived_input) do
      calls = pick_calls
      build_input_object('LazyExpenseInput') do
        argument :inline_only, String, required: false

        derive_from FixtureSchema::ExpenseType do |pick|
          calls[:input] += 1
          pick.required(:title)
          pick.optional(:amount)
        end
      end
    end
    let(:query_type) do
      expense_type = derived_expense
      input_type = derived_input
      Class.new(GraphQL::Schema::Object) do
        graphql_name 'Query'

        field :expense, expense_type, null: true do
          argument :input, input_type, required: false
        end

        def expense(input: nil)
          {
            title: input ? input[:title] : 'default',
            status: 'APPROVED',
            inline_only: input && input[:inline_only],
          }
        end
      end
    end
    let(:schema) { build_schema(query_type, visibility: visibility) }

    before { skip_unless_visibility_available if visibility }

    it 'prints the derived members and their otherwise-unreferenced types in the SDL' do
      sdl = schema.to_definition

      expect(sdl).to include(
        'title: String!',
        'status: ExpenseStatusEnum!',
        'enum ExpenseStatusEnum',
        'amount: MoneyAmount',
      )
        .and include('scalar MoneyAmount')
    end

    it 'lists the derived fields through introspection' do
      result = schema.execute('{ __type(name: "LazyExpense") { fields { name } } }')

      names = result.dig('data', '__type', 'fields').map { |f| f['name'] }
      expect(names).to contain_exactly('inlineOnly', 'title', 'description', 'status')
    end

    it 'lists the derived arguments through introspection' do
      result = schema.execute('{ __type(name: "LazyExpenseInput") { inputFields { name } } }')

      names = result.dig('data', '__type', 'inputFields').map { |f| f['name'] }
      expect(names).to contain_exactly('inlineOnly', 'title', 'amount')
    end

    it 'validates and executes the very first request against derived fields and arguments' do
      result = schema.execute(
        '{ expense(input: {title: "Lunch", amount: 12, inlineOnly: "x"}) { title status inlineOnly } }',
      )

      expect(result.to_h).to eq('data' => {'expense' => {
        'title' => 'Lunch',
        'status' => 'APPROVED',
        'inlineOnly' => 'x',
      }})
    end

    it 'runs each pick block exactly once across build, SDL, introspection and execution' do
      schema.to_definition
      schema.execute('{ __type(name: "LazyExpense") { fields { name } } }')
      schema.execute('{ expense(input: {title: "a"}) { title } }')

      expect(pick_calls).to eq(object: 1, input: 1)
    end
  end

  describe 'under the legacy Warden (default)' do
    include_examples 'a schema that resolves derivations on first use', visibility: false
  end

  describe 'under GraphQL::Schema::Visibility' do
    include_examples 'a schema that resolves derivations on first use', visibility: true
  end

  describe 'subclass of a derivable ObjectType' do
    let(:base) do
      build_object_type('LazyBaseExpense') do
        derive_from(FixtureSchema::ExpenseType) { |pick| pick.fields(:title) }
      end
    end
    let(:child) do
      Class.new(base) do
        graphql_name 'LazyChildExpense'
        field :extra, String, null: true
      end
    end
    let(:schema) do
      child_type = child
      query_type = Class.new(GraphQL::Schema::Object) do
        graphql_name 'Query'
        field :child, child_type, null: true

        def child
          {title: 'inherited', extra: 'own'}
        end
      end
      build_schema(query_type)
    end

    it "resolves the parent's pending derivation when the subclass's fields are read" do
      expect(child.fields.keys).to contain_exactly('extra', 'title')
    end

    it 'serves the inherited derived field on the first request' do
      result = schema.execute('{ child { title extra } }')

      expect(result.to_h).to eq('data' => {'child' => {'title' => 'inherited', 'extra' => 'own'}})
    end
  end

  describe 'a resolution that raises' do
    context 'when the pick block fails once' do
      let(:attempts) { [] }
      let(:input) do
        tries = attempts
        build_input_object('LazyFlakyInput') do
          derive_from FixtureSchema::ExpenseType do |pick|
            tries << :attempt
            raise 'transient failure' if tries.size == 1

            pick.required(:title)
          end
        end
      end

      it 'surfaces the error on the first read' do
        expect { input.arguments }.to raise_error(RuntimeError, 'transient failure')
      end

      it 'stays pending, so the next read retries instead of serving a half-derived type' do
        begin
          input.arguments
        rescue RuntimeError
          nil
        end

        expect(input.arguments.keys).to contain_exactly('title')
      end
    end

    context 'when two classes form a cycle' do
      let(:a) { build_input_object('LazyCycleA') { argument :a_inline, String, required: false } }
      let(:b) { build_input_object('LazyCycleB') { argument :b_inline, String, required: false } }

      before do
        a.derive_from(b) { |pick| pick.required(:b_inline) }
        b.derive_from(a) { |pick| pick.required(:a_inline) }
        begin
          a.arguments
        rescue GraphQL::Derivation::CyclicDependencyError
          nil
        end
      end

      it 'keeps raising from the class that was read first' do
        expect { a.arguments }.to raise_error(GraphQL::Derivation::CyclicDependencyError)
      end

      it 'keeps raising from the class that was reached through the cycle, instead of going quiet' do
        expect { b.arguments }.to raise_error(GraphQL::Derivation::CyclicDependencyError)
      end

      it 'drains the guard stack after the raise' do
        expect(GraphQL::Derivation::DerivationResolutionGuard.in_progress).to be_empty
      end
    end
  end

  describe 'concurrent first reads' do
    # Everything the threads touch is resolved into locals BEFORE they start:
    # RSpec `let`s take RSpec's own memoization mutex, and a thread blocking
    # on that while another holds the gem's resolution lock would be a
    # lock-order deadlock in the spec itself, not in the code under test.
    shared_examples 'a class every thread sees fully derived' do |reader|
      let(:pick_calls) { [] }
      let(:results) do
        klass = derivable
        Array.new(4) { Thread.new { klass.public_send(reader).keys } }.map(&:value)
      end

      it 'gives every thread the fully derived set' do
        expect(results).to all(contain_exactly('inlineOnly', 'title', 'amountCents'))
      end

      it 'runs the pick block once' do
        results

        expect(pick_calls.size).to eq(1)
      end
    end

    context 'with a DerivableInputObject' do
      let(:derivable) do
        calls = pick_calls
        build_input_object('LazyConcurrentInput') do
          argument :inline_only, String, required: false

          derive_from FixtureSchema::ExpenseType do |pick|
            calls << :call
            sleep 0.05 # widen the window in which a second thread could observe a half-resolved class
            pick.required(:title, :amount_cents)
          end
        end
      end

      include_examples 'a class every thread sees fully derived', :arguments
    end

    context 'with a DerivableObjectType' do
      let(:derivable) do
        calls = pick_calls
        build_object_type('LazyConcurrentExpense') do
          field :inline_only, String, null: true

          derive_from FixtureSchema::ExpenseType do |pick|
            calls << :call
            sleep 0.05
            pick.fields(:title, :amount_cents)
          end
        end
      end

      include_examples 'a class every thread sees fully derived', :fields
    end

    it 'does not deadlock when two threads start at opposite ends of the same chain' do
      b = build_input_object('LazyChainB')
      a = build_input_object('LazyChainA')
      b.derive_from(FixtureSchema::ExpenseType) do |pick|
        sleep 0.05
        pick.required(:title, :amount_cents)
      end
      a.derive_from(b) do |pick|
        sleep 0.05
        pick.required(:title)
      end

      threads = [Thread.new { a.arguments.keys }, Thread.new { b.arguments.keys }]

      # `join(5)` returns nil on timeout, so a deadlock shows up as `[nil, nil]`.
      expect(threads.map { |thread| thread.join(5)&.value }).to eq([['title'], %w[title amountCents]])
    end
  end

  describe 'Rails ControllerConcern-generated InputObjects' do
    def build_controller(&class_body)
      klass = Class.new(ActionController::Base) do
        include GraphQL::Derivation::Rails::ControllerConcern
      end
      klass.argument_namespace(:lazy_spec)
      klass.class_eval(&class_body)
      klass
    end

    it 'loads a class combining a sibling arguments_from with resource_arguments on one action' do
      controller = build_controller do
        argument :title, String, required: true
        def create; end

        arguments_from(:create) { |pick| pick.required :title }
        resource_arguments(:expense) { argument :note, String, required: false }
        def update; end
      end

      expect(controller.argument_input_object_for(:update).arguments.keys).to contain_exactly('expense', 'title')
    end

    it 'does not evaluate a forward sibling reference while the class body is still being defined' do
      controller = build_controller do
        arguments_from(:update) { |pick| pick.required :title }
        resource_arguments(:expense) { argument :note, String, required: false }
        def create; end

        argument :title, String, required: true
        def update; end
      end

      expect(controller.argument_input_object_for(:create).arguments.keys).to contain_exactly('expense', 'title')
    end

    it 'resolves a sibling source from a plain SDL dump, with no eager_load_argument_sources!' do
      controller = build_controller do
        argument :title, String, required: true
        def create; end

        arguments_from(:create) { |pick| pick.required :title }
        def update; end
      end

      sdl = GraphQL::Derivation::Rails::ArgumentSchema.for(:lazy_spec).to_definition

      update_input_name = "#{controller.name}UpdateInput".delete(':')
      expect(sdl).to match(/input #{update_input_name} \{\s+title: String!\s+\}/)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
