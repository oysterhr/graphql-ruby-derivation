# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::FieldDerivation do
  def resolve(source, &pick_block)
    described_class.resolve(source, pick_block)
  end

  describe '.resolve' do
    context 'with an ObjectType source' do
      let(:wrapper) { double('wrapper', object: model) } # rubocop:disable RSpec/VerifiedDoubles
      let(:model) { double('model', full_name: 'Jane Doe') } # rubocop:disable RSpec/VerifiedDoubles
      let(:full_name_field) { fields_with_resolver_override.find { |field| field.graphql_name == 'fullName' } }
      let(:fields_with_resolver_override) do
        resolve(FixtureSchema::ExpenseType) do |pick|
          pick.fields(:full_name)
          pick.override(:full_name, resolver: resolver)
        end
      end
      let(:resolver) { ->(obj, _args, _ctx) { obj.full_name } }

      it 'returns configured fields for the selected fields' do
        fields = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.fields(:title, :amount_cents)
        end

        expect(fields.map(&:graphql_name)).to contain_exactly('title', 'amountCents')
      end

      it 'copies a Case 1 (default method resolver) field as-is' do
        fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:title) }
        title = fields.find { |field| field.graphql_name == 'title' }

        expect(title.method_sym).to eq(:title)
      end

      it 'copies a Case 2 (method: option) field with the same method:' do
        fields = resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:memo) }
        memo = fields.find { |field| field.graphql_name == 'memo' }

        expect(memo.method_sym).to eq(:internal_memo)
      end

      it 'raises UnresolvableFieldError for an unresolved Case 3 (custom resolver) field' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:full_name) }
        end.to raise_error(GraphQL::Derivation::UnresolvableFieldError, /full_name/)
      end

      it 'resolves a Case 3 field when the pick block supplies a method: override' do
        fields = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.fields(:full_name)
          pick.override(:full_name, method: :computed_full_name)
        end
        full_name = fields.find { |field| field.graphql_name == 'fullName' }

        expect(full_name.method_sym).to eq(:computed_full_name)
      end

      it 'resolves a Case 3 field when the pick block supplies a resolver: override' do
        expect(fields_with_resolver_override.map(&:graphql_name)).to include('fullName')
      end

      it 'invokes the resolver: override proc, unwrapping the GraphQL object wrapper, when resolved' do
        expect(full_name_field.resolve(wrapper, {}, nil)).to eq('Jane Doe')
      end

      it 'mixes Case 1, Case 2, and overridden Case 3 fields in one resolution' do
        fields = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.fields(:title, :memo, :full_name)
          pick.override(:full_name, method: :computed_full_name)
        end

        expect(fields.map(&:graphql_name)).to contain_exactly('title', 'memo', 'fullName')
      end

      it 'does not offer a connection-type field as a candidate' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |pick| pick.fields(:related_expenses) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /related_expenses/)
      end
    end

    context 'with an ActiveRecord model source, adapter not loaded' do
      # `FixtureSchema::Expense` is deliberately a plain Ruby stand-in, not a
      # real `ActiveRecord::Base` subclass (SPEC.md §10.5) -- the gem's own
      # test suite never loads ActiveRecord. To exercise the
      # `source < ActiveRecord::Base` branch of `FieldDerivation` without
      # the ActiveRecord adapter (`graphql/derivation/rails/active_record`)
      # loaded, this context defines a minimal `ActiveRecord::Base`
      # stand-in for the duration of the example, simulating a host app
      # that has loaded ActiveRecord but not opted into this gem's AR
      # integration, then removes it so other examples are unaffected.
      #
      # `ActiveRecordMapper` is also hidden via `hide_const`: other spec
      # files in this suite (e.g. `active_record_mapper_spec.rb`) genuinely
      # require `graphql/derivation/rails/active_record`, and once required
      # the constant stays defined process-wide (Ruby has no "unrequire").
      # Hiding it here keeps this example's behaviour independent of test
      # run order.
      before do
        stub_const('ActiveRecord::Base', Class.new)
        hide_const('GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper') if defined?(
          GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper
        )
      end

      it 'raises a clear error pointing at the ActiveRecord adapter require path' do
        model = Class.new(ActiveRecord::Base)

        expect do
          resolve(model) { |pick| pick.fields(:title) }
        end.to raise_error(NotImplementedError, %r{graphql/derivation/rails/active_record})
      end
    end

    context 'with a real ActiveRecord model source (adapter loaded)' do
      # Requiring the adapter here (rather than at the top of the file) is
      # deliberate: it keeps the rest of this spec file's examples running
      # in an environment where ActiveRecord has not been loaded, matching
      # SPEC.md §10.5's "no DB required" and AGENTS.md's "core loads/runs
      # without Rails or ActiveRecord" rule for the bulk of the suite. This
      # context is the one place that legitimately exercises the AR
      # integration end-to-end.
      before { require 'graphql/derivation/rails/active_record' }

      # `FixtureSchema::Expense` (SPEC.md §10.5's stub) is not itself a
      # `< ActiveRecord::Base` descendant, so a tiny real subclass is used
      # here purely to satisfy `active_record_source?`'s ancestry check;
      # its `.columns`/`.defined_enums` are delegated to the stub.
      let(:model) do
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

      it 'returns real GraphQL::Schema::Field instances for selected AR columns' do
        fields = resolve(model) do |pick|
          pick.fields(:title, :amount_cents, :reimbursable, :category, :team_member_id)
        end

        expect(fields).to all(be_a(GraphQL::Schema::Field))
      end

      it 'derives a field for every selected AR column' do
        fields = resolve(model) do |pick|
          pick.fields(:title, :amount_cents, :reimbursable, :category, :team_member_id)
        end

        expect(fields.map(&:graphql_name)).to contain_exactly(
          'title', 'amountCents', 'reimbursable', 'category', 'teamMemberId',
        )
      end

      it 'maps a not-null :string column to String!' do
        fields = resolve(model) { |pick| pick.fields(:title) }

        expect(fields.first.type.to_type_signature).to eq('String!')
      end

      it 'maps a nullable :text column to String' do
        fields = resolve(model) { |pick| pick.fields(:description) }

        expect(fields.first.type.to_type_signature).to eq('String')
      end

      it 'maps a not-null :integer column to Int!' do
        fields = resolve(model) { |pick| pick.fields(:amount_cents) }

        expect(fields.first.type.to_type_signature).to eq('Int!')
      end

      it 'maps a not-null *_id :bigint column to ID! (foreign-key override)' do
        fields = resolve(model) { |pick| pick.fields(:team_member_id) }

        expect(fields.first.type.to_type_signature).to eq('ID!')
      end

      it 'allows a pick.override to flip null: for an AR-derived field' do
        fields = resolve(model) do |pick|
          pick.fields(:description)
          pick.override(:description, null: false)
        end

        expect(fields.first.type.to_type_signature).to eq('String!')
      end

      it 'raises UnsupportedColumnTypeError when an unsupported column is selected' do
        expect do
          resolve(model) { |pick| pick.fields(:metadata) }
        end.to raise_error(GraphQL::Derivation::UnsupportedColumnTypeError, /metadata/)
      end

      it 'excludes id/created_at/updated_at from the candidate set' do
        expect do
          resolve(model) { |pick| pick.fields(:id) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /id/)
      end
    end

    context 'with an unsupported source type' do
      it 'raises ArgumentError immediately' do
        expect do
          resolve('not a valid source') { |_pick| nil }
        end.to raise_error(ArgumentError, /Unsupported FieldDerivation source/)
      end

      it 'raises ArgumentError for nil' do
        expect { resolve(nil) { |_pick| nil } }.to raise_error(ArgumentError)
      end
    end

    context 'when the pick block selects nothing' do
      it 'raises ConfigurationError via PickFields#validate!' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |_pick| nil }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /selected/)
      end
    end

    context 'with a bare anonymous ObjectType source (no graphql_name declared)' do
      it 'falls back to #inspect instead of raising RequiredImplementationMissingError' do
        anonymous_type = Class.new(GraphQL::Schema::Object) do
          field :title, String, null: true
        end

        expect do
          resolve(anonymous_type) { |pick| pick.fields(:bogus) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /does not define it/)
      end
    end
  end

  describe '#source_name (private)' do
    # `enumerate_candidates` rejects any source that isn't an ObjectType or
    # ActiveRecord model before `source_name` is ever reached via `.resolve`,
    # so every real source responds to `graphql_name`. This exercises the
    # defensive `respond_to?(:graphql_name)` guard directly, for a source
    # type `.resolve` could never actually pass it -- called via `send`
    # since `source_name` is a `private_class_method`.
    let(:fake_source) do
      source = Object.new
      def source.name
        nil
      end
      source
    end

    it 'falls back to #inspect for a source with no #name and no #graphql_name' do
      expect(described_class.send(:source_name, fake_source)).to eq(fake_source.inspect)
    end
  end
end
