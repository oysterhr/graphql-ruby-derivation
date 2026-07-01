# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'
require 'graphql'
require 'graphql/derivation/errors'

module GraphQL
  module Derivation
    module Rails
      module Adapters
        # SPEC.md §9, the ActiveRecord Adapter. Maps `ActiveRecord::Base`
        # column definitions to GraphQL field-ready type/null information.
        # Used by `FieldDerivation` (core) when the source is an AR model
        # class -- see that engine's `active_record_source?` dispatch, which
        # only activates once this file has been required (i.e. once the
        # `graphql/derivation/rails/active_record` require path has been
        # opted into).
        #
        # One mapper instance is built per `(model, pick_block)` resolution
        # by `FieldDerivation`; the *enum cache* (§9.2's memoization
        # requirement) is therefore class-level, keyed by `[model.name,
        # column name]` (see the cache's own comment below for why the name
        # string, not the model class object, is used as the key), so the
        # same generated enum class is returned across separate
        # `FieldDerivation.resolve` calls for the same model/column -- not
        # just within a single mapper instance.
        #
        # ## Excluded columns (§9.4)
        #
        # `id`, `created_at`, `updated_at` are excluded from the candidate
        # set entirely -- `candidates` filters them out before they are ever
        # offered to the pick block.
        #
        # ## Foreign-key naming override (§9.1 vs §9.4 reconciliation)
        #
        # §9.1's column type mapping table is keyed by the AR column's
        # reported `:type` symbol -- Rails' `connection.columns`
        # introspection has no distinct "foreign key" type; a `bigint`
        # column is reported as `:bigint` whether or not it happens to hold
        # another table's primary key. §9.4 separately states "foreign key
        # columns ... map to GraphQL::Types::ID". The only way to reconcile
        # these without contradicting §9.1's type-keyed table is to treat
        # §9.4's claim as a NAME-based override applied on top of the
        # type-based default: a column whose name ends in `_id` (and is not
        # the primary key `id` column itself, which is excluded entirely by
        # §9.4) is mapped to `GraphQL::Types::ID` whenever its underlying
        # `:type` would otherwise resolve to `GraphQL::Types::Int` (i.e.
        # `:integer` or `:bigint`). Columns of any other underlying type
        # that happen to end in `_id` (there are none in practice, but
        # nothing in the spec rules them out) are NOT overridden -- the
        # name-based rule only ever narrows Int down to ID, it never
        # changes any other type mapping.
        class ActiveRecordMapper
          # SPEC.md §9.4: excluded from the candidate set entirely.
          EXCLUDED_COLUMNS = %w[id created_at updated_at].freeze

          # SPEC.md §9.1's column type mapping table, for types whose
          # GraphQL counterpart never depends on column name or enum
          # status. `:enum` and the unsupported/array rows are handled
          # separately (see `mapped_type`).
          SIMPLE_TYPE_MAP = {
            string: ::String,
            text: ::String,
            citext: ::String,
            integer: GraphQL::Types::Int,
            bigint: GraphQL::Types::Int,
            float: ::Float,
            decimal: ::Float,
            numeric: ::Float,
            boolean: GraphQL::Types::Boolean,
            date: GraphQL::Types::ISO8601Date,
            datetime: GraphQL::Types::ISO8601DateTime,
            timestamp: GraphQL::Types::ISO8601DateTime,
            timestamptz: GraphQL::Types::ISO8601DateTime,
            uuid: GraphQL::Types::ID,
          }.freeze

          # SPEC.md §9.1: these types have no GraphQL primitive mapping and
          # always raise, regardless of column name.
          UNSUPPORTED_TYPES = %i[jsonb json hstore].freeze

          # SPEC.md §9.1: `[element_type]` array mapping. The stub/AR column
          # contract used here mirrors `ActiveRecord::ConnectionAdapters::
          # Column#sql_type`: for an array column, `sql_type` is the
          # element's SQL type name followed by `[]` (Rails' own
          # convention, e.g. `"character varying[]"`, `"text[]"`,
          # `"integer[]"`). This maps that prefix back to one of
          # `SIMPLE_TYPE_MAP`'s keys; anything not listed here is treated
          # as an unsupported element type.
          ARRAY_SQL_TYPE_ALIASES = {
            'character varying' => :string,
            'varchar' => :string,
            'text' => :text,
            'citext' => :citext,
            'integer' => :integer,
            'bigint' => :bigint,
            'float' => :float,
            'double precision' => :float,
            'decimal' => :decimal,
            'numeric' => :numeric,
            'boolean' => :boolean,
            'date' => :date,
            'datetime' => :datetime,
            'timestamp' => :timestamp,
            'timestamptz' => :timestamptz,
            'uuid' => :uuid,
          }.freeze

          # Class-level enum cache (SPEC.md §9.2): `[model.name, column_name]
          # => { model:, enum: }`. Shared across mapper instances/resolutions
          # so the same column always yields the same enum class object.
          #
          # Keyed by `model.name` (a String), not the `model` class object
          # itself. Under Rails class reloading (Zeitwerk), a reloaded AR
          # model is a NEW class object with the same `.name` -- an
          # identity-based key (`[model, ...]`) would never hit the old
          # cache slot after a reload, silently leaking one stale entry per
          # reload while also generating a fresh enum with the exact same
          # `graphql_name` (derived from `model.name`, which is stable). If
          # anything still held a reference to the old enum, that would be
          # two distinct classes sharing one `graphql_name` -- the same
          # `DuplicateNamesError` risk as `ArgumentSchema#register_input_object`.
          #
          # A plain `||=` on the string key alone would fix the leak but
          # introduce a subtler bug: after a reload, the string key matches
          # the STALE slot, so `||=` would keep serving the OLD enum (built
          # from the old model class) forever, even though `model` is now a
          # different, current class object. To detect "the key matches but
          # the model has actually changed identity (a reload happened)", the
          # cache stores the model class object alongside the enum and
          # compares it with `equal?` before reusing a hit; a mismatch
          # rebuilds and replaces the slot in place (see `enum_type` below).
          @enum_cache = {}

          class << self
            attr_reader :enum_cache
          end

          def self.candidates(model)
            new(model).candidates
          end

          def initialize(model)
            @model = model
          end

          # Returns `{name => Candidate}` for every column eligible to be
          # offered to the pick block (SPEC.md §5.2/§9.4), keyed by the
          # column's original (snake_case) name as a Symbol, matching the
          # convention used by `ObjectTypeToField`'s candidates.
          #
          # Type mapping is deliberately lazy (see `Candidate#type` below):
          # a column whose type has no GraphQL mapping (§9.1's unsupported
          # rows) must only raise `UnsupportedColumnTypeError` if that
          # column is actually selected by the pick block -- a model with
          # an unrelated unsupported column (e.g. a `jsonb` column) must
          # still be a usable FieldDerivation source for its other columns.
          def candidates
            model.columns.each_with_object({}) do |column, result|
              name = column.name.to_s
              next if EXCLUDED_COLUMNS.include?(name)

              result[name.to_sym] = candidate_for(column)
            end
          end

          private

          attr_reader :model

          # `type` resolves `mapped_type(column)` lazily, on first access,
          # so unselected unsupported columns never raise (see `candidates`
          # comment above). Memoized since FieldDerivation may read `type`
          # more than once per resolution.
          class Candidate
            attr_reader :name, :null

            def initialize(name, null, &type_resolver)
              @name = name
              @null = null
              @type_resolver = type_resolver
            end

            def type
              return @type if defined?(@type)

              @type = @type_resolver.call
            end
          end

          def candidate_for(column)
            name = column.name.to_s
            Candidate.new(name.to_sym, null_default?(column)) { mapped_type(column) }
          end

          # SPEC.md §9.3: NOT NULL DB constraint => null: false default;
          # otherwise null: true. The pick block may still override either
          # direction (handled by FieldDerivation/PickFields, not here).
          def null_default?(column)
            column.null != false
          end

          # SPEC.md §9.1/§9.2: dispatches a column to its mapped GraphQL
          # type, applying the foreign-key naming override (see class
          # comment) after the base type-keyed lookup.
          def mapped_type(column)
            base_type = base_mapped_type(column)
            apply_foreign_key_override(column, base_type)
          end

          def base_mapped_type(column)
            type = column.type

            return enum_type(column) if enum_column?(column)
            return array_element_type(column) if type == :array

            raise_unsupported!(column) if UNSUPPORTED_TYPES.include?(type)

            SIMPLE_TYPE_MAP.fetch(type) { raise_unsupported!(column) }
          end

          # SPEC.md §9.1's foreign-key reconciliation (see class comment):
          # only narrows an Int-mapped column to ID, only when the column
          # name ends in `_id` (and isn't the already-excluded `id` PK
          # itself, which never reaches this method).
          def apply_foreign_key_override(column, base_type)
            return base_type unless base_type == GraphQL::Types::Int
            return base_type unless foreign_key_column?(column)

            GraphQL::Types::ID
          end

          def foreign_key_column?(column)
            column.name.to_s.end_with?('_id')
          end

          # SPEC.md §9.2: a column is enum-mapped if its AR `:type` is
          # literally `:enum` (native Postgres enum) OR its name matches a
          # key in `model.defined_enums` (Rails enum, typically
          # integer-backed).
          def enum_column?(column)
            column.type == :enum || model.defined_enums.key?(column.name.to_s)
          end

          # See the `@enum_cache` comment above: the cache slot is only
          # reused when BOTH the string key matches AND the cached entry's
          # `model` is the identical class object as the current `model` --
          # a string-key match with a differing model object means the model
          # was reloaded, so the slot is rebuilt and replaced rather than
          # blindly reused.
          def enum_type(column)
            cache = self.class.enum_cache
            key = [model.name, column.name.to_s]
            cached = cache[key]
            return cached[:enum] if cached && cached[:model].equal?(model)

            cache[key] = {model: model, enum: build_enum_type(column)}
            cache[key][:enum]
          end

          def build_enum_type(column)
            values = enum_values(column)
            raise_unsupported!(column) if values.nil? || values.empty?

            name = "#{model.name}#{column.name.to_s.camelize}Enum"
            Class.new(GraphQL::Schema::Enum) do
              graphql_name(name)
              values.each { |value| value(value.upcase) }
            end
          end

          # SPEC.md §9.2 step 1: `Model.defined_enums[column_name].keys`.
          # A native Postgres `:enum` column with no matching
          # `defined_enums` entry has no way to determine its values at
          # class load time, so it is unsupported (§9.2's last paragraph).
          def enum_values(column)
            enum_definition = model.defined_enums[column.name.to_s]
            return unless enum_definition

            enum_definition.keys.map(&:to_s)
          end

          # SPEC.md §9.1: `[element_type]` if the array's element type is
          # itself mappable, else `UnsupportedColumnTypeError`. See
          # `ARRAY_SQL_TYPE_ALIASES` for how the element type is determined.
          def array_element_type(column)
            element_type = element_type_for(column)
            raise_unsupported!(column) if element_type.nil?

            [element_type]
          end

          def element_type_for(column)
            sql_type = column.respond_to?(:sql_type) ? column.sql_type : nil
            return unless sql_type

            base = sql_type.to_s.delete_suffix('[]').strip
            symbol = ARRAY_SQL_TYPE_ALIASES[base]
            return unless symbol

            SIMPLE_TYPE_MAP[symbol]
          end

          def raise_unsupported!(column)
            raise GraphQL::Derivation::UnsupportedColumnTypeError,
              "Column #{model.name}##{column.name} has type #{column.type.inspect}, which has no " \
              'GraphQL mapping (SPEC.md §9.1).'
          end
        end
      end
    end
  end
end
