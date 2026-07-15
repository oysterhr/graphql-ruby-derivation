# frozen_string_literal: true

require 'graphql/derivation/rails/active_record'

RSpec.describe GraphQL::Derivation::Rails do
  describe '.reset_for_reload!' do
    around do |example|
      original_input_object_classes = GraphQL::Derivation::DerivableInputObject.included_classes.dup
      original_object_type_classes = GraphQL::Derivation::DerivableObjectType.included_classes.dup
      original_enum_cache = GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper.enum_cache.dup
      GraphQL::Derivation::Rails::ArgumentSchema.reset!

      example.run

      GraphQL::Derivation::DerivableInputObject.included_classes.replace(original_input_object_classes)
      GraphQL::Derivation::DerivableObjectType.included_classes.replace(original_object_type_classes)
      GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper.enum_cache.replace(original_enum_cache)
      GraphQL::Derivation::Rails::ArgumentSchema.reset!
    end

    it 'has a non-empty DerivableInputObject.included_classes before reset (sanity check)' do
      Class.new(GraphQL::Schema::InputObject) { include GraphQL::Derivation::DerivableInputObject }

      expect(GraphQL::Derivation::DerivableInputObject.included_classes).not_to be_empty
    end

    it 'clears DerivableInputObject.included_classes' do
      Class.new(GraphQL::Schema::InputObject) { include GraphQL::Derivation::DerivableInputObject }

      described_class.reset_for_reload!

      expect(GraphQL::Derivation::DerivableInputObject.included_classes).to be_empty
    end

    it 'has a non-empty DerivableObjectType.included_classes before reset (sanity check)' do
      Class.new(GraphQL::Schema::Object) { include GraphQL::Derivation::DerivableObjectType }

      expect(GraphQL::Derivation::DerivableObjectType.included_classes).not_to be_empty
    end

    it 'clears DerivableObjectType.included_classes' do
      Class.new(GraphQL::Schema::Object) { include GraphQL::Derivation::DerivableObjectType }

      described_class.reset_for_reload!

      expect(GraphQL::Derivation::DerivableObjectType.included_classes).to be_empty
    end

    it 'forgets cached per-namespace ArgumentSchemas' do
      schema = GraphQL::Derivation::Rails::ArgumentSchema.for(:reset_for_reload_spec)

      described_class.reset_for_reload!

      expect(GraphQL::Derivation::Rails::ArgumentSchema.for(:reset_for_reload_spec)).not_to equal(schema)
    end

    it 'has a non-empty ActiveRecordMapper.enum_cache before reset (sanity check)' do
      GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper.candidates(FixtureSchema::Expense).fetch(:category).type

      expect(GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper.enum_cache).not_to be_empty
    end

    it 'clears ActiveRecordMapper.enum_cache' do
      GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper.candidates(FixtureSchema::Expense).fetch(:category).type

      described_class.reset_for_reload!

      expect(GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper.enum_cache).to be_empty
    end

    it 'does not touch ActiveRecordMapper when the optional AR adapter was never required' do
      hide_const('GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper')

      expect { described_class.reset_for_reload! }.not_to raise_error
    end
  end
end
