# frozen_string_literal: true

module GraphQL
  module Derivation
    # Attached by `FieldDerivation` to a derived field whose source type
    # defines an instance method for it (SPEC.md §5.3 Case 4). graphql-ruby
    # resolves a field by first asking the *type instance* for
    # `resolver_method`, then falling back to the underlying object. A field
    # copied onto another type would skip the source's method and hit the
    # object directly, silently changing behaviour (or raising) at query
    # time.
    #
    # This extension swaps the type instance for an instance of the source
    # type before the field resolves, so the source's method runs exactly as
    # it does on the source type: same `object`, same `context`, same
    # dataloader. Everything else in `Field#resolve` (authorization, extras,
    # other extensions, lazy handling) is untouched because the swap happens
    # inside graphql-ruby's own extension pipeline.
    #
    # The source instance is built with `authorized_new`, graphql-ruby's
    # public constructor for type instances (`new` is protected). If the
    # source type has its own `authorized?` rule, it therefore applies to the
    # copied field as well.
    class SourceResolverExtension < GraphQL::Schema::FieldExtension
      def resolve(object:, arguments:, context:)
        yield(options.fetch(:source).authorized_new(object.object, context), arguments)
      end
    end
  end
end
