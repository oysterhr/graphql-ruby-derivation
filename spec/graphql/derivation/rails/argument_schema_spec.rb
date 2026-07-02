# frozen_string_literal: true

require 'graphql/derivation/rails'

RSpec.describe GraphQL::Derivation::Rails::ArgumentSchema do
  # Explicit constant, not `described_class` -- the nested `NullQueryContext`
  # describe block below has a different `described_class`, but still needs
  # this same schema-registry reset.
  before { GraphQL::Derivation::Rails::ArgumentSchema.reset! }
  after { GraphQL::Derivation::Rails::ArgumentSchema.reset! }

  describe '.for' do
    it 'returns the same schema class across calls for one namespace' do
      expect(described_class.for(:team_members)).to equal(described_class.for(:team_members))
    end

    it 'returns distinct schema classes for distinct namespaces' do
      expect(described_class.for(:a)).not_to equal(described_class.for(:b))
    end

    it 'returns a GraphQL::Schema subclass' do
      expect(described_class.for(:a).ancestors).to include(GraphQL::Schema)
    end

    it 'collapses a nil namespace to the default namespace' do
      expect(described_class.for(nil)).to equal(described_class.for(:default))
    end
  end

  describe 'extra type registration' do
    let(:input_object) do
      Class.new(GraphQL::Schema::InputObject) do
        graphql_name 'WidgetCreateInput'
        argument :title, String, required: true
      end
    end

    it 'records the registered InputObject' do
      schema = described_class.for(:widgets)
      schema.register_input_object(input_object)

      expect(schema.registered_input_objects).to include(input_object)
    end

    it 'makes the InputObject appear in the schema SDL (introspectable for codegen)' do
      schema = described_class.for(:widgets)
      schema.register_input_object(input_object)

      expect(schema.to_definition).to include('WidgetCreateInput')
    end

    it 'is idempotent when the same InputObject is registered twice' do
      schema = described_class.for(:widgets)
      schema.register_input_object(input_object)
      schema.register_input_object(input_object)

      expect(schema.registered_input_objects.count(input_object)).to eq(1)
    end
  end

  # SPEC.md §8.2 "Introspection design": a top-level InputObject whose own
  # argument is ANOTHER InputObject (the `resource_arguments` case, SPEC.md
  # §8.1) must print correctly -- both the type itself and every one of its
  # scalar arguments. graphql-ruby's own `extra_types` mechanism cannot make
  # this reachable at all (InputObject can't be a field return type, so the
  # dummy-field trick `extra_types` relies on internally skips InputObject
  # entries entirely); only registering the *outer* InputObject and letting
  # normal root-based reachability do the rest (this schema's actual design)
  # makes it work.
  describe 'reachability of a nested InputObject argument (multi-argument, multi-type)' do
    let(:nested_input_object) do
      Class.new(GraphQL::Schema::InputObject) do
        graphql_name 'WidgetNestedInput'
        argument :title, String, required: true
        argument :amount_cents, GraphQL::Types::Int, required: true
      end
    end

    let(:outer_input_object) do
      nested = nested_input_object
      Class.new(GraphQL::Schema::InputObject) do
        graphql_name 'WidgetOuterInput'
        argument :widget, nested, required: true
      end
    end

    it 'prints the outer InputObject with its nested-InputObject-typed argument' do
      schema = described_class.for(:widgets)
      schema.register_input_object(outer_input_object)

      expect(schema.to_definition).to include('widget: WidgetNestedInput!')
    end

    it 'prints the nested InputObject with every one of its own arguments' do
      schema = described_class.for(:widgets)
      schema.register_input_object(outer_input_object)

      sdl = schema.to_definition
      expect(sdl).to include('title: String!').and include('amountCents: Int!')
    end

    it 'does not require the nested InputObject to be separately registered' do
      schema = described_class.for(:widgets)
      schema.register_input_object(outer_input_object)

      expect(schema.registered_input_objects).to contain_exactly(outer_input_object)
    end
  end

  describe 'reload safety (dedup by graphql_name, not object identity)' do
    def build_input_object(name)
      Class.new(GraphQL::Schema::InputObject) do
        graphql_name name
        argument :title, String, required: true
      end
    end

    it 'replaces a previously-registered InputObject that shares the same graphql_name' do
      schema = described_class.for(:widgets)
      first = build_input_object('TeamMembersCreateInput')
      second = build_input_object('TeamMembersCreateInput')

      schema.register_input_object(first)
      schema.register_input_object(second)

      matching = schema.registered_input_objects.select { |type| type.graphql_name == 'TeamMembersCreateInput' }
      expect(matching).to contain_exactly(second)
    end

    it 'keeps only the most recently registered class for a re-registered graphql_name' do
      schema = described_class.for(:widgets)
      first = build_input_object('TeamMembersCreateInput')
      second = build_input_object('TeamMembersCreateInput')

      schema.register_input_object(first)
      schema.register_input_object(second)

      expect(schema.registered_input_objects).not_to include(first)
    end

    it 'does not raise when to_definition is called after a same-name re-registration' do
      schema = described_class.for(:widgets)
      first = build_input_object('TeamMembersCreateInput')
      second = build_input_object('TeamMembersCreateInput')

      schema.register_input_object(first)
      schema.register_input_object(second)

      expect { schema.to_definition }.not_to raise_error
    end

    it 'prints the re-registered type exactly once in the schema SDL' do
      schema = described_class.for(:widgets)
      first = build_input_object('TeamMembersCreateInput')
      second = build_input_object('TeamMembersCreateInput')

      schema.register_input_object(first)
      schema.register_input_object(second)

      expect(schema.to_definition.scan('input TeamMembersCreateInput').count).to eq(1)
    end

    it 'does not disturb a differently-named InputObject already registered' do
      schema = described_class.for(:widgets)
      other = build_input_object('TeamMembersUpdateInput')
      first = build_input_object('TeamMembersCreateInput')
      second = build_input_object('TeamMembersCreateInput')

      schema.register_input_object(other)
      schema.register_input_object(first)
      schema.register_input_object(second)

      expect(schema.registered_input_objects).to include(other)
    end
  end

  # Approximates a real Zeitwerk reload more closely than a bare
  # object-identity swap: the "before" and "after" class objects are bound to
  # the SAME constant name (as `stub_const` rebinds a real autoloaded
  # constant across a reload cycle -- `RSpec/RemoveConst` rules out
  # `remove_const` directly in specs), while remaining distinct Ruby objects
  # with the SAME `graphql_name`, exactly as `ControllerConcern#build_input_object`
  # regenerates a fresh anonymous class with a stable computed name on every
  # reload.
  describe 'reload safety across a stubbed constant rebind (Zeitwerk-reload approximation)' do
    def build_input_object(name)
      Class.new(GraphQL::Schema::InputObject) do
        graphql_name name
        argument :title, String, required: true
      end
    end

    let(:schema) { described_class.for(:widgets) }

    before do
      stub_const('TmpReloadableInput', build_input_object('TmpReloadableInput'))
      schema.register_input_object(TmpReloadableInput)
    end

    it 'rebinds the constant to a genuinely different class object after a second reload' do
      original_object_id = TmpReloadableInput.object_id
      stub_const('TmpReloadableInput', build_input_object('TmpReloadableInput'))

      expect(TmpReloadableInput.object_id).not_to eq(original_object_id)
    end

    it 'keeps exactly the current (post-rebind) class object registered under that name' do
      stub_const('TmpReloadableInput', build_input_object('TmpReloadableInput'))
      schema.register_input_object(TmpReloadableInput)

      matching = schema.registered_input_objects.select { |type| type.graphql_name == 'TmpReloadableInput' }
      expect(matching).to contain_exactly(TmpReloadableInput)
    end

    it 'does not raise when the schema is rendered after a rebind-and-re-register' do
      stub_const('TmpReloadableInput', build_input_object('TmpReloadableInput'))
      schema.register_input_object(TmpReloadableInput)

      expect { schema.to_definition }.not_to raise_error
    end
  end

  describe '.coercion_context' do
    it 'is bound to the namespace schema so all argument types are visible' do
      schema = described_class.for(:widgets)

      expect(schema.coercion_context.schema).to equal(schema)
    end
  end

  # SPEC.md §8.2 "graphql-ruby version compatibility": `GraphQL::Query::
  # NullContext` cannot be used here on any graphql-ruby version this gem
  # supports (its `.new` stays private/Singleton-bound through at least
  # 2.5.x), so `NullQueryContext` is this gem's own permanent replacement.
  # This exercises its contract directly, independent of the coercion tests
  # elsewhere that only exercise it indirectly.
  describe GraphQL::Derivation::Rails::ArgumentSchema::NullQueryContext do
    subject(:context) { described_class.new(schema: schema) }

    let(:schema) { GraphQL::Derivation::Rails::ArgumentSchema.for(:widgets) }

    it 'exposes the schema it was built for' do
      expect(context.schema).to equal(schema)
    end

    it 'exposes a warden whose #arguments resolves an InputObject class own argument set' do
      input_object = Class.new(GraphQL::Schema::InputObject) do
        graphql_name 'NullQueryContextWidgetInput'
        argument :title, String, required: true
      end

      expect(context.warden.arguments(input_object).map(&:graphql_name)).to contain_exactly('title')
    end

    it 'treats every argument as visible via the warden (all-types-visible semantics)' do
      argument = GraphQL::Schema::Argument.new(:title, String, owner: nil, required: true)
      expect(context.warden.visible_argument?(argument)).to be(true)
    end

    it 'exposes a visibility profile via #types, backed by the same warden' do
      # `#types` is only ever called by graphql-ruby versions whose own
      # `coerce_arguments` calls it (>= 2.4 -- see the class docs); on older
      # versions `warden.visibility_profile` genuinely does not exist, and
      # `#types` is correctly never reached in practice.
      skip 'warden has no visibility_profile on this graphql-ruby version' \
        unless context.warden.respond_to?(:visibility_profile)

      expect(context.types.arguments(GraphQL::Schema::InputObject)).to eq([])
    end

    it 'runs #query.after_lazy synchronously with the given value' do
      expect(context.query.after_lazy(:already_resolved) { |v| v }).to eq(:already_resolved)
    end

    it 'runs dataloader jobs synchronously via #dataloader.append_job' do
      ran = false
      context.dataloader.append_job { ran = true }

      expect(ran).to be(true)
    end

    it 'returns nil for an unset key via #[]' do
      expect(context[:anything]).to be_nil
    end

    it 'returns the given default via #fetch' do
      expect(context.fetch(:anything, :default)).to eq(:default)
    end

    it 'returns nil via #dig' do
      expect(context.dig(:anything, :nested)).to be_nil
    end

    it 'returns false via #key?' do
      expect(context.key?(:anything)).to be(false)
    end

    it 'returns an empty Hash via #to_h' do
      expect(context.to_h).to eq({})
    end
  end
end
