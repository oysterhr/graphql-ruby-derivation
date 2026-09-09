# frozen_string_literal: true

# Field Derivation behaviour that exists for *projections*: what happens to
# a picked field's return type when it is an Object type (an "edge"), inline
# nested projections (`pick.project`), and everything about a field that has
# to survive the copy for the derived type to behave like the source
# (arguments, extras, extensions, instance resolver methods, `connection:`).
RSpec.describe GraphQL::Derivation::FieldDerivation do
  around do |example|
    original = GraphQL::Derivation::DerivableObjectType.included_classes.dup
    GraphQL::Derivation::DerivableObjectType.included_classes.clear
    example.run
    GraphQL::Derivation::DerivableObjectType.included_classes.replace(original)
  end

  def resolve(source, destination: nil, &pick_block)
    described_class.resolve(source, pick_block, destination: destination)
  end

  def field_named(fields, graphql_name)
    fields.find { |field| field.graphql_name == graphql_name }
  end

  def build_type(base = GraphQL::Schema::Object, name: "Anon#{rand(1_000_000)}", &block)
    Class.new(base) do
      graphql_name name
      class_eval(&block) if block
    end
  end

  def build_projection(source, base = GraphQL::Schema::Object, name: source.graphql_name, &pick_block)
    Class.new(base) do
      include GraphQL::Derivation::DerivableObjectType

      graphql_name name
      derive_from(source, &pick_block)
    end
  end

  describe 'edge types' do
    it 'copies an Object-typed field as a ProjectedEdge carrying the source type name' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:billing_address) }

      expect(field_named(fields, 'billingAddress').type).to be_a(GraphQL::Derivation::ProjectedEdge).and(
        have_attributes(name: 'Address', canonical_type: FixtureSchema::AddressType),
      )
    end

    it 'keeps the List/NonNull wrapping around the edge' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:attachments) }
      type = field_named(fields, 'attachments').type

      expect(type.to_type_signature).to eq('[Address!]!')
    end

    it 'wraps a ProjectedEdge inside the List/NonNull layers' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:attachments) }

      expect(field_named(fields, 'attachments').type.unwrap).to be_a(GraphQL::Derivation::ProjectedEdge)
    end

    it 'records the destination and source field on the edge' do
      destination = build_type(name: 'Expense')
      fields = resolve(FixtureSchema::ExpenseType, destination: destination) { |pick| pick.fields(:billing_address) }
      edge = field_named(fields, 'billingAddress').type

      expect(edge).to have_attributes(
        destination: destination,
        source_field: FixtureSchema::ExpenseType.fields['billingAddress'],
        derived_field_path: 'Expense.billingAddress',
      )
    end

    it 'copies an enum field as-is (leaf types are not edges)' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:status) }

      expect(field_named(fields, 'status').type.unwrap).to eq(FixtureSchema::ExpenseStatusEnum)
    end

    it 'copies a scalar field as-is' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:title) }

      expect(field_named(fields, 'title').type).to eq(GraphQL::Types::String.to_non_null_type)
    end

    it 'passes an already late-bound edge through unchanged when the source is itself a projection' do
      first_hop = build_projection(FixtureSchema::ExpenseType, name: 'ExpenseA') { |pick| pick.fields(:billing_address) }

      fields = resolve(first_hop) { |pick| pick.fields(:billing_address) }

      expect(field_named(fields, 'billingAddress').type).to equal(first_hop.fields['billingAddress'].type)
    end
  end

  describe 'pick.override(name, type: ...)' do
    it 'copies the field with exactly the given type' do
      fields = resolve(FixtureSchema::ExpenseType) do |pick|
        pick.fields(:billing_address)
        pick.override(:billing_address, type: FixtureSchema::SyncConnectionType)
      end

      expect(field_named(fields, 'billingAddress').type).to eq(FixtureSchema::SyncConnectionType)
    end

    it 'keeps the source wrapping around the given type' do
      fields = resolve(FixtureSchema::ExpenseType) do |pick|
        pick.fields(:attachments)
        pick.override(:attachments, type: FixtureSchema::SyncConnectionType)
      end

      expect(field_named(fields, 'attachments').type.to_type_signature).to eq('[SyncConnection!]!')
    end
  end

  describe 'pick.expose_full' do
    it 'copies the field with the source return type unchanged' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.expose_full(:billing_address) }

      expect(field_named(fields, 'billingAddress').type).to eq(FixtureSchema::AddressType)
    end
  end

  describe 'pick.project' do
    let(:fields) do
      resolve(FixtureSchema::ExpenseType) do |pick|
        pick.project(:billing_address) { |address| address.fields(:city) }
      end
    end
    let(:nested_type) { field_named(fields, 'billingAddress').type }

    it 'builds an anonymous derived type named after the source type' do
      expect(nested_type).to be_a(Class).and(have_attributes(name: nil, graphql_name: 'Address'))
    end

    it 'derives only the nested picks onto the anonymous type' do
      expect(nested_type.fields.keys).to contain_exactly('city')
    end

    it 'includes DerivableObjectType on the anonymous type' do
      expect(nested_type).to be < GraphQL::Derivation::DerivableObjectType
    end

    it 'registers the anonymous type for resolve_all!' do
      expect(GraphQL::Derivation::DerivableObjectType.included_classes).to include(nested_type)
    end

    it 'keeps the source List/NonNull wrapping around the nested type' do
      fields = resolve(FixtureSchema::ExpenseType) do |pick|
        pick.project(:attachments) { |address| address.fields(:street) }
      end

      expect(field_named(fields, 'attachments').type.to_type_signature).to eq('[Address!]!')
    end

    it 'bases the nested type on the destination superclass, so it shares field_class and behaviour' do
      base = build_type(name: 'Base') { field_class Class.new(GraphQL::Schema::Field) }
      destination = build_type(base, name: 'Expense')

      fields = resolve(FixtureSchema::ExpenseType, destination: destination) do |pick|
        pick.project(:billing_address) { |address| address.fields(:city) }
      end

      expect(field_named(fields, 'billingAddress').type.superclass).to eq(base)
    end

    it 'falls back to GraphQL::Schema::Object as the base without a destination' do
      expect(nested_type.superclass).to eq(GraphQL::Schema::Object)
    end

    it 'does not include DerivableObjectType twice when the base already has it' do
      base = build_type(name: 'Base') { include GraphQL::Derivation::DerivableObjectType }
      destination = build_type(base, name: 'Expense')

      fields = resolve(FixtureSchema::ExpenseType, destination: destination) do |pick|
        pick.project(:billing_address) { |address| address.fields(:city) }
      end

      nested = field_named(fields, 'billingAddress').type
      expect(nested.ancestors.count(GraphQL::Derivation::DerivableObjectType)).to eq(1)
    end

    it 'copies the source type description onto the nested type' do
      described = build_type(name: 'Described') do
        description 'A described thing'
        field :label, String, null: true
      end
      source = build_type(name: 'Holder') { field :thing, described, null: true }

      fields = resolve(source) { |pick| pick.project(:thing) { |thing| thing.fields(:label) } }

      expect(field_named(fields, 'thing').type.description).to eq('A described thing')
    end

    it 'nests recursively' do
      country = build_type(name: 'Country') do
        field :code, String, null: false
        field :name, String, null: false
      end
      address = build_type(name: 'ShippingAddress') do
        field :line, String, null: false
        field :country, country, null: false
      end
      source = build_type(name: 'Order') { field :shipping, address, null: false }

      fields = resolve(source) do |pick|
        pick.project(:shipping) do |shipping|
          shipping.fields(:line)
          shipping.project(:country) { |c| c.fields(:code) }
        end
      end

      shipping_type = field_named(fields, 'shipping').type.unwrap
      country_type = shipping_type.fields['country'].type.unwrap
      expect([shipping_type.fields.keys, country_type.fields.keys]).to eq([%w[line country], %w[code]])
    end

    it 'supports the fields(name: [...]) shorthand' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:title, billing_address: %i[city street]) }

      expect(field_named(fields, 'billingAddress').type.fields.keys).to contain_exactly('city', 'street')
    end

    it 'names an anonymous destination in the error when the field does not return an Object type' do
      first_hop = build_projection(FixtureSchema::ExpenseType, name: 'ExpenseA') { |pick| pick.fields(:billing_address) }

      expect do
        resolve(first_hop) { |pick| pick.project(:billing_address) { |address| address.fields(:city) } }
      end.to raise_error(GraphQL::Derivation::ConfigurationError, /on an anonymous projection:/)
    end

    it 'raises ConfigurationError when the field does not return an Object type' do
      first_hop = build_projection(FixtureSchema::ExpenseType, name: 'ExpenseA') { |pick| pick.fields(:billing_address) }
      destination = build_type(name: 'ExpenseB')

      expect do
        resolve(first_hop, destination: destination) do |pick|
          pick.project(:billing_address) { |address| address.fields(:city) }
        end
      end.to raise_error(
        GraphQL::Derivation::ConfigurationError,
        /Cannot pick\.project\(:billing_address\) on ExpenseB: .*only Object types can be projected inline/m,
      )
    end
  end

  describe 'copying the rest of the field definition' do
    it 'copies arguments' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:notes) }

      expect(field_named(fields, 'notes').arguments.keys).to contain_exactly('limit')
    end

    it 'copies extras' do
      source = build_type(name: 'WithExtras') { field :peek, String, null: true, extras: [:lookahead] }

      fields = resolve(source) { |pick| pick.fields(:peek) }

      expect(field_named(fields, 'peek').extras).to eq([:lookahead])
    end

    it 'copies custom extensions with their options' do
      extension = Class.new(GraphQL::Schema::FieldExtension)
      source = build_type(name: 'WithExtension') do
        field :tagged, String, null: true do
          extension(extension, flavour: :mint)
        end
      end

      fields = resolve(source) { |pick| pick.fields(:tagged) }
      copied = field_named(fields, 'tagged').extensions.find { |ext| ext.instance_of?(extension) }

      expect(copied.options).to eq(flavour: :mint)
    end

    it 'does not duplicate the extensions graphql-ruby adds on its own' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:tags) }
      classes = field_named(fields, 'tags').extensions.map(&:class)

      expect(classes).to eq(FixtureSchema::ExpenseType.fields['tags'].extensions.map(&:class))
    end

    it 'copies description and deprecation_reason' do
      source = build_type(name: 'Documented') do
        field :old, String, null: true, description: 'Old thing', deprecation_reason: 'Use new'
      end

      fields = resolve(source) { |pick| pick.fields(:old) }

      expect(field_named(fields, 'old')).to have_attributes(description: 'Old thing', deprecation_reason: 'Use new')
    end

    it 'keeps connection: false on a field whose type is merely named like a connection' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:sync_connection) }
      copied = field_named(fields, 'syncConnection')

      expect([copied.connection?, copied.arguments.keys]).to eq([false, []])
    end

    it 'builds the field with the destination field_class' do
      field_class = Class.new(GraphQL::Schema::Field)
      destination = build_type(name: 'Expense') { field_class(field_class) }

      fields = resolve(FixtureSchema::ExpenseType, destination: destination) { |pick| pick.fields(:title) }

      expect(field_named(fields, 'title')).to be_an_instance_of(field_class)
    end
  end

  describe 'Case 4: instance resolver methods on the source type' do
    let(:expense) { Struct.new(:title).new('Lunch') }
    let(:query_type) do
      derived = build_projection(FixtureSchema::ExpenseType, name: 'Expense') do |pick|
        pick.fields(:title, :display_title, :notes)
      end
      build_type(name: 'Query') { field :expense, derived, null: false }
    end
    let(:schema) do
      root = query_type
      Class.new(GraphQL::Schema) { query(root) }
    end

    it 'attaches SourceResolverExtension pointing at the source type' do
      fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:display_title) }
      extension = field_named(fields, 'displayTitle').extensions.find do |ext|
        ext.is_a?(GraphQL::Derivation::SourceResolverExtension)
      end

      expect(extension.options).to eq(source: FixtureSchema::ExpenseType)
    end

    it 'resolves the copied field through the source type method at query time' do
      root = Struct.new(:expense).new(expense)
      result = schema.execute('{ expense { displayTitle notes(limit: 2) title } }', root_value: root)

      expect(result['data']['expense']).to eq('displayTitle' => 'Lunch!', 'notes' => 'note x2', 'title' => 'Lunch')
    end

    it 'does not attach the extension when the pick block overrides method:' do
      fields = resolve(FixtureSchema::ExpenseType) do |pick|
        pick.fields(:display_title)
        pick.override(:display_title, method: :title)
      end

      expect(field_named(fields, 'displayTitle').extensions).not_to include(a_kind_of(GraphQL::Derivation::SourceResolverExtension))
    end

    it 'does not attach the extension when the pick block overrides resolver:' do
      fields = resolve(FixtureSchema::ExpenseType) do |pick|
        pick.fields(:display_title)
        pick.override(:display_title, resolver: ->(obj, _args, _ctx) { obj.title })
      end

      expect(field_named(fields, 'displayTitle').extensions).not_to include(a_kind_of(GraphQL::Derivation::SourceResolverExtension))
    end
  end
end
