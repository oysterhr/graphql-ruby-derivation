# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::ProjectionSchema do
  around do |example|
    original = GraphQL::Derivation::DerivableObjectType.included_classes.dup
    GraphQL::Derivation::DerivableObjectType.included_classes.clear
    example.run
    GraphQL::Derivation::DerivableObjectType.included_classes.replace(original)
  end

  let(:address_projection) do
    Class.new(GraphQL::Schema::Object) do
      include GraphQL::Derivation::DerivableObjectType

      graphql_name 'Address'
      derive_from(FixtureSchema::AddressType) { |pick| pick.fields(:city) }
    end
  end
  let(:expense_projection) do
    Class.new(GraphQL::Schema::Object) do
      include GraphQL::Derivation::DerivableObjectType

      graphql_name 'Expense'
      derive_from(FixtureSchema::ExpenseType) { |pick| pick.fields(:title, :billing_address) }
    end
  end
  let(:legacy_address) do
    Class.new(GraphQL::Schema::Object) do
      graphql_name 'Address'
      field :street, String, null: false
    end
  end

  def query_type(**root_fields)
    Class.new(GraphQL::Schema::Object) do
      graphql_name 'Query'
      root_fields.each { |name, type| field name, type, null: true }
    end
  end

  def build_schema(root, orphans: [])
    Class.new(GraphQL::Schema) do
      extend GraphQL::Derivation::ProjectionSchema

      orphan_types(*orphans) unless orphans.empty?
      query(root)
    end
  end

  describe 'resolving projected edges' do
    it 'resolves an edge to the type of the same name reachable from the root' do
      schema = build_schema(query_type(expense: expense_projection, address: address_projection))

      expect(schema.get_type('Address')).to eq(address_projection)
    end

    it 'rewrites the derived field type to the resolved projection' do
      build_schema(query_type(expense: expense_projection, address: address_projection))

      expect(expense_projection.fields['billingAddress'].type).to eq(address_projection)
    end

    it 'resolves an edge to a projection listed in orphan_types' do
      schema = build_schema(query_type(expense: expense_projection), orphans: [address_projection])

      expect(schema.get_type('Address')).to eq(address_projection)
    end

    it 'resolves an edge to a legacy type mounted elsewhere in the schema' do
      schema = build_schema(query_type(expense: expense_projection, address: legacy_address))

      expect(schema.get_type('Address')).to eq(legacy_address)
    end

    it 'needs no explicit resolve_all! for the derived fields to be in the schema' do
      schema = build_schema(query_type(expense: expense_projection), orphans: [address_projection])

      expect(schema.get_type('Expense').fields.keys).to contain_exactly('title', 'billingAddress')
    end

    it 'executes a query across the projected edge' do
      schema = build_schema(query_type(expense: expense_projection), orphans: [address_projection])
      address = Struct.new(:city, :street).new('Lisbon', 'Rua A')
      expense = Struct.new(:title, :billing_address).new('Lunch', address)

      root_value = Struct.new(:expense).new(expense)

      result = schema.execute('{ expense { title billingAddress { city } } }', root_value: root_value)

      expect(result['data']).to eq('expense' => {'title' => 'Lunch', 'billingAddress' => {'city' => 'Lisbon'}})
    end

    it 'tolerates the same class being reached more than once' do
      root = query_type(expense: expense_projection, address: address_projection)

      expect { build_schema(root, orphans: [address_projection]) }.not_to raise_error
    end
  end

  describe 'missing projection' do
    it 'raises MissingProjectionError naming the schema type and the derived field' do
      expect { build_schema(query_type(expense: expense_projection)) }.to raise_error(
        GraphQL::Derivation::MissingProjectionError,
        /has no type named "Address", but Expense\.billingAddress needs one/,
      )
    end

    it 'names the source field and the canonical type it returns' do
      expect { build_schema(query_type(expense: expense_projection)) }.to raise_error(
        GraphQL::Derivation::MissingProjectionError,
        /derived from FixtureSchema::ExpenseType#billing_address, which returns FixtureSchema::AddressType\./,
      )
    end

    it 'tells the developer the three ways out' do
      expect { build_schema(query_type(expense: expense_projection)) }.to raise_error(
        GraphQL::Derivation::MissingProjectionError,
        /reachable\ from\ a\ root\ field\ or\ listed\ in\ `orphan_types`.*
          pick\.override\(:billing_address,\ type:\ SomeType\).*pick\.expose_full\(:billing_address\)/mx,
      )
    end

    it 'uses the schema class name when it has one' do
      stub_const('SurfaceSchema', Class.new(GraphQL::Schema) { extend GraphQL::Derivation::ProjectionSchema })
      root = query_type(expense: expense_projection)

      expect { SurfaceSchema.query(root) }.to raise_error(
        GraphQL::Derivation::MissingProjectionError, /\ASurfaceSchema has no type/,
      )
    end

    it 'exposes the edge and schema on the error' do
      build_schema(query_type(expense: expense_projection))
    rescue GraphQL::Derivation::MissingProjectionError => e
      expect([e.edge.name, e.schema]).to eq(['Address', e.schema]).and(satisfy { e.schema < GraphQL::Schema })
    end

    it 'is a ConfigurationError' do
      expect(GraphQL::Derivation::MissingProjectionError).to be < GraphQL::Derivation::ConfigurationError
    end

    it 're-raises an unrelated late-bound type failure untouched' do
      root = query_type(nope: GraphQL::Schema::LateBoundType.new('Nope'))

      expect { build_schema(root) }.to raise_error(GraphQL::Schema::UnresolvedLateBoundTypeError)
    end
  end

  describe 'duplicate type names' do
    it 'raises DuplicateTypeNameError as soon as two classes share a name' do
      root = query_type(expense: expense_projection, address: legacy_address)

      expect { build_schema(root, orphans: [address_projection]) }.to raise_error(
        GraphQL::Derivation::DuplicateTypeNameError,
        /has 2 different types named "Address"/,
      )
    end

    it 'lists each class with the fields that return it' do
      root = query_type(expense: expense_projection, address: legacy_address)

      expect { build_schema(root, orphans: [address_projection]) }.to raise_error(
        GraphQL::Derivation::DuplicateTypeNameError,
        /-\ \#<Class.*>\ \(root\ or\ orphan\ type\)\n
          \ \ -\ \#<Class.*>\ \(returned\ by\ Expense\.billingAddress,\ Query\.address\)\n/x,
      )
    end

    it 'exposes the name and classes on the error' do
      root = query_type(expense: expense_projection, address: legacy_address)
      build_schema(root, orphans: [address_projection])
    rescue GraphQL::Derivation::DuplicateTypeNameError => e
      expect([e.type_name, e.classes]).to eq(['Address', [address_projection, legacy_address]])
    end

    it 'is a ConfigurationError' do
      expect(GraphQL::Derivation::DuplicateTypeNameError).to be < GraphQL::Derivation::ConfigurationError
    end
  end
end
