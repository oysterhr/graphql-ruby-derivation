# frozen_string_literal: true

# Minimal concrete subclass exercising Base's own behaviour directly.
# PickArguments/PickFields cover Base only indirectly through their own
# selection semantics -- this fills in the gap the review flagged (T.52).
# Defined as a real (named) constant, not `Class.new`, because
# `raise_unknown_override_opt_error` calls `self.class.name.split` --
# an anonymous class's `#name` is nil.
class PickDslBaseTestSubclass < GraphQL::Derivation::PickDsl::Base
  def initialize(candidate_names, source_name: nil)
    super
    @selected = Set.new
  end

  def select(*field_names)
    field_names.each do |field_name|
      check_known_candidate!(field_name)
      @selected << field_name
    end
  end

  def selections
    selected_names.to_h { |name| [name, overrides[name]] }
  end

  private

  def selected?(field_name)
    @selected.include?(field_name)
  end

  def selected_names
    @selected
  end

  def selection_method_hint
    'select'
  end

  def allowed_override_opts
    %i[description default_value]
  end
end

RSpec.describe GraphQL::Derivation::PickDsl::Base do
  subject(:pick) { concrete_class.new(%i[name email age]) }

  let(:concrete_class) { PickDslBaseTestSubclass }

  describe '#initialize' do
    it 'falls back to a generic source label when source_name is omitted' do
      expect { pick.select(:bogus) }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /derivation source/i,
      )
    end

    it 'uses the given source_name in error messages' do
      named_pick = concrete_class.new(%i[name email age], source_name: 'SomeType')

      expect { named_pick.select(:bogus) }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /SomeType/,
      )
    end
  end

  describe '#override' do
    it 'raises ConfigurationError for a candidate that does not exist' do
      expect { pick.override(:bogus, description: 'x') }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /bogus.*available names.*age.*email.*name/im,
      )
    end

    it 'raises ConfigurationError when the candidate exists but was not selected yet' do
      expect { pick.override(:name, description: 'x') }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /name.*has not been picked yet.*pick\.select/im,
      )
    end

    it 'raises ConfigurationError for an option outside allowed_override_opts' do
      pick.select(:name)

      expect { pick.override(:name, bogus_opt: 'x') }.to raise_error(
        GraphQL::Derivation::ConfigurationError,
        /bogus_opt.*Valid options: :default_value, :description/im,
      )
    end

    it 'suggests a correction via did_you_mean for a close typo' do
      pick.select(:name)

      expect { pick.override(:name, descriptoin: 'x') }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /descriptoin.*Did you mean :description\?/im,
      )
    end

    it 'merges options onto an already-selected candidate' do
      pick.select(:name)
      pick.override(:name, description: 'The name')

      expect(pick.selections[:name]).to eq(description: 'The name')
    end

    it 'accumulates options across multiple override calls' do
      pick.select(:name)
      pick.override(:name, description: 'The name')
      pick.override(:name, default_value: 'anon')

      expect(pick.selections[:name]).to eq(description: 'The name', default_value: 'anon')
    end
  end

  describe '#validate!' do
    it 'raises ConfigurationError when nothing has been selected' do
      expect { pick.validate! }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /No fields or arguments were selected/,
      )
    end

    it 'lists the available candidate names, sorted' do
      expect { pick.validate! }.to raise_error(
        GraphQL::Derivation::ConfigurationError, /:age, :email, :name/,
      )
    end

    it 'does not raise once at least one candidate has been selected' do
      pick.select(:name)

      expect { pick.validate! }.not_to raise_error
    end
  end

  describe '#selections' do
    it 'raises NotImplementedError when not overridden by a subclass' do
      bare_pick = described_class.new(%i[name])

      expect { bare_pick.selections }.to raise_error(NotImplementedError)
    end
  end

  describe 'subclass contract' do
    subject(:bare_pick) { described_class.new(%i[name]) }

    it 'requires selection_method_hint to be implemented' do
      expect { bare_pick.send(:selection_method_hint) }.to raise_error(NotImplementedError)
    end

    it 'requires allowed_override_opts to be implemented' do
      expect { bare_pick.send(:allowed_override_opts) }.to raise_error(NotImplementedError)
    end

    it 'requires selected? to be implemented' do
      expect { bare_pick.send(:selected?, :name) }.to raise_error(NotImplementedError)
    end

    it 'requires selected_names to be implemented' do
      expect { bare_pick.send(:selected_names) }.to raise_error(NotImplementedError)
    end
  end
end
