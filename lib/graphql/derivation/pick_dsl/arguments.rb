# frozen_string_literal: true

require 'set'
require 'graphql/derivation/pick_dsl/base'

module GraphQL
  module Derivation
    module PickDsl
      # Pick DSL used by ArgumentDerivation (SPEC.md §3.2). Constructed with
      # the candidate set of allowed argument names; the pick block selects
      # names via `required`/`optional` and may adjust them via `override`.
      #
      # After `validate!`, `selections` returns
      # `{name => [required_boolean, overrides]}` pairs, matching the shape
      # consumed by ArgumentDerivation's resolution algorithm (SPEC.md §4.4).
      class PickArguments < Base
        def initialize(candidate_names)
          super
          @required_names = Set.new
          @optional_names = Set.new
        end

        # Selects the named fields and marks them `required: true`.
        def required(*field_names)
          select(field_names, into: @required_names)
        end

        # Selects the named fields and marks them `required: false`.
        def optional(*field_names)
          select(field_names, into: @optional_names)
        end

        def validate!
          super

          duplicates = @required_names & @optional_names
          return if duplicates.empty?

          raise GraphQL::Derivation::ConfigurationError,
            "Fields passed to both required and optional: #{duplicates.to_a.inspect}"
        end

        def selections
          selected_names.to_h do |name|
            [name, [@required_names.include?(name), overrides[name]]]
          end
        end

        private

        # Re-selecting a name into the same bucket is idempotent; only
        # cross-bucket duplication (required then optional, or vice versa) is
        # a validation error, caught by validate! once both buckets are final.
        def select(field_names, into:)
          field_names.each do |field_name|
            check_known_candidate!(field_name)
            into << field_name
          end
        end

        def selected?(field_name)
          @required_names.include?(field_name) || @optional_names.include?(field_name)
        end

        def selected_names
          @required_names | @optional_names
        end
      end
    end
  end
end
