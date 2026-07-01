# frozen_string_literal: true

require 'set'
require 'graphql/derivation/pick_dsl/base'

module GraphQL
  module Derivation
    module PickDsl
      # Pick DSL used by FieldDerivation (SPEC.md §3.3). Constructed with the
      # candidate set of allowed field names; the pick block selects names
      # via `fields` (which may be called multiple times — selections
      # accumulate) and may adjust them via `override`.
      #
      # After `validate!`, `selections` returns `{name => overrides}` pairs,
      # matching the shape consumed by FieldDerivation's resolution algorithm
      # (SPEC.md §5.4).
      class PickFields < Base
        # SPEC.md §3.3's "Valid override opts" for PickFields.
        ALLOWED_OVERRIDE_OPTS = %i[
          description deprecation_reason null method resolver name camelize
        ].freeze

        def initialize(candidate_names, source_name: nil)
          super
          @selected_names = Set.new
        end

        # Selects the named fields from the candidate set. May be called
        # multiple times; selections accumulate.
        def fields(*field_names)
          field_names.each do |field_name|
            check_known_candidate!(field_name)
            @selected_names << field_name
          end
        end

        def selections
          selected_names.to_h do |name|
            [name, overrides[name]]
          end
        end

        private

        def selected?(field_name)
          @selected_names.include?(field_name)
        end

        attr_reader :selected_names

        def selection_method_hint
          'fields'
        end

        def allowed_override_opts
          ALLOWED_OVERRIDE_OPTS
        end
      end
    end
  end
end
