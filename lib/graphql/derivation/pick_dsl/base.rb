# frozen_string_literal: true

require 'did_you_mean'

module GraphQL
  module Derivation
    module PickDsl
      # Shared base for PickArguments and PickFields (SPEC.md §3). Handles
      # candidate-set bookkeeping and the `override` mechanism common to both
      # DSLs. Subclasses are responsible for the selection methods themselves
      # (`required`/`optional` for PickArguments, `fields` for PickFields) and
      # for building the final `selections` shape.
      class Base
        # @param candidate_names [Enumerable<Symbol>] the names available to
        #   pick/override, as derived from +source_name+.
        # @param source_name [String, nil] a human-readable identifier for the
        #   class/source these candidates were derived from (e.g. a class
        #   name, or `source.inspect` for anonymous classes), used only to
        #   produce clearer error messages. Optional so existing internal
        #   callers/tests that construct Pick objects directly keep working;
        #   falls back to a generic label when absent.
        def initialize(candidate_names, source_name: nil)
          @candidate_names = candidate_names.to_set
          @source_name = source_name || 'the derivation source'
          @overrides = Hash.new { |hash, key| hash[key] = {} }
        end

        # Applies the given options to an already-selected field.
        # Raises ConfigurationError if +field_name+ is not in the candidate
        # set, or if it has not been selected yet.
        def override(field_name, **opts)
          check_known_candidate!(field_name)
          check_allowed_override_opts!(opts)
          unless selected?(field_name)
            raise GraphQL::Derivation::ConfigurationError,
              "Cannot override #{field_name.inspect}: it has not been picked yet. " \
              "Call pick.#{selection_method_hint} #{field_name.inspect} (or the equivalent " \
              'selection method) before overriding it.'
          end

          @overrides[field_name].merge!(opts)
        end

        # Validates the accumulated selections. Raises ConfigurationError on
        # any violation. Subclasses extend this with their own rules.
        def validate!
          return unless selected_names.empty?

          raise GraphQL::Derivation::ConfigurationError,
            "No fields or arguments were selected from #{source_name}. Call " \
            "pick.#{selection_method_hint} with at least one of its available names: " \
            "#{available_names_list}."
        end

        # Returns the resolved selections. Must be implemented by subclasses.
        def selections
          raise NotImplementedError
        end

        private

        attr_reader :candidate_names, :overrides, :source_name

        # Subclasses must implement: returns the name of the primary
        # selection method (e.g. `required`/`optional` for PickArguments,
        # `fields` for PickFields), used to point developers at the right
        # method in error messages.
        def selection_method_hint
          raise NotImplementedError
        end

        # Subclasses must implement: returns the Array of keywords accepted
        # by `override` for this Pick subclass (SPEC.md §3.2/§3.3's "Valid
        # override opts").
        def allowed_override_opts
          raise NotImplementedError
        end

        def check_allowed_override_opts!(opts)
          unknown_opts = opts.keys - allowed_override_opts
          return if unknown_opts.empty?

          unknown_opts.each { |opt| raise_unknown_override_opt_error(opt) }
        end

        def raise_unknown_override_opt_error(opt)
          suggestion = did_you_mean(opt, allowed_override_opts)
          message = "Unknown override option #{opt.inspect} for #{self.class.name.split('::').last}."
          message += " Did you mean #{suggestion.inspect}?" if suggestion
          message += " Valid options: #{allowed_override_opts.sort.map(&:inspect).join(', ')}."

          raise GraphQL::Derivation::ConfigurationError, message
        end

        # Best-effort typo suggestion via stdlib `did_you_mean` (already
        # bundled with Ruby, not a new runtime dependency -- AGENTS.md).
        # Handles the common "missing/extra/transposed letter" typo case the
        # review comment called out (e.g. :descriptoin).
        def did_you_mean(opt, allowed)
          DidYouMean::SpellChecker.new(dictionary: allowed).correct(opt).first
        end

        def available_names_list
          candidate_names.to_a.sort.map(&:inspect).join(', ')
        end

        def check_known_candidate!(field_name)
          return if candidate_names.include?(field_name)

          raise GraphQL::Derivation::ConfigurationError,
            "You're trying to derive a field or argument #{field_name.inspect} from " \
            "#{source_name}, but #{source_name} does not define it. Available names on " \
            "#{source_name} are: #{available_names_list}."
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
