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

  describe '.coercion_context' do
    it 'is bound to the namespace schema so all argument types are visible' do
      schema = described_class.for(:widgets)

      expect(schema.coercion_context.schema).to equal(schema)
    end
  end
end
