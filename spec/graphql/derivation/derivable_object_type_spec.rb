# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::DerivableObjectType do
  # The registry (`included_classes`) is module-level state that
  # accumulates across the whole spec run. Reset it around each example so
  # one test's dynamically-defined class (especially ones left in a
  # deliberately-unresolvable, colliding state) cannot leak into another
  # test's `resolve_all!` call.
  around do |example|
    original = described_class.included_classes.dup
    described_class.included_classes.clear
    example.run
    described_class.included_classes.replace(original)
  end

  def build_object_type_class(&block)
    Class.new(GraphQL::Schema::Object) do
      include GraphQL::Derivation::DerivableObjectType

      graphql_name "TestObject#{object_id}"

      class_eval(&block) if block
    end
  end

  describe 'lazy resolution on first use' do
    it 'registers derived fields the first time .fields is read, without resolve_all!' do
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.fields(:title, :description)
        end
      end

      # No resolve_all! / resolve_derivation! -- reading .fields must resolve.
      expect(object_class.fields.keys).to contain_exactly('title', 'description')
    end

    it 'does not re-run the pick block on repeated .fields reads' do
      call_count = 0
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          call_count += 1
          pick.fields(:title)
        end
      end

      object_class.fields
      object_class.fields

      expect(call_count).to eq(1)
    end
  end

  describe 'derivation resolution (§10.4 integration: derived fields appear)' do
    it 'registers derived fields on the class after resolve_all! fires' do
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.fields(:title, :description)
        end
      end

      described_class.resolve_all!

      expect(object_class.fields.keys).to contain_exactly('title', 'description')
    end

    it "keeps a derived field's underlying type" do
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.fields(:title)
        end
      end

      described_class.resolve_all!

      expect(object_class.fields['title'].type.unwrap).to eq(GraphQL::Types::String)
    end

    it 'allows inline field declarations to coexist with derive_from' do
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.fields(:title)
        end

        field :team_member_notes, String, null: true
      end

      described_class.resolve_all!

      expect(object_class.fields.keys).to contain_exactly('title', 'teamMemberNotes')
    end

    it 'does not raise when resolving a class that never calls derive_from' do
      build_object_type_class { field :team_member_notes, String, null: true }

      expect { described_class.resolve_all! }.not_to raise_error
    end

    it 'leaves a class that never calls derive_from with only its inline fields' do
      object_class = build_object_type_class do
        field :team_member_notes, String, null: true
      end

      described_class.resolve_all!

      expect(object_class.fields.keys).to contain_exactly('teamMemberNotes')
    end
  end

  describe 'collision detection (§10.4 integration)' do
    it 'raises ConfigurationError at resolution time when an inline field collides with a derived one' do
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.fields(:title)
        end

        field :title, String, null: true
      end

      expect { object_class.resolve_derivation! }.to raise_error(
        GraphQL::Derivation::ConfigurationError,
        /already defines a field named title inline.*remove the inline declaration/im,
      )
    end

    it 'does not register any derived fields when a collision is detected' do
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.fields(:title, :amount_cents)
        end

        field :title, String, null: true
      end

      begin
        object_class.resolve_derivation!
      rescue GraphQL::Derivation::ConfigurationError
        nil
      end

      expect(object_class.fields.keys).to contain_exactly('title')
    end

    it 'uses plural phrasing when more than one inline field collides with a derived one' do
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.fields(:title, :amount_cents)
        end

        field :title, String, null: true
        field :amount_cents, Integer, null: true
      end

      expect { object_class.resolve_derivation! }.to raise_error(
        GraphQL::Derivation::ConfigurationError,
        /already defines fields named amountCents, title inline.*derive fields with that name/im,
      )
    end
  end

  describe 'derive_from validation' do
    it 'raises ConfigurationError immediately when called a second time on the same class' do
      object_class = build_object_type_class do
        derive_from(FixtureSchema::ExpenseType) { |pick| pick.fields(:title) }
      end

      expect do
        object_class.derive_from(FixtureSchema::ExpenseType) { |pick| pick.fields(:description) }
      end.to raise_error(
        GraphQL::Derivation::ConfigurationError,
        /already called derive_from.*at most once.*remove the duplicate/im,
      )
    end
  end

  describe 'resolve_all! idempotency' do
    it 'does not raise when resolve_all! is called twice' do
      build_object_type_class do
        derive_from(FixtureSchema::ExpenseType) { |pick| pick.fields(:title) }
      end

      described_class.resolve_all!

      expect { described_class.resolve_all! }.not_to raise_error
    end

    it 'does not duplicate fields when resolve_all! is called twice' do
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.fields(:title)
        end
      end

      described_class.resolve_all!
      described_class.resolve_all!

      expect(object_class.fields.keys).to contain_exactly('title')
    end

    it 'does not re-run the pick block on a second resolve_derivation! call' do
      call_count = 0
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          call_count += 1
          pick.fields(:title)
        end
      end

      object_class.resolve_derivation!
      object_class.resolve_derivation!

      expect(call_count).to eq(1)
    end
  end

  describe 'end-to-end resolver verification (§10.4: resolver handling end-to-end)' do
    # `FixtureSchema::ExpenseType#full_name` is a Case 3 (custom class
    # resolver) field -- it resolves via `self.resolve_full_name` on the
    # source class and cannot be transparently copied without an explicit
    # `method:`/`resolver:` override (SPEC.md §5.3). This proves the
    # derived field, once given that override, actually executes against a
    # real underlying object via a real `GraphQL::Schema` query -- not just
    # that a `GraphQL::Schema::Field` instance got constructed.
    let(:underlying_object) do
      Struct.new(:title, :computed_full_name).new('Team offsite', 'Ada Lovelace')
    end

    def build_full_name_schema
      object_class = build_object_type_class do
        derive_from FixtureSchema::ExpenseType do |pick|
          pick.fields(:title, :full_name)
          pick.override(:full_name, method: :computed_full_name)
        end
      end

      described_class.resolve_all!

      query_type = object_class
      Class.new(GraphQL::Schema) { query query_type }
    end

    it 'executes a query without errors for the overridden Case 3 field' do
      schema = build_full_name_schema

      result = schema.execute('{ title fullName }', root_value: underlying_object)

      expect(result['errors']).to be_nil
    end

    it 'resolves the overridden Case 3 field to the correct value' do
      schema = build_full_name_schema

      result = schema.execute('{ title fullName }', root_value: underlying_object)

      expect(result['data']).to eq('title' => 'Team offsite', 'fullName' => 'Ada Lovelace')
    end
  end
end
