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
      # Fields whose source type returns another Object type ("edges") are
      # handled by FieldDerivation like this, in order of precedence:
      #
      #   - `pick.override name, type: SomeType` -- the copy returns exactly
      #     that type. The explicit escape hatch (e.g. a legacy type during
      #     a transition).
      #   - `pick.project name do |nested| ... end` -- the copy returns a new,
      #     anonymous derived type built from the source field's own return
      #     type, picking only what the nested block says. For types that
      #     are private to the source and reachable only through this field.
      #   - `pick.expose_full name` -- the copy returns the source field's
      #     return type as-is (the whole thing). Greppable on purpose.
      #   - none of the above -- the copy returns a late-bound reference to
      #     the type's GraphQL *name*, which the schema resolves to whatever
      #     type carries that name there (`ProjectedEdge`). For entry types
      #     that have their own projection in the schema.
      #
      # Enums, scalars and other leaf types are never edges: they are copied
      # as-is.
      #
      # After `validate!`, `selections` returns `{name => overrides}` pairs,
      # matching the shape consumed by FieldDerivation's resolution algorithm
      # (SPEC.md §5.4), and `projections` returns `{name => block}` for every
      # field picked through `project`.
      class PickFields < Base
        # SPEC.md §3.3's "Valid override opts" for PickFields.
        ALLOWED_OVERRIDE_OPTS = %i[
          description deprecation_reason null method resolver name camelize type expose_full
        ].freeze

        def initialize(candidate_names, source_name: nil)
          super
          @selected_names = Set.new
          @projections = {}
        end

        # Selects the named fields from the candidate set. May be called
        # multiple times; selections accumulate.
        #
        # Keyword arguments are shorthand for `project`: each key is an edge
        # field and each value the list of names to pick from its type.
        #
        #   pick.fields :id, :state, file: %i[url filename]
        #
        # is the same as
        #
        #   pick.fields :id, :state
        #   pick.project(:file) { |file| file.fields :url, :filename }
        def fields(*field_names, **nested)
          field_names.each do |field_name|
            check_known_candidate!(field_name)
            @selected_names << field_name
          end
          nested.each do |field_name, nested_names|
            project(field_name) { |nested_pick| nested_pick.fields(*Array(nested_names)) }
          end
        end

        # Selects +field_name+ and declares an inline projection of its
        # return type. The block receives a nested PickFields for that type
        # and follows the same rules (it may itself call `project`).
        def project(field_name, &block)
          raise ArgumentError, "pick.project(#{field_name.inspect}) requires a block" unless block

          check_known_candidate!(field_name)
          @selected_names << field_name
          @projections[field_name] = block
        end

        # Selects the named edge fields and marks them to be copied with
        # their source return type unchanged. Equivalent to
        # `pick.fields(name)` plus `pick.override(name, expose_full: true)`.
        def expose_full(*field_names)
          fields(*field_names)
          field_names.each { |field_name| override(field_name, expose_full: true) }
        end

        def selections
          selected_names.to_h do |name|
            [name, overrides[name]]
          end
        end

        # @return [Hash{Symbol => Proc}] nested pick blocks declared via
        #   `project`, keyed by field name.
        attr_reader :projections

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
