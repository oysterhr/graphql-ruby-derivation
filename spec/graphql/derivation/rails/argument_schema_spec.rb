# frozen_string_literal: true

require 'graphql/derivation/rails'

RSpec.describe GraphQL::Derivation::Rails::ArgumentSchema do
  before { described_class.reset! }
  after { described_class.reset! }

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

  describe 'orphan type registration' do
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
end
