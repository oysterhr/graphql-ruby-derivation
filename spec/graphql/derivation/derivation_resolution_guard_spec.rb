# frozen_string_literal: true

# Covers the resolution-ordering + cycle-detection fix described in the PR:
# `resolve_derivation!` (both `DerivableInputObject` and
# `DerivableObjectType`) now recursively resolves a Derivable source BEFORE
# reading its `.arguments`/`.fields`, and both mixins share a single
# in-progress stack (`GraphQL::Derivation::DerivationResolutionGuard`) so a
# true `derive_from` cycle is caught with a clear `CyclicDependencyError`
# instead of silently reading an empty/partial source or succeeding/failing
# based on inclusion order.
#
# rubocop:disable RSpec/DescribeClass -- this spec exercises the interaction
# between DerivableInputObject, DerivableObjectType, and the shared guard;
# no single class is "under test" the way the per-mixin specs are.
RSpec.describe 'derive_from resolution ordering + cycle detection' do
  # `DerivableInputObject.included_classes` / `DerivableObjectType.
  # included_classes` are module-level state shared with
  # `derivable_input_object_spec.rb` / `derivable_object_type_spec.rb` in the
  # same run -- reset around every example, same pattern those files use.
  # The guard's own `in_progress` stack is intentionally NOT reset here: per
  # its own contract, it drains back to empty via `ensure` once the
  # outermost `resolve_derivation!` call returns (even after a raise), so if
  # it ever leaked, that would itself be the bug under test.
  around do |example|
    input_object_originals = GraphQL::Derivation::DerivableInputObject.included_classes.dup
    object_type_originals = GraphQL::Derivation::DerivableObjectType.included_classes.dup
    GraphQL::Derivation::DerivableInputObject.included_classes.clear
    GraphQL::Derivation::DerivableObjectType.included_classes.clear

    example.run

    GraphQL::Derivation::DerivableInputObject.included_classes.replace(input_object_originals)
    GraphQL::Derivation::DerivableObjectType.included_classes.replace(object_type_originals)
  end

  def build_input_object_class(name)
    klass = Class.new(GraphQL::Schema::InputObject) do
      include GraphQL::Derivation::DerivableInputObject
    end
    klass.graphql_name(name)
    klass
  end

  def build_object_type_class(name)
    klass = Class.new(GraphQL::Schema::Object) do
      include GraphQL::Derivation::DerivableObjectType
    end
    klass.graphql_name(name)
    klass
  end

  describe 'the guard leaves no state behind' do
    it 'drains the in-progress stack after a successful top-level resolution' do
      a = build_input_object_class('GuardDrainA')
      b = build_input_object_class('GuardDrainB')
      b.derive_from(FixtureSchema::ExpenseType) { |pick| pick.required(:title) }
      a.derive_from(b) { |pick| pick.required(:title) }

      a.resolve_derivation!

      expect(GraphQL::Derivation::DerivationResolutionGuard.in_progress).to be_empty
    end

    it 'drains the in-progress stack even after a cycle raises' do
      a = build_input_object_class('GuardDrainRaiseA')
      b = build_input_object_class('GuardDrainRaiseB')
      a.derive_from(b) { |pick| pick.required(:title) }
      b.derive_from(a) { |pick| pick.required(:title) }

      begin
        a.resolve_derivation!
      rescue GraphQL::Derivation::CyclicDependencyError
        nil
      end

      expect(GraphQL::Derivation::DerivationResolutionGuard.in_progress).to be_empty
    end
  end

  describe 'DerivableInputObject direct 2-node cycle' do
    it 'raises CyclicDependencyError instead of a misleading "does not define it" error' do
      a = build_input_object_class('CycleInputA')
      b = build_input_object_class('CycleInputB')
      a.derive_from(b) { |pick| pick.required(:title) }
      b.derive_from(a) { |pick| pick.required(:title) }

      expect { a.resolve_derivation! }.to raise_error(
        GraphQL::Derivation::CyclicDependencyError, /CycleInputA.*CycleInputB/,
      )
    end

    it 'includes the cycle path in arrow form' do
      a = build_input_object_class('CycleInputPathA')
      b = build_input_object_class('CycleInputPathB')
      a.derive_from(b) { |pick| pick.required(:title) }
      b.derive_from(a) { |pick| pick.required(:title) }

      expect { a.resolve_derivation! }.to raise_error(
        GraphQL::Derivation::CyclicDependencyError,
        /CycleInputPathA.*→.*CycleInputPathB.*→.*CycleInputPathA/,
      )
    end

    it 'is a ConfigurationError (per SPEC.md §2 hierarchy)' do
      a = build_input_object_class('CycleInputHierarchyA')
      b = build_input_object_class('CycleInputHierarchyB')
      a.derive_from(b) { |pick| pick.required(:title) }
      b.derive_from(a) { |pick| pick.required(:title) }

      expect { a.resolve_derivation! }.to raise_error(GraphQL::Derivation::ConfigurationError)
    end
  end

  describe 'DerivableObjectType direct 2-node cycle' do
    it 'raises CyclicDependencyError instead of a misleading "does not define it" error' do
      a = build_object_type_class('CycleObjectA')
      b = build_object_type_class('CycleObjectB')
      a.derive_from(b) { |pick| pick.fields(:title) }
      b.derive_from(a) { |pick| pick.fields(:title) }

      expect { a.resolve_derivation! }.to raise_error(
        GraphQL::Derivation::CyclicDependencyError, /CycleObjectA.*CycleObjectB/,
      )
    end
  end

  describe '3-node cycle (A -> B -> C -> A)' do
    it 'raises CyclicDependencyError with the full path for DerivableInputObject' do
      a = build_input_object_class('Cycle3A')
      b = build_input_object_class('Cycle3B')
      c = build_input_object_class('Cycle3C')
      a.derive_from(b) { |pick| pick.required(:title) }
      b.derive_from(c) { |pick| pick.required(:title) }
      c.derive_from(a) { |pick| pick.required(:title) }

      expect { a.resolve_derivation! }.to raise_error(
        GraphQL::Derivation::CyclicDependencyError,
        /Cycle3A.*→.*Cycle3B.*→.*Cycle3C.*→.*Cycle3A/,
      )
    end

    it 'raises CyclicDependencyError with the full path for DerivableObjectType' do
      a = build_object_type_class('Cycle3ObjA')
      b = build_object_type_class('Cycle3ObjB')
      c = build_object_type_class('Cycle3ObjC')
      a.derive_from(b) { |pick| pick.fields(:title) }
      b.derive_from(c) { |pick| pick.fields(:title) }
      c.derive_from(a) { |pick| pick.fields(:title) }

      expect { a.resolve_derivation! }.to raise_error(
        GraphQL::Derivation::CyclicDependencyError,
        /Cycle3ObjA.*→.*Cycle3ObjB.*→.*Cycle3ObjC.*→.*Cycle3ObjA/,
      )
    end
  end

  describe 'cross-mixin ordering (ObjectType source that is itself a pending DerivableObjectType)' do
    # Per the Appendix's supported directions, a genuine cross-mixin CYCLE is
    # not constructible: "InputObject args -> ObjectType fields" is forbidden
    # (raises ArgumentError at declaration time in FieldDerivation), so an
    # ObjectType can never derive_from an InputObject in the first place --
    # there is no way to route a path back from a DerivableInputObject to a
    # DerivableObjectType that could close a cycle. What IS reachable is
    # problem #2's cross-mixin manifestation: a DerivableInputObject deriving
    # from an ObjectType source that is itself a pending DerivableObjectType.
    # This proves that ordering-independence holds across the mixin boundary,
    # even though it isn't cyclic.
    def build_pending_object_type(name)
      object_type = build_object_type_class(name)
      object_type.derive_from(FixtureSchema::ExpenseType) { |pick| pick.fields(:title, :amount_cents) }
      object_type
    end

    it "resolves the ObjectType source's own pending derivation before reading its fields" do
      object_type = build_pending_object_type('CrossMixinSource')
      input_object = build_input_object_class('CrossMixinInput')
      input_object.derive_from(object_type) { |pick| pick.required(:title) }

      input_object.resolve_derivation!

      expect(input_object.arguments.keys).to contain_exactly('title')
    end

    it 'leaves the ObjectType source itself fully resolved as a side effect' do
      object_type = build_pending_object_type('CrossMixinSourceSideEffect')
      input_object = build_input_object_class('CrossMixinInputSideEffect')
      input_object.derive_from(object_type) { |pick| pick.required(:title) }

      input_object.resolve_derivation!

      expect(object_type.fields.keys).to contain_exactly('title', 'amountCents')
    end
  end

  describe 'order-independent valid chain (A.derive_from(B), B.derive_from(RealSource), no cycle)' do
    def build_chain
      a = build_input_object_class('ChainA')
      b = build_input_object_class('ChainB')
      b.derive_from(FixtureSchema::ExpenseType) { |pick| pick.required(:title, :amount_cents) }
      a.derive_from(b) { |pick| pick.required(:title) }
      [a, b]
    end

    it 'succeeds when the dependent (A) is included/resolved before its dependency (B)' do
      a, b = build_chain

      # `resolve_all!` iterates `included_classes` in inclusion order; A was
      # defined (and thus included) before B, so this exercises the
      # "dependent first" ordering that used to silently produce an empty
      # result (or a misleading ConfigurationError) prior to this fix.
      GraphQL::Derivation::DerivableInputObject.included_classes.replace([a, b])
      GraphQL::Derivation::DerivableInputObject.resolve_all!

      expect(a.arguments.keys).to contain_exactly('title')
    end

    it 'succeeds when the dependency (B) is included/resolved before its dependent (A)' do
      a, b = build_chain

      GraphQL::Derivation::DerivableInputObject.included_classes.replace([b, a])
      GraphQL::Derivation::DerivableInputObject.resolve_all!

      expect(a.arguments.keys).to contain_exactly('title')
    end

    it 'produces identical results regardless of resolution order' do
      order_ab = build_chain
      GraphQL::Derivation::DerivableInputObject.included_classes.replace(order_ab)
      GraphQL::Derivation::DerivableInputObject.resolve_all!

      order_ba = build_chain
      GraphQL::Derivation::DerivableInputObject.included_classes.replace(order_ba.reverse)
      GraphQL::Derivation::DerivableInputObject.resolve_all!

      a_first, = order_ab
      a_second, = order_ba
      expect(a_first.arguments.keys).to eq(a_second.arguments.keys)
    end

    it "does not leave B's derivation pending after resolving A (B resolves as a side effect)" do
      a, b = build_chain

      a.resolve_derivation!

      expect(b.arguments.keys).to contain_exactly('title', 'amountCents')
    end
  end

  describe 'idempotency across recursive resolution' do
    it 'does not raise when resolving the same chain twice via resolve_all!' do
      a = build_input_object_class('IdempotentChainA')
      b = build_input_object_class('IdempotentChainB')
      b.derive_from(FixtureSchema::ExpenseType) { |pick| pick.required(:title) }
      a.derive_from(b) { |pick| pick.required(:title) }
      GraphQL::Derivation::DerivableInputObject.included_classes.replace([a, b])

      GraphQL::Derivation::DerivableInputObject.resolve_all!

      expect { GraphQL::Derivation::DerivableInputObject.resolve_all! }.not_to raise_error
    end

    it 'does not duplicate arguments when resolving the same chain twice' do
      a = build_input_object_class('IdempotentChainDupA')
      b = build_input_object_class('IdempotentChainDupB')
      b.derive_from(FixtureSchema::ExpenseType) { |pick| pick.required(:title) }
      a.derive_from(b) { |pick| pick.required(:title) }
      GraphQL::Derivation::DerivableInputObject.included_classes.replace([a, b])

      GraphQL::Derivation::DerivableInputObject.resolve_all!
      GraphQL::Derivation::DerivableInputObject.resolve_all!

      expect([a.arguments.keys, b.arguments.keys]).to eq([['title'], ['title']])
    end

    it 'does not re-run either pick block on a second resolve_derivation! call' do
      call_counts = Hash.new(0)
      a = build_input_object_class('IdempotentChainCallCountA')
      b = build_input_object_class('IdempotentChainCallCountB')
      b.derive_from(FixtureSchema::ExpenseType) do |pick|
        call_counts[:b] += 1
        pick.required(:title)
      end
      a.derive_from(b) do |pick|
        call_counts[:a] += 1
        pick.required(:title)
      end

      a.resolve_derivation!
      a.resolve_derivation!
      b.resolve_derivation!

      expect(call_counts).to eq(a: 1, b: 1)
    end

    it 'resolving an already-resolved dependency does not spuriously interact with the guard stack' do
      a = build_input_object_class('IdempotentChainGuardA')
      b = build_input_object_class('IdempotentChainGuardB')
      b.derive_from(FixtureSchema::ExpenseType) { |pick| pick.required(:title) }
      a.derive_from(b) { |pick| pick.required(:title) }

      b.resolve_derivation! # resolve B standalone first
      a.resolve_derivation! # then resolve A, which re-touches B

      expect(a.arguments.keys).to contain_exactly('title')
    end
  end
end
# rubocop:enable RSpec/DescribeClass
