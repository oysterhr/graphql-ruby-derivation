# frozen_string_literal: true

module GraphQL
  module Derivation
    module Mappers
      # Maps an ObjectType's candidate fields to field-copy candidates per
      # SPEC.md §5.2 (candidate enumeration) and §5.3 (resolver handling).
      #
      # Relay connection fields are excluded from the candidate set entirely:
      # a connection type is one whose ancestors include
      # `GraphQL::Types::Relay::BaseConnection`. (Matching on a `Connection`
      # name suffix, as ObjectTypeToArgument does, is deliberately NOT used
      # here: a plain object type may legitimately be called e.g.
      # `SyncConnection`, and a field returning it must stay derivable.)
      # Unlike ObjectTypeToArgument, plain nested Object-type fields and
      # list-of-Object fields ARE eligible candidates here: copying a field
      # (rather than deriving an argument type from it) does not require
      # resolving an input type, so there is no need to defer or special-case
      # them.
      #
      # Each candidate carries enough information for FieldDerivation to
      # decide which of the resolver cases applies:
      #
      #   Case 1 -- default method resolver: the field resolves straight to
      #     the underlying object. Copy as-is.
      #   Case 2 -- `method:` option: `field.method_sym` differs from the
      #     field's original name. Copy with the same `method:`.
      #   Case 3 -- custom class resolver: the source class responds to
      #     `resolve_#{name}` (a singleton/class method, e.g.
      #     `def self.resolve_full_name(obj, args, ctx)`). Unresolvable
      #     without an explicit `method:`/`resolver:` override.
      #   Case 4 -- instance resolver method: the source class defines an
      #     instance method named after the field's `resolver_method`
      #     (`def submitted_on ... end`). graphql-ruby calls that method on
      #     the *type instance* before ever looking at the underlying object,
      #     so the copy must keep routing through the source type --
      #     FieldDerivation attaches `SourceResolverExtension` for this.
      #     Checked before Case 2, because graphql-ruby itself prefers the
      #     type-instance method over `method:`.
      #
      # SPEC.md §5.3's literal text checks Case 3 via
      # `source.method_defined?("resolve_#{field_name}")` -- but
      # `method_defined?` only inspects *instance* methods, and the
      # fixture's Case 3 resolver (`ExpenseType.resolve_full_name`) is a
      # singleton/class method, for which `method_defined?` always returns
      # false. We use `source.respond_to?("resolve_#{field_name}")` instead,
      # which correctly detects singleton methods (equivalent to
      # `source.singleton_class.method_defined?(...)`). This is a deliberate
      # deviation from SPEC.md's literal prose; see the PR description for
      # this engine's history.
      class ObjectTypeToField
        # A field-copy candidate. `type` is the field's fully-wrapped return
        # type (List/NonNull applied, exactly as declared on the source
        # field) -- field copying does not change nullability/list-ness the
        # way argument derivation does, so the wrapped type is carried
        # through unchanged rather than re-derived.
        #
        # `resolver_case` is one of :default, :method, :custom_resolver or
        # :instance_method (Case 1/2/3/4 above). `method_override` is the
        # `method:` option to forward for Case 2 (nil otherwise). Named
        # `method_override`, not `method`, to avoid shadowing `Struct#method`
        # (Lint/StructNewOverride).
        Candidate = Struct.new(:name, :type, :resolver_case, :method_override, :field)

        def self.candidates(source)
          new(source).candidates
        end

        def initialize(source)
          @source = source
        end

        # Returns `{name => Candidate}` for every field eligible to be
        # offered to the pick block (SPEC.md §5.2).
        def candidates
          source.fields.each_with_object({}) do |(_graphql_name, field), result|
            next if connection_type?(field.type.unwrap)

            name = field.original_name
            result[name] = candidate_for(field, name)
          end
        end

        private

        attr_reader :source

        def connection_type?(type)
          type.respond_to?(:ancestors) && type.ancestors.include?(GraphQL::Types::Relay::BaseConnection)
        end

        def candidate_for(field, name)
          Candidate.new(name, field.type, resolver_case(field, name), method_override(field, name), field)
        end

        # SPEC.md §5.3's Case 2: an explicit `method:` option is present
        # whenever the resolved `method_sym` differs from the field's own
        # name -- `GraphQL::Schema::Field` falls back to the field name
        # itself when no `method:` is given, so equality means "default".
        def method_override?(field, name)
          field.method_sym != name
        end

        def method_override(field, name)
          field.method_sym if method_override?(field, name)
        end

        def resolver_case(field, name)
          return :instance_method if instance_resolver?(field)
          return :method if method_override?(field, name)
          return :custom_resolver if custom_resolver?(name)

          :default
        end

        # Case 4: the source type (or a module it includes) defines an
        # instance method graphql-ruby would call for this field. Methods
        # every `GraphQL::Schema::Object` already has (`object`, `context`,
        # ...) don't count -- a field named `context` resolves to the
        # underlying object just like any other on the source, and must on
        # the copy too.
        def instance_resolver?(field)
          method_name = field.resolver_method
          source.method_defined?(method_name) && !GraphQL::Schema::Object.method_defined?(method_name)
        end

        # See the class comment: `respond_to?` (not SPEC.md's literal
        # `method_defined?`) is required to detect singleton/class-method
        # resolvers like `def self.resolve_full_name(...)`.
        def custom_resolver?(name)
          source.respond_to?("resolve_#{name}")
        end
      end
    end
  end
end
