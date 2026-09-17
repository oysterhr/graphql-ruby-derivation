# frozen_string_literal: true

RSpec.describe GraphQL::Derivation::ArgumentDerivation do
  def resolve(source, &pick_block)
    described_class.resolve(source, pick_block)
  end

  describe '.resolve' do
    context 'with an ObjectType source' do
      it 'returns configured arguments for the selected fields' do
        arguments = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.required(:title, :amount_cents)
          pick.optional(:description, :status)
        end

        expect(arguments.map(&:graphql_name)).to contain_exactly(
          'title', 'amountCents', 'description', 'status',
        )
      end

      it 'marks required selections as non-null' do
        arguments = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.required(:title)
          pick.optional(:description)
        end
        by_name = arguments.to_h { |argument| [argument.graphql_name, argument] }

        expect(by_name['title'].type).to be_non_null
      end

      it 'marks optional selections as nullable' do
        arguments = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.required(:title)
          pick.optional(:description)
        end
        by_name = arguments.to_h { |argument| [argument.graphql_name, argument] }

        expect(by_name['description'].type).not_to be_non_null
      end

      it 'passes a custom scalar field type through unchanged' do
        arguments = resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:amount) }
        amount = arguments.find { |argument| argument.graphql_name == 'amount' }

        expect(amount.type).to eq(FixtureSchema::MoneyAmountType)
      end

      it 'passes an enum field type through unchanged' do
        arguments = resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:status) }
        status = arguments.find { |argument| argument.graphql_name == 'status' }

        expect(status.type).to eq(FixtureSchema::ExpenseStatusEnum)
      end

      it 'keeps a list-of-scalar field as a list' do
        arguments = resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:tags) }
        tags = arguments.find { |argument| argument.graphql_name == 'tags' }

        expect(tags.type.list?).to be(true)
      end

      it 'keeps a list-of-scalar field wrapping the same scalar type' do
        arguments = resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:tags) }
        tags = arguments.find { |argument| argument.graphql_name == 'tags' }

        expect(tags.type.unwrap).to eq(GraphQL::Types::String)
      end

      it 'does not offer a connection-type field as a candidate' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:related_expenses) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /related_expenses/)
      end

      it 'does not offer a list-of-Object field as a candidate' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:attachments) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /attachments/)
      end

      it 'raises ConfigurationError when a nested Object-type field is selected without input_type:' do
        expect do
          resolve(FixtureSchema::ExpenseType) { |pick| pick.optional(:billing_address) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /billing_address/)
      end

      it 'allows a nested Object-type field when input_type: is supplied via override' do
        arguments = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.optional(:billing_address)
          pick.override(:billing_address, input_type: FixtureSchema::ExpenseBaseInput)
        end
        billing_address = arguments.find { |argument| argument.graphql_name == 'billingAddress' }

        expect(billing_address.type).to eq(FixtureSchema::ExpenseBaseInput)
      end

      it 'does not forward input_type: itself as a GraphQL::Schema::Argument option' do
        arguments = resolve(FixtureSchema::ExpenseType) do |pick|
          pick.optional(:billing_address)
          pick.override(:billing_address, input_type: FixtureSchema::ExpenseBaseInput)
        end
        billing_address = arguments.find { |argument| argument.graphql_name == 'billingAddress' }

        expect(billing_address.type).not_to be_non_null
      end
    end

    context 'with an InputObject source' do
      it 'returns configured arguments using identity type mapping' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) do |pick|
          pick.required(:title)
          pick.optional(:category)
        end

        expect(arguments.map(&:graphql_name)).to contain_exactly('title', 'category')
      end

      it 'reuses the source argument type directly' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.optional(:title) }
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type.unwrap).to eq(FixtureSchema::ExpenseBaseInput.arguments['title'].type.unwrap)
      end

      it 'marks a pick.optional selection as nullable regardless of source nullability' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.optional(:title) }
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type).not_to be_non_null
      end

      it 'marks a pick.required selection as non-null regardless of source nullability' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.required(:category) }
        category = arguments.find { |argument| argument.graphql_name == 'category' }

        expect(category.type).to be_non_null
      end

      # SPEC.md §4.4: the derived argument must preserve the source
      # argument's own option metadata (`prepare:`, `description:`,
      # `default_value:`, `validates:`, `deprecation_reason:`) -- only
      # `required:` is intentionally re-controlled by the pick block. Before
      # this was fixed, `build_argument` only ever merged `{required:}` with
      # `pick.override` opts, so every one of these was silently dropped.
      it 'preserves prepare:' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.optional(:category) }
        category = arguments.find { |argument| argument.graphql_name == 'category' }

        expect(category.prepare).to eq(:strip)
      end

      it 'preserves description:' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.optional(:category) }
        category = arguments.find { |argument| argument.graphql_name == 'category' }

        expect(category.description).to eq('Expense category')
      end

      it 'preserves default_value:' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.optional(:reimbursable) }
        reimbursable = arguments.find { |argument| argument.graphql_name == 'reimbursable' }

        expect(reimbursable.default_value).to be(true)
      end

      it 'does not set default_value: when the source argument has none' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.optional(:category) }
        category = arguments.find { |argument| argument.graphql_name == 'category' }

        expect(category.default_value?).to be(false)
      end

      it 'preserves validates:' do
        # The source `title` argument allows up to 40 characters
        # (`FixtureSchema::ExpenseBaseInput`) -- a 41-character value must
        # still fail validation on the derived argument.
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.optional(:title) }
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.validators.first.validate(nil, nil, 'a' * 41)).not_to be_nil
      end

      it 'preserves deprecation_reason: when the pick block keeps the argument optional' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.optional(:notes) }
        notes = arguments.find { |argument| argument.graphql_name == 'notes' }

        expect(notes.deprecation_reason).to eq('Use description instead')
      end

      it 'raises ConfigurationError rather than silently drop deprecation_reason: under pick.required' do
        # graphql-ruby forbids a deprecated required argument ("Required
        # arguments cannot be deprecated"). Silently dropping the source's
        # deprecation_reason: to keep pick.required legal would hide a real
        # fact about the source argument from whoever reads the derived
        # one -- the caller must choose explicitly instead (khamusa's PR #46
        # review).
        expect do
          resolve(FixtureSchema::ExpenseBaseInput) { |pick| pick.required(:notes) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /pick\.optional\(:notes\)/)
      end

      it 'lets an explicit pick.override(name, deprecation_reason: nil) opt out of the raise' do
        # The pick block, not derivation, records the decision that the
        # derived argument is not deprecated -- so it is free to become
        # required.
        arguments = resolve(FixtureSchema::ExpenseBaseInput) do |pick|
          pick.required(:notes)
          pick.override(:notes, deprecation_reason: nil)
        end
        notes = arguments.find { |argument| argument.graphql_name == 'notes' }

        expect(notes).to have_attributes(deprecation_reason: nil, type: be_non_null)
      end

      it 'lets an explicit pick.override win over the source default_value:' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) do |pick|
          pick.optional(:reimbursable)
          pick.override(:reimbursable, default_value: false)
        end
        reimbursable = arguments.find { |argument| argument.graphql_name == 'reimbursable' }

        expect(reimbursable.default_value).to be(false)
      end

      it 'lets an explicit pick.override win over the source validates:' do
        # The source `title` argument allows up to 40 characters
        # (`FixtureSchema::ExpenseBaseInput`); the override tightens that to
        # 10, so an 11-character value must fail validation only if the
        # override -- not the transplanted source validator -- is the one
        # actually in effect.
        arguments = resolve(FixtureSchema::ExpenseBaseInput) do |pick|
          pick.optional(:title)
          pick.override(:title, validates: {length: {maximum: 10}})
        end
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.validators.first.validate(nil, nil, '01234567890')).not_to be_nil
      end

      it 'lets an explicit pick.override win over the source prepare:' do
        arguments = resolve(FixtureSchema::ExpenseBaseInput) do |pick|
          pick.optional(:category)
          pick.override(:category, prepare: :upcase)
        end
        category = arguments.find { |argument| argument.graphql_name == 'category' }

        expect(category.prepare).to eq(:upcase)
      end
    end

    context 'with a Mutation source' do
      it 'returns configured arguments using identity type mapping' do
        arguments = resolve(FixtureSchema::CreateExpenseMutation) do |pick|
          pick.required(:title)
          pick.optional(:category)
        end

        expect(arguments.map(&:graphql_name)).to contain_exactly('title', 'category')
      end

      it 'reuses the mutation argument type directly' do
        arguments = resolve(FixtureSchema::CreateExpenseMutation) { |pick| pick.optional(:title) }
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type.unwrap).to eq(FixtureSchema::CreateExpenseMutation.arguments['title'].type.unwrap)
      end

      it 'lets the pick block re-control nullability regardless of the mutation argument nullability' do
        arguments = resolve(FixtureSchema::CreateExpenseMutation) { |pick| pick.optional(:title) }
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type).not_to be_non_null
      end

      # Finding #1 (Rox's PR #46 review): the "preserves ..." specs under the
      # InputObject context only covered the InputObject source path. Mutation
      # sources go through the SAME `InputObjectToArgument` mapper, but nothing
      # asserted the source option metadata actually carries across for them --
      # a regression in that shared mapper (e.g. a candidate that stopped
      # carrying its source argument) would still pass every other Mutation
      # spec here. A source-declared inline (not the shared `CreateExpenseMutation`
      # fixture, which carries no option metadata and is asserted on elsewhere)
      # locks the Mutation path in.
      it 'preserves the source argument option metadata (prepare:, description:)' do
        source = Class.new(GraphQL::Schema::Mutation) do
          graphql_name 'MetadataMutation'
          argument :category, String, required: false, prepare: :strip, description: 'Expense category'
          field :success, GraphQL::Types::Boolean, null: false
        end

        arguments = resolve(source) { |pick| pick.optional(:category) }
        category = arguments.find { |argument| argument.graphql_name == 'category' }

        expect(category).to have_attributes(prepare: :strip, description: 'Expense category')
      end
    end

    context 'with a Symbol (sibling action) source' do
      # SPEC.md §4.2: Symbol sources are resolved via a `context:` object that
      # responds to `resolve_sibling_arguments(symbol)`. This is the seam the
      # Rails ControllerConcern plugs the controller class into. The engine
      # stays Rails-free, so this is tested with a lightweight fake resolver
      # rather than a real controller.
      let(:sibling_resolver) do
        sibling_arguments = [
          GraphQL::Schema::Argument.new(:title, String, owner: nil, required: true),
          GraphQL::Schema::Argument.new(:category, String, owner: nil, required: false),
        ]
        Class.new do
          define_method(:resolve_sibling_arguments) do |name|
            raise "unexpected sibling #{name.inspect}" unless name == :create

            sibling_arguments
          end
        end.new
      end

      let(:tags) do
        arguments = described_class.resolve(
          :create, ->(pick) { pick.required(:tags) }, context: list_resolver,
        )
        arguments.find { |argument| argument.graphql_name == 'tags' }
      end
      let(:list_resolver) do
        Class.new do
          define_method(:resolve_sibling_arguments) do |_name|
            [GraphQL::Schema::Argument.new(:tags, [String], owner: nil, required: true)]
          end
        end.new
      end

      it 'resolves the named sibling action via the context resolver' do
        arguments = described_class.resolve(
          :create, ->(pick) { pick.required(:title) }, context: sibling_resolver,
        )

        expect(arguments.map(&:graphql_name)).to contain_exactly('title')
      end

      it 'maps the sibling argument type by identity' do
        arguments = described_class.resolve(
          :create, ->(pick) { pick.optional(:title) }, context: sibling_resolver,
        )
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type.unwrap).to eq(GraphQL::Types::String)
      end

      it 'lets the pick block re-control nullability of an identity-mapped sibling argument' do
        arguments = described_class.resolve(
          :create, ->(pick) { pick.optional(:title) }, context: sibling_resolver,
        )
        title = arguments.find { |argument| argument.graphql_name == 'title' }

        expect(title.type).not_to be_non_null
      end

      it 'raises ConfigurationError when no sibling resolver is supplied' do
        expect do
          resolve(:create) { |pick| pick.optional(:title) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /no sibling resolver/)
      end

      it 're-lists a list-typed sibling argument after unwrapping its element type' do
        expect(tags.type).to have_attributes(list?: true, unwrap: GraphQL::Types::String)
      end

      # Finding #1 (Rox's PR #46 review): `SiblingCandidate` now carries the
      # source `GraphQL::Schema::Argument`, so a sibling argument's option
      # metadata carries across just like an InputObject source's. Nothing
      # asserted this, though -- a regression that forgot to pass `argument`
      # to `SiblingCandidate.new` would slip past every other sibling spec.
      it 'preserves the sibling argument option metadata (prepare:, description:)' do
        resolver = Class.new do
          def resolve_sibling_arguments(_name)
            [GraphQL::Schema::Argument.new(
              :category,
              String,
              owner: nil,
              required: false,
              prepare: :strip,
              description: 'Expense category',
            )]
          end
        end.new

        arguments = described_class.resolve(
          :create, ->(pick) { pick.optional(:category) }, context: resolver,
        )
        category = arguments.find { |argument| argument.graphql_name == 'category' }

        expect(category).to have_attributes(prepare: :strip, description: 'Expense category')
      end
    end

    context 'with a source argument using validates: { all: {...} } (AllValidator)' do
      # Finding #2 (Rox / friendly-reviewer PR #46 review): `transplant_validators`
      # dups each source validator and rebinds its `@validated` to the derived
      # argument. `AllValidator` holds its sub-validators in a `@validators`
      # array that a shallow `dup` shares by reference, so those nested
      # sub-validators must be rebound too (and the source's own must be left
      # untouched).
      #
      # These specs read `@validated` directly instead of driving real
      # coercion, on purpose -- and that is NOT the "config read, not behavior"
      # trap khamusa flagged earlier in this file. graphql-ruby 2.6
      # interpolates `%{validated}` from the OUTER validator only (see
      # `transplant_validators`'s comment), so a real coercion produces the
      # correct derived name whether or not the nested rebind happened. A
      # message-level spec would pass either way and guard nothing; asserting
      # on the binding is the only way to catch a regression here.
      let(:source) do
        Class.new(GraphQL::Schema::InputObject) do
          graphql_name 'AllValidatorSourceInput'
          argument :handles, [String], required: false, validates: {all: {length: {maximum: 3}}}
        end
      end
      let(:derived) do
        arguments = resolve(source) { |pick| pick.optional(:handles) }
        arguments.find { |argument| argument.graphql_name == 'handles' }
      end

      it 'rebinds the nested sub-validators @validated to the derived argument' do
        nested = derived.validators.first.instance_variable_get(:@validators)

        expect(nested.map(&:validated)).to all(equal(derived))
      end

      it 'leaves the source argument nested sub-validators pointing at the source' do
        derived # resolve the derivation, which transplants off the source

        source_argument = source.arguments['handles']
        source_nested = source_argument.validators.first.instance_variable_get(:@validators)

        expect(source_nested.map(&:validated)).to all(equal(source_argument))
      end
    end

    context 'with an unsupported source type' do
      it 'raises ArgumentError immediately' do
        expect do
          resolve('not a valid source') { |_pick| nil }
        end.to raise_error(ArgumentError, /Unsupported ArgumentDerivation source/)
      end

      it 'raises ArgumentError for nil' do
        expect { resolve(nil) { |_pick| nil } }.to raise_error(ArgumentError)
      end
    end

    context 'when the pick block selects nothing' do
      it 'raises ConfigurationError via PickArguments#validate!' do
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
          resolve(anonymous_type) { |pick| pick.required(:bogus) }
        end.to raise_error(GraphQL::Derivation::ConfigurationError, /does not define it/)
      end
    end
  end

  # khamusa's PR #46 review: the specs above only ever read an argument's
  # config (`.prepare`, calling a validator's `#validate` directly) -- they
  # never run the real coercion path, so they cannot catch either of two
  # real behaviors: a transplanted validator's `@validated` still pointing
  # at the source argument (only `Validator.validate!` reads that, to fill
  # `%{validated}` in an error message), or a Symbol `prepare:` that fails
  # to resolve on the target owner (only `Argument#prepare_value` reads
  # that, at request time). These specs build a minimal schema around a
  # real `DerivableInputObject` and execute a query against it, so both
  # paths actually run.
  describe 'derived arguments under real coercion (not config reads)' do
    def build_target_input(source, &block)
      Class.new(GraphQL::Schema::InputObject) do
        include GraphQL::Derivation::DerivableInputObject

        graphql_name "CoercionTargetInput#{object_id}"
        derive_from(source, &block)
      end
    end

    def build_schema(field_name, argument_name, input_type)
      Class.new(GraphQL::Schema) do
        query_type = Class.new(GraphQL::Schema::Object) do
          graphql_name 'Query'

          field field_name, String, null: true do
            argument argument_name, input_type, required: true
          end

          define_method(field_name) { |**kwargs| kwargs[argument_name][:category] }
        end
        query(query_type)
      end
    end

    context 'when a transplanted validator fails (@validated rebind)' do
      # `as: :public_title` gives the source argument a GraphQL name
      # ("internalTitle") that differs from the derived argument's GraphQL
      # name ("publicTitle" -- `InputObjectToArgument#candidates` keys
      # candidates by `argument.keyword`, which `as:` overrides, not by the
      # argument's own declared GraphQL name). That asymmetry is what makes
      # this spec able to tell a correctly-rebound validator apart from one
      # still pointing at the source: if `transplant_validators` regressed
      # to not rebinding `@validated`, the error message below would say
      # "internalTitle", not "publicTitle" (verified manually against the
      # pre-rebind implementation while writing this spec).
      let(:source) do
        Class.new(GraphQL::Schema::InputObject) do
          graphql_name 'ValidatorRebindSourceInput'
          argument :internal_title, String, required: true, as: :public_title, validates: {length: {maximum: 5}}
        end
      end
      let(:target) { build_target_input(source) { |pick| pick.required(:public_title) } }
      let(:schema) do
        # `target` (an RSpec `let`) must be captured into a true local
        # variable before entering `Class.new(...) do ... end`: that block
        # runs via `class_eval`, which rebinds `self`, so a bare `target`
        # call inside it would look for a method on the new class instead
        # of the example's `let` -- a real local variable is resolved
        # lexically instead, regardless of `self`.
        input_type = target
        Class.new(GraphQL::Schema) do
          query_type = Class.new(GraphQL::Schema::Object) do
            graphql_name 'Query'

            field :echo, String, null: true do
              argument :input, input_type, required: true
            end

            def echo(**)
              raise 'unreachable -- validation must fail before the resolver runs'
            end
          end
          query(query_type)
        end
      end

      it "reports the DERIVED argument's GraphQL name in the validation error, not the source's" do
        result = schema.execute('{ echo(input: {publicTitle: "toolong"}) }')

        expect(result.to_h.dig('errors', 0, 'message')).to eq('publicTitle is too long (maximum is 5)')
      end
    end

    context 'when a Symbol prepare: runs through the target' do
      let(:source) do
        Class.new(GraphQL::Schema::InputObject) do
          graphql_name 'PrepareSymbolSourceInput'
          argument :category, String, required: false, prepare: :normalize_category
        end
      end
      let(:target) do
        # See the previous context's `schema` `let` for why `source` (an
        # RSpec `let`) is captured into a local variable before entering
        # `Class.new(...) do ... end`.
        source_input = source
        Class.new(GraphQL::Schema::InputObject) do
          include GraphQL::Derivation::DerivableInputObject

          graphql_name 'PrepareSymbolTargetInput'
          derive_from(source_input) { |pick| pick.optional(:category) }

          # The Symbol `prepare:` (`:normalize_category`) carries across
          # from `source` unchanged -- graphql-ruby resolves it against
          # THIS class's instances at coercion time, so it must be defined
          # here, not on `source` (USAGE.md's "`prepare:` — Symbol vs.
          # lambda").
          def normalize_category(value)
            value.strip.upcase
          end
        end
      end
      let(:schema) { build_schema(:echo, :input, target) }

      it "runs the source's Symbol prepare: on the target, proving it resolved there" do
        result = schema.execute('{ echo(input: {category: "  travel  "}) }')

        expect(result.to_h).to eq('data' => {'echo' => 'TRAVEL'})
      end
    end

    context 'when a lambda prepare: overrides a Symbol prepare: on a target with no matching method' do
      let(:source) do
        Class.new(GraphQL::Schema::InputObject) do
          graphql_name 'PrepareLambdaSourceInput'
          argument :category, String, required: false, prepare: :normalize_category
        end
      end
      let(:target) do
        # Deliberately does NOT define `normalize_category` -- the
        # `pick.override(:category, prepare: ->(...) { ... })` below
        # replaces the source's Symbol prepare: entirely, so nothing here
        # ever looks it up.
        build_target_input(source) do |pick|
          pick.optional(:category)
          pick.override(:category, prepare: ->(value, _context) { value.strip })
        end
      end
      let(:schema) { build_schema(:echo, :input, target) }

      it 'runs the lambda without needing a matching method on the target' do
        result = schema.execute('{ echo(input: {category: "  travel  "}) }')

        expect(result.to_h).to eq('data' => {'echo' => 'travel'})
      end
    end
  end

  describe '#source_name (private)' do
    # `enumerate_candidates` rejects any source that isn't an ObjectType,
    # InputObject, Mutation, or Symbol before `source_name` is ever reached
    # via `.resolve`, so every real source responds to `graphql_name`. This
    # exercises the defensive `respond_to?(:graphql_name)` guard directly, for
    # a source type `.resolve` could never actually pass it -- called via
    # `send` since `source_name` is a `private_class_method`.
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
