# frozen_string_literal: true

module GraphQL
  module Derivation
    # Base class for all errors raised by this gem.
    class Error < StandardError; end

    # Catch-all for invalid declarations (unknown field selected, override on
    # unselected field, sibling cycle). Always raised at class load time, never
    # at request time.
    class ConfigurationError < Error; end

    # Raised when sibling resolution detects a cycle. Message includes the
    # full cycle path (e.g. `create → update → create`).
    class CyclicDependencyError < ConfigurationError; end

    # Raised when field derivation encounters a field whose resolver cannot be
    # transferred to the destination type without an explicit override.
    class UnresolvableFieldError < ConfigurationError; end

    # Raised by the ActiveRecord adapter when a column type has no GraphQL
    # primitive mapping.
    class UnsupportedColumnTypeError < Error; end
  end
end
