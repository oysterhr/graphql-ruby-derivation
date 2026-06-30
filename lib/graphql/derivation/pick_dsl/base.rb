# frozen_string_literal: true

module GraphQL
  module Derivation
    module PickDsl
      # Shared base for PickArguments and PickFields (SPEC.md §3). Handles
      # candidate-set bookkeeping and the `override` mechanism common to both
      # DSLs. Subclasses are responsible for the selection methods themselves
      # (`required`/`optional` for PickArguments, `fields` for PickFields) and
      # for building the final `selections` shape.
      class Base
        def initialize(candidate_names)
          @candidate_names = candidate_names.to_set
          @overrides = Hash.new { |hash, key| hash[key] = {} }
        end

        # Applies the given options to an already-selected field.
        # Raises ConfigurationError if +field_name+ is not in the candidate
        # set, or if it has not been selected yet.
        def override(field_name, **opts)
          check_known_candidate!(field_name)
          unless selected?(field_name)
            raise GraphQL::Derivation::ConfigurationError,
              "Cannot override #{field_name.inspect}: it has not been selected"
          end

          @overrides[field_name].merge!(opts)
        end

        # Validates the accumulated selections. Raises ConfigurationError on
        # any violation. Subclasses extend this with their own rules.
        def validate!
          return unless selected_names.empty?

          raise GraphQL::Derivation::ConfigurationError, 'No fields were selected'
        end

        # Returns the resolved selections. Must be implemented by subclasses.
        def selections
          raise NotImplementedError
        end

        private

        attr_reader :candidate_names, :overrides

        def check_known_candidate!(field_name)
          return if candidate_names.include?(field_name)

          raise GraphQL::Derivation::ConfigurationError,
            "Unknown field #{field_name.inspect}: not in the candidate set"
        end

        # Subclasses must implement: returns true if +field_name+ has already
        # been selected (via required/optional/fields).
        def selected?(field_name)
          raise NotImplementedError
        end

        # Subclasses must implement: returns the set of currently selected
        # field names.
        def selected_names
          raise NotImplementedError
        end
      end
    end
  end
end
