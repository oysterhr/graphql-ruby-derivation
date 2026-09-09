# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::DerivableObjectType do
  around do |example|
    original = described_class.included_classes.dup
    described_class.included_classes.clear
    example.run
    described_class.included_classes.replace(original)
  end

  def build_derived(&block)
    Class.new(GraphQL::Schema::Object) do
      include GraphQL::Derivation::DerivableObjectType

      graphql_name "Lazy#{object_id}"
      class_eval(&block) if block
    end
  end

  describe 'lazy resolution' do
    let(:derived) do
      build_derived do
        derive_from(FixtureSchema::ExpenseType) { |pick| pick.fields(:title) }
        field :extra, String, null: true
      end
    end

    it 'resolves the derivation the first time fields is read' do
      expect(derived.fields.keys).to contain_exactly('title', 'extra')
    end

    it 'resolves the derivation the first time get_field is called' do
      expect(derived.get_field('title')).to be_a(GraphQL::Schema::Field)
    end

    it 'resolves the derivation the first time all_field_definitions is read' do
      expect(derived.all_field_definitions.map(&:graphql_name)).to contain_exactly('title', 'extra')
    end

    it 'leaves a class without derive_from alone' do
      plain = build_derived { field :extra, String, null: true }

      expect(plain.fields.keys).to eq(['extra'])
    end

    context 'when the derivation cannot resolve' do
      let(:broken) do
        build_derived do
          derive_from(FixtureSchema::ExpenseType) { |pick| pick.fields(:title) }
          field :title, String, null: true
        end
      end

      it 'raises on the first read' do
        expect { broken.fields }.to raise_error(GraphQL::Derivation::ConfigurationError)
      end

      it 'keeps raising on later reads instead of silently exposing a partial type' do
        begin
          broken.fields
        rescue GraphQL::Derivation::ConfigurationError
          nil
        end

        expect { broken.get_field('title') }.to raise_error(GraphQL::Derivation::ConfigurationError)
      end
    end
  end

  describe 'registration of subclasses' do
    it 'registers subclasses of an including base class for resolve_all!' do
      base = build_derived
      subclass = Class.new(base) do
        graphql_name 'Sub'
        derive_from(FixtureSchema::ExpenseType) { |pick| pick.fields(:title) }
      end

      described_class.resolve_all!

      expect([described_class.included_classes.include?(subclass), subclass.own_fields.keys]).to eq([true, ['title']])
    end
  end
end
