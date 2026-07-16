# frozen_string_literal: true

require 'graphql/derivation/errors'

module GraphQL
  module Derivation
    module Rails
      # Raised by `ControllerConcern#arguments` when the current action has no
      # registered InputObject -- i.e. neither `argument` nor `arguments_from`
      # was declared for it (SPEC.md §8.1). This is a programming error (a
      # controller asking for arguments it never declared), so it is a
      # `ConfigurationError` -- surfaced the first time the action is exercised.
      class MissingInputTypeError < GraphQL::Derivation::ConfigurationError; end

      # Raised by `ControllerConcern#arguments` when coercion of the request
      # input fails (required argument absent, type mismatch, unrecognised enum
      # value). SPEC.md §8.1 calls this "a hard error -- no rescue inside the
      # concern", raised at request time. Per the SPEC.md §2 philosophy
      # (ConfigurationError == load-time only), a request-time error must NOT
      # subclass ConfigurationError, so this descends from Error directly.
      class ArgumentCoercionError < GraphQL::Derivation::Error; end
    end
  end
end
