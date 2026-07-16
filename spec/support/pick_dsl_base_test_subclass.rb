# frozen_string_literal: true

# Minimal concrete subclass exercising GraphQL::Derivation::PickDsl::Base's
# own behaviour directly (spec/graphql/derivation/pick_dsl/base_spec.rb).
# PickArguments/PickFields cover Base only indirectly through their own
# selection semantics -- this fills in the gap the review flagged (T.52).
# Defined as a real (named) constant, not `Class.new`, because
# `raise_unknown_override_opt_error` calls `self.class.name.split` -- an
# anonymous class's `#name` is nil.
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
