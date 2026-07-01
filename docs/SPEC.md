# graphql-ruby-derivation — Gem Specification

A Ruby gem providing composable, independently requireable utilities for working with
`graphql-ruby` schemas. Argument and field derivation from multiple source types, with optional
Rails and ActiveRecord integration.

---

## Table of Contents & Implementation Status

Status legend: **Specified** (design done, no code yet) · **In Progress** (a PR is actively
implementing it) · **Implemented** (merged to `main`) · **N/A** (reference/appendix material, not
itself implementable).

This table must be kept current — when a PR implementing part of the spec merges, update the
corresponding row(s) in the same PR. See `AGENTS.md`.

| Section | Status |
|---|---|
| [1. Gem Identity](#1-gem-identity) | Specified |
| [2. Error Types](#2-error-types) | Implemented |
| [3. Pick DSL](#3-pick-dsl) | Implemented |
| [4. Argument Derivation Engine](#4-argument-derivation-engine) | Implemented |
| [5. Field Derivation Engine](#5-field-derivation-engine) | Implemented |
| [6. `DerivableInputObject`](#6-derivableinputobject) | Implemented |
| [7. `DerivableObjectType`](#7-derivableobjecttype) | Implemented |
| [8. Rails Plugin](#8-rails-plugin) | Implemented |
| [9. ActiveRecord Adapter](#9-activerecord-adapter) | Implemented |
| [10. Testing Requirements](#10-testing-requirements) | Specified |
| [11. Open Questions (Deferred to Implementation)](#11-open-questions-deferred-to-implementation) | N/A |
| [12. Development Environment (Nix)](#12-development-environment-nix) | Implemented |
| [Appendix: Derivation Direction Rules](#appendix-derivation-direction-rules) | N/A |

---

## 1. Gem Identity

**Name:** `graphql-ruby-derivation`
**Ruby version:** >= 3.1
**License:** MIT

### 1.1 Require Paths

The gem is a single installable unit. Each layer is independently requireable:

| Require path | Loads |
|---|---|
| `graphql/derivation` | Core: Pick DSL, argument derivation engine, field derivation engine, `DerivableInputObject`, `DerivableObjectType` |
| `graphql/derivation/rails` | Rails plugin: `ControllerConcern`, `ArgumentSchema`. Requires `graphql/derivation`. |
| `graphql/derivation/rails/active_record` | ActiveRecord adapter. Requires `graphql/derivation/rails`. |

`require 'graphql-ruby-derivation'` is an alias for `require 'graphql/derivation'`.

### 1.2 Runtime Dependencies

| Dependency | Required by |
|---|---|
| `graphql` (~> 2.0) | Core |
| `activesupport` (~> 7.0) | Rails plugin |
| `actionpack` (~> 7.0) | Rails plugin |
| `activerecord` (~> 7.0) | ActiveRecord adapter |

Dependencies are declared as optional in the gemspec (`add_development_dependency` for rails and
activerecord in the core gemspec; consumed via `require` guards). The gem does not enforce that
Rails or ActiveRecord are loaded unless the corresponding require path is used.

### 1.3 File Structure

```
lib/
  graphql-ruby-derivation.rb               # alias: require 'graphql/derivation'
  graphql/
    derivation.rb
    derivation/
      version.rb
      errors.rb
      pick_dsl/
        arguments.rb                  # PickArguments — pick.required, pick.optional, pick.override
        fields.rb                     # PickFields — pick.fields, pick.override
      engines/
        argument_derivation.rb        # ArgumentDerivation engine
        field_derivation.rb           # FieldDerivation engine
      mappers/
        object_type_to_argument.rb    # ObjectType field → Argument type
        input_object_to_argument.rb   # InputObject arg → Argument type (identity map)
        object_type_to_field.rb       # ObjectType field → Field (handles resolver check)
      derivable_input_object.rb       # InputObject mixin
      derivable_object_type.rb        # ObjectType mixin
      rails/
        controller_concern.rb         # argument, arguments_from, arguments
        argument_schema.rb            # per-namespace ArgumentSchema
        adapters/
          active_record_mapper.rb     # AR column → GraphQL type
spec/
  support/
    fixture_schema/                   # test-only ObjectTypes, InputObjects, AR model stubs
  graphql/derivation/
    pick_dsl/
    derivation/
    mappers/
    derivable_input_object_spec.rb
    derivable_object_type_spec.rb
    rails/
      controller_concern_spec.rb
      adapters/
        active_record_mapper_spec.rb
graphql-ruby-derivation.gemspec
```

---

## 2. Error Types

All errors live under `GraphQL::Derivation`. All inherit from `GraphQL::Derivation::Error`.

```ruby
module GraphQL
  module Derivation
    Error                  = Class.new(StandardError)
    ConfigurationError     = Class.new(Error)   # programming errors; raised at class load time
    CyclicDependencyError  = Class.new(ConfigurationError)
    UnresolvableFieldError = Class.new(ConfigurationError)
    UnsupportedColumnTypeError = Class.new(Error)
  end
end
```

**ConfigurationError** is the catch-all for invalid declarations (unknown field selected, override
on unselected field, sibling cycle). Always raised at class load time — never at request time.

**CyclicDependencyError** is raised when sibling resolution detects a cycle. Message includes the
full cycle path (e.g. `create → update → create`).

**UnresolvableFieldError** is raised when field derivation encounters a field whose resolver
cannot be transferred to the destination type without an explicit override.

**UnsupportedColumnTypeError** is raised by the ActiveRecord adapter when a column type has no
GraphQL primitive mapping.

---

## 3. Pick DSL

The Pick DSL is the block interface used by both argument and field derivation. Two variants
exist: `PickArguments` (for deriving arguments onto InputObjects) and `PickFields` (for deriving
fields onto ObjectTypes). They share a common base that handles the override mechanism.

### 3.1 Evaluation Model

The block passed to `derive_from` or `arguments_from` is **stored unevaluated** at declaration
time. It is evaluated exactly once during resolution (see §4.4 and §5.4). This allows forward
references to sibling actions and to classes not yet defined at declaration time.

The block receives a single Pick object as its argument. The conventional name for this argument
is `pick`.

### 3.2 `PickArguments`

Used by `ArgumentDerivation`. Methods:

**`pick.required(*field_names)`**
Selects the named fields from the candidate set and marks them `required: true`. Raises
`ConfigurationError` at evaluation time if any name is not in the candidate set.

**`pick.optional(*field_names)`**
Selects the named fields and marks them `required: false`. Same validation.

**`pick.override(field_name, **opts)`**
Applies the given options to an already-selected field. `opts` may include any keyword accepted
by `GraphQL::Schema::Argument` except `required:` (use `pick.required` / `pick.optional` for
that). Raises `ConfigurationError` if `field_name` is not in the selected set.

Valid override opts: `description:`, `default_value:`, `prepare:`, `validates:`, `as:`,
`deprecation_reason:`, `input_type:` (used for nested ObjectType fields — see §4.2).

**Validation at evaluation time:**
- At least one field must be selected. An empty block raises `ConfigurationError`.
- A field may be passed to either `required` or `optional` but not both. Duplicate raises
  `ConfigurationError`.

### 3.3 `PickFields`

Used by `FieldDerivation`. Methods:

**`pick.fields(*field_names)`**
Selects the named fields from the candidate set. Raises `ConfigurationError` at evaluation time
if any name is not in the candidate set. May be called multiple times; selections accumulate.

**`pick.override(field_name, **opts)`**
Applies the given options to an already-selected field. Raises `ConfigurationError` if
`field_name` is not in the selected set.

Valid override opts: `description:`, `deprecation_reason:`, `null:`, `method:`, `resolver:`,
`name:` (emits the field under a different name on the destination type),
`camelize:` (default true, matches graphql-ruby default).

**Validation at evaluation time:**
- At least one field must be selected. An empty block raises `ConfigurationError`.

---

## 4. Argument Derivation Engine

**Class:** `GraphQL::Derivation::ArgumentDerivation`

Accepts a source and an unevaluated pick block. Returns an array of configured
`GraphQL::Schema::Argument` instances ready to be registered on an InputObject.

### 4.1 Source Types

Three source types are supported, distinguished by the type of the source argument:

| Source | Type check |
|---|---|
| ObjectType | `source < GraphQL::Schema::Object` |
| InputObject | `source < GraphQL::Schema::InputObject` |
| Sibling action | `source.is_a?(Symbol)` — resolved via the ControllerConcern registry |

Any other source raises `ArgumentError` immediately at declaration time.

### 4.2 Candidate Enumeration

**ObjectType source:**
`source.fields.values` — all fields on the ObjectType, including inherited fields.
Fields are excluded from the candidate set if:
- Their return type is a connection type (class name ends in `Connection`, or the type includes
  `GraphQL::Types::Relay::BaseConnection` in its ancestors).
- Their return type is a list of Object types (List<Object> — scalars and enums in lists are
  kept).

The resulting candidates are mapped to argument types using the table in §4.3.

**InputObject source:**
`source.arguments.values` — all arguments on the InputObject, including inherited arguments.
No exclusions. Type mapping is identity: the argument's type is reused directly.

**Sibling source:**
The sibling is resolved by looking up the action's registered argument set in the
ControllerConcern's class-level registry (see §8). Resolution is deferred; the sibling must be
defined in the same controller class or an ancestor by the time resolution runs.
The sibling's resolved `GraphQL::Schema::Argument` instances are the candidate set.
Type mapping is identity.

### 4.3 ObjectType Field → Argument Type Mapping

| ObjectType field return type | Argument type |
|---|---|
| `String` | `String` |
| `Integer` / `GraphQL::Types::Int` | `GraphQL::Types::Int` |
| `Float` | `Float` |
| `Boolean` / `GraphQL::Types::Boolean` | `GraphQL::Types::Boolean` |
| `ID` / `GraphQL::Types::ID` | `GraphQL::Types::ID` |
| Any custom scalar (`< GraphQL::Schema::Scalar`) | Same scalar class |
| Any enum (`< GraphQL::Schema::Enum`) | Same enum class |
| Any non-connection Object type | Not eligible by default. Eligible if `pick.override(name, input_type: SomeInputObjectClass)` is present — the argument type becomes the specified InputObject class. Raises `ConfigurationError` if selected without `input_type:`. |
| Connection type | Excluded from candidates entirely |
| List of scalar / enum | `[same_type]` with same nullability |
| List of Object type | Excluded from candidates entirely |

Nullability on the ObjectType field is **ignored** for argument type construction. All derived
arguments default to `required: false` unless the pick block calls `pick.required`.

### 4.4 Resolution Algorithm

```
def resolve(source, pick_block, context: nil)
  candidates = enumerate_candidates(source, context)
  pick = PickArguments.new(candidates.keys)
  pick_block.call(pick)
  pick.validate!  # raises ConfigurationError on violations

  pick.selections.map do |name, (required, overrides)|
    candidate = candidates[name]
    type = candidate.type  # already mapped in enumerate step
    opts = { required: required }.merge(overrides)
    build_argument(name, type, **opts)
  end
end
```

`build_argument` constructs a `GraphQL::Schema::Argument` instance without registering it. The
caller registers it on the target InputObject.

---

## 5. Field Derivation Engine

**Class:** `GraphQL::Derivation::FieldDerivation`

Accepts a source and an unevaluated pick block. Returns an array of configured
`GraphQL::Schema::Field` instances ready to be registered on an ObjectType.

### 5.1 Source Types

| Source | Type check |
|---|---|
| ObjectType | `source < GraphQL::Schema::Object` |
| ActiveRecord model | `source < ActiveRecord::Base` — requires `graphql/derivation/rails/active_record` |

Any other source raises `ArgumentError` at declaration time.

### 5.2 Candidate Enumeration

**ObjectType source:**
`source.fields.values` — all fields, including inherited. Connections are excluded from
candidates (same rule as §4.2).

**ActiveRecord source:**
`source.columns` — all columns reported by `ActiveRecord::Base.columns`. Virtual attributes,
`created_at`, `updated_at`, and `id` are included by default; the pick block controls what is
selected. Type mapping is performed by the ActiveRecord adapter (§9).

### 5.3 Resolver Handling (ObjectType source)

When copying a field from a source ObjectType, three cases arise:

**Case 1 — Default method resolver:** The field has no `resolver_method:` override and no
`resolver:` proc. graphql-ruby resolves it by calling a method of the same name on the
underlying object. The field definition is copied as-is. The destination ObjectType's underlying
object is assumed to respond to the same method. No action required.

**Case 2 — `method:` option:** The field specifies `method: :some_ruby_method`. The field is
copied with the same `method:` option. The destination ObjectType's underlying object must
respond to that method.

**Case 3 — Custom resolver method on source class:** The field resolves via a class method
defined on the source ObjectType class (e.g. `def self.resolve_field_name(obj, args, ctx)`).
This method lives on the source class and cannot be transparently transferred. The engine
raises `UnresolvableFieldError` at class load time unless the pick block provides an explicit
`method:` or `resolver:` override:

```ruby
pick.override :full_name, resolver: ->(obj, args, ctx) { obj.first_name + " " + obj.last_name }
# or
pick.override :full_name, method: :computed_full_name
```

The engine detects Case 3 by checking whether `source.method_defined?("resolve_#{field_name}")`.

### 5.4 Resolution Algorithm

```
def resolve(source, pick_block)
  candidates = enumerate_candidates(source)
  pick = PickFields.new(candidates.keys)
  pick_block.call(pick)
  pick.validate!

  pick.selections.map do |name, overrides|
    candidate = candidates[name]
    check_resolver!(source, candidate, name, overrides)  # raises UnresolvableFieldError if Case 3
    build_field(name, candidate.type, **merge_opts(candidate, overrides))
  end
end
```

---

## 6. `DerivableInputObject`

**Module:** `GraphQL::Derivation::DerivableInputObject`

A mixin for `GraphQL::Schema::InputObject` subclasses that adds `derive_from`.

### 6.1 Interface

```ruby
class CreateExpenseInput < GraphQL::Schema::InputObject
  include GraphQL::Derivation::DerivableInputObject

  derive_from ExpenseType do |pick|
    pick.required :title, :expense_date, :category
    pick.optional :description, :notes
    pick.override :description, prepare: :strip
  end

  argument :receipt_id, GraphQL::Types::ID, required: true
end
```

### 6.2 Behaviour

- `derive_from` may be called at most once per class. A second call raises `ConfigurationError`.
- The derivation is stored unevaluated. Resolution fires when the owning schema is first loaded
  (via `lazy_resolve_derivations!` — see §6.3).
- Resolved arguments are registered on the InputObject class via `argument` as if declared
  inline. They appear in introspection like any other argument.
- Inline `argument` declarations may coexist with `derive_from`. If an inline `argument` names
  a field also present in the derivation, `ConfigurationError` is raised at resolution time.
- If the `derive_from` source is itself Derivable (another `DerivableInputObject` or
  `DerivableObjectType` class with a pending derivation), its own derivation is resolved first,
  recursively, before this class's arguments are derived from it. Resolution is therefore order
  -independent: it does not matter which class happens to be included, declared, or resolved
  first. A cycle anywhere in the `derive_from` graph (including one that crosses both mixins)
  raises `CyclicDependencyError` with the full cycle path, instead of silently resolving against
  a partially-resolved or empty source.

### 6.3 Resolution Trigger

`GraphQL::Derivation::DerivableInputObject.resolve_all!` iterates all classes that include the mixin
and resolves any pending derivations. Callers:
- The Rails plugin calls this during `ArgumentSchema` initialisation (see §8.2).
- Outside Rails, the schema author calls it explicitly, typically in a schema initialiser or
  test helper.

**Rails dev-environment note:** in a Rails app with class reloading enabled (dev/test --
`config.cache_classes = false` / `config.reloading = true`), do NOT call `resolve_all!` (or
anything else that populates state from `DerivableInputObject`-including classes) from a
one-shot initializer. Initializers run once at boot, before any reload cycle, so a class
redefined by a later reload would never have its derivation re-resolved. Instead wire it into
`Rails.application.reloader.to_prepare { GraphQL::Derivation::DerivableInputObject.resolve_all! }`
-- `to_prepare` blocks re-run after every reload AND once at boot, so this stays correct across
the whole dev/test session. In production, where nothing reloads, a one-shot initializer-style
call remains fine. See §8.2/§8.1 for the accompanying reload-safety utility
(`GraphQL::Derivation::Rails.reset_for_reload!`) that should run on the unload side of the same
reload cycle, and §8.1's `eager_load_argument_sources!` for the separate CI-time validation
story this does not replace.

---

## 7. `DerivableObjectType`

**Module:** `GraphQL::Derivation::DerivableObjectType`

A mixin for `GraphQL::Schema::Object` subclasses that adds `derive_from`.

### 7.1 Interface

```ruby
class TeamMemberExpenseType < GraphQL::Schema::Object
  include GraphQL::Derivation::DerivableObjectType

  derive_from ExpenseType do |pick|
    pick.fields :title, :description, :amount_cents
    pick.override :amount_cents, name: :amount, description: "Amount in cents"
  end

  field :team_member_notes, String, null: true
end
```

```ruby
# ActiveRecord source — requires graphql/derivation/rails/active_record
class ExpenseType < GraphQL::Schema::Object
  include GraphQL::Derivation::DerivableObjectType

  derive_from Expense do |pick|      # Expense < ActiveRecord::Base
    pick.fields :title, :description, :amount_cents, :currency_code, :category
    pick.override :category, description: "Expense category"
  end
end
```

### 7.2 Behaviour

- `derive_from` may be called at most once per class. A second call raises `ConfigurationError`.
- The derivation is stored unevaluated. Resolution fires when the owning schema is first loaded
  (via `lazy_resolve_derivations!`).
- Resolved fields are registered on the ObjectType class via `field` as if declared inline.
- Inline `field` declarations may coexist with `derive_from`. If an inline `field` names a
  field also produced by the derivation, `ConfigurationError` is raised at resolution time.
- Same recursive-resolution and cycle-detection guarantee as §6.2: if the `derive_from` source is
  itself Derivable, its own pending derivation resolves first, resolution order does not matter,
  and any cycle (including one crossing both `DerivableInputObject` and `DerivableObjectType`)
  raises `CyclicDependencyError` with the full cycle path.

### 7.3 Resolution Trigger

`GraphQL::Derivation::DerivableObjectType.resolve_all!` — same pattern as §6.3. Called during schema
load or explicitly by the schema author.

**Rails dev-environment note:** same guidance as §6.3 -- in dev/test with class reloading
enabled, drive this from `Rails.application.reloader.to_prepare { ... }`, not a one-shot
initializer, so re-resolution happens after every reload as well as at boot. In production
(no reloading), a one-shot initializer-style call is fine.

---

## 8. Rails Plugin

**Require:** `graphql/derivation/rails`

### 8.1 `ControllerConcern`

**Module:** `GraphQL::Derivation::Rails::ControllerConcern`

Extend a Rails controller base class:

```ruby
class ApplicationController < ActionController::Base
  include GraphQL::Derivation::Rails::ControllerConcern
end
```

#### Class-level DSL

**`argument(name, type, **opts)`**
Declares a single inline argument. Buffered against the next defined action via `method_added`.
Accepts any keyword that `GraphQL::Schema::Argument` accepts, except `loads:`.

**`arguments_from(source, &block)`**
Declares a composable source. `source` is an ObjectType class, InputObject class, or Symbol
(sibling action name). `block` receives a `PickArguments` object. Buffered against the next
defined action via `method_added`.

At most one `arguments_from` call is permitted per action. A second call on the same action
raises `ConfigurationError`.

**`method_added` hook**
When a new instance method is defined on the controller class, the pending buffer (accumulated
`argument` declarations and at most one `arguments_from`) is flushed:
- An anonymous `GraphQL::Schema::InputObject` subclass is built from the declarations.
- The InputObject is registered on the namespace's `ArgumentSchema` (see §8.2) as an orphan
  type, named after the controller and action (e.g. `TeamMembersTimeOffsCreateInput`).
- The controller action is associated with this InputObject in the class-level action registry.
- The buffer is cleared.

If the buffer is empty when a method is defined, no InputObject is created and the action is
not registered. Calling `arguments` from an unregistered action raises `MissingInputTypeError`.

#### Instance method

**`arguments`**
Available in any controller action. Returns a `Hash` of coerced Ruby keyword arguments keyed
by snake_case symbol. Memoized per request.

Resolution: on first call, the registered InputObject for the action is resolved (triggering
lazy derivation if not yet resolved), then `coerce_input` is called via the namespace's
`ArgumentSchema` context. The result is cached in an instance variable.

Raises:
- `GraphQL::Derivation::Rails::MissingInputTypeError` (subclass of `ConfigurationError`) if no
  `argument` or `arguments_from` was declared for this action.
- `GraphQL::Derivation::Rails::ArgumentParsingError` if coercion fails (required argument absent,
  type mismatch, enum value unrecognised). This is a hard error — no rescue inside the concern.

#### `eager_load_argument_sources!`

Class method available on any controller that includes the concern. Triggers full resolution of
all composable sources registered on the class and its ancestors. Detects cycles using a
depth-first stack algorithm. Raises `CyclicDependencyError` at the first cycle detected.

Must be called in CI (e.g. in a dedicated spec) to guarantee cycle errors are caught before
merge.

**This CI role is separate from, and not replaced by, Rails dev-environment reload safety**
(see §8.2's `reset_for_reload!`): `eager_load_argument_sources!` is a validation entry point you
run deliberately, in CI, to catch `ConfigurationError`/`CyclicDependencyError` before merge --
it is not part of normal request-serving or reload behaviour, and reload-safety fixes do not
change when or how it should be invoked.

#### Collision rule

If a standalone `argument` declaration names a field already produced by `arguments_from` on
the same action, `ConfigurationError` is raised at resolution time. All customisation happens
inside the `arguments_from` block.

### 8.2 `ArgumentSchema`

**Class:** `GraphQL::Derivation::Rails::ArgumentSchema`

A minimal `GraphQL::Schema` subclass per namespace. No query root. No application types
pre-registered. Uses `NullWarden` (all types visible).

One instance is created per namespace and cached for the process lifetime. The namespace is
an identifier (string or symbol) supplied by the controller concern configuration.

```ruby
class TeamMembers::ApplicationController < ApplicationController
  argument_namespace :team_members
end
```

If no namespace is configured, the default namespace `:default` is used.

Responsibilities:
- Provides the `GraphQL::Query::Context` factory used by `coerce_input`.
- Holds all anonymous InputObjects generated by the controller concern as orphan types,
  making them introspectable for TypeScript codegen without polluting the application schema.

`ArgumentSchema.for(namespace)` returns or creates the schema for that namespace.

#### Rails dev-environment reload safety

`ArgumentSchema` is cached for the process lifetime, and `ControllerConcern#build_input_object`
generates a fresh anonymous InputObject class (with a stable, reload-independent `graphql_name`)
every time the controller class body re-executes. Under Rails class reloading (dev/test),
`register_input_object` therefore de-duplicates by `graphql_name`, not object identity: a
reload-driven re-registration REPLACES the previously-registered InputObject for that name in
place, rather than accumulating a second type with the same name (which would otherwise raise
`GraphQL::Schema::DuplicateNamesError` on the next `to_definition`/introspection/validation
call). Registering the exact same class object twice remains a safe no-op, as before.

This still leaves other reload-time state (see Finding 1 below) reachable longer than it needs
to be, so a companion reset utility is provided:

**`GraphQL::Derivation::Rails.reset_for_reload!`**
Clears `DerivableInputObject.included_classes`, `DerivableObjectType.included_classes`, all
cached per-namespace `ArgumentSchema`s (`ArgumentSchema.reset!`), and (if the ActiveRecord
adapter is loaded) `ActiveRecordMapper.enum_cache`. Not auto-wired into anything -- call it
explicitly, in a Rails app with class reloading enabled, from:

```ruby
Rails.application.reloader.before_class_unload do
  GraphQL::Derivation::Rails.reset_for_reload!
end
```

`before_class_unload` runs immediately before Zeitwerk unloads the old autoloaded constants,
so this clears the gem's registries before the classes they reference become stale, and pairs
with the `to_prepare`-driven re-resolution described in §6.3/§7.3 to give a clean
unload-then-rebuild cycle on every reload. In production (no reloading), this never needs to run.

---

## 9. ActiveRecord Adapter

**Require:** `graphql/derivation/rails/active_record`

**Class:** `GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper`

Maps ActiveRecord column definitions to GraphQL field definitions. Used by `FieldDerivation`
when the source is an ActiveRecord model class.

### 9.1 Column Type Mapping

| AR column type (`:type` symbol) | GraphQL type |
|---|---|
| `:string`, `:text`, `:citext` | `String` |
| `:integer`, `:bigint` | `GraphQL::Types::Int` |
| `:float`, `:decimal`, `:numeric` | `Float` |
| `:boolean` | `GraphQL::Types::Boolean` |
| `:date` | `GraphQL::Types::ISO8601Date` |
| `:datetime`, `:timestamp`, `:timestamptz` | `GraphQL::Types::ISO8601DateTime` |
| `:uuid` | `GraphQL::Types::ID` |
| `:enum` | GraphQL enum class (see §9.2) |
| `:jsonb`, `:json`, `:hstore` | raises `UnsupportedColumnTypeError` |
| `:array` | `[element_type]` if element type is mappable; raises `UnsupportedColumnTypeError` otherwise |
| All other types | raises `UnsupportedColumnTypeError` |

All mapped fields are generated with `null: true` by default. The pick block's `pick.override`
can set `null: false` explicitly.

### 9.2 Rails Enum Handling

When a column's type is `:enum` (PostgreSQL native enum) or when the column name matches a key
in `Model.defined_enums` (Rails enum):

1. The enum values are retrieved: `Model.defined_enums[column_name].keys`.
2. A `GraphQL::Schema::Enum` subclass is generated dynamically with those values, upcased and
   underscored (e.g. `food` → `FOOD`, `paid_time_off` → `PAID_TIME_OFF`).
3. The generated class is named `"#{model_name}#{column_name.camelize}Enum"` and cached
   (memoized on the mapper; not registered on the application schema).
4. The field uses this generated enum class as its type.

If the enum values cannot be determined at class load time, `UnsupportedColumnTypeError` is
raised.

**Rails dev-environment reload safety:** the memoization cache is keyed by `[model.name,
column_name]` (a String key), not by the `model` class object itself, and additionally records
which `model` class object produced each cached enum. Under Rails class reloading, a reloaded AR
model is a new class object with the same `.name`; a plain identity-keyed or naively
string-keyed-with-`||=` cache would either leak an unreachable stale entry per reload or keep
serving an enum built from the old, pre-reload model class. Instead, a cache hit is only reused
when the cached entry's model is `equal?` to the current `model`; otherwise the slot is rebuilt
and replaced. `GraphQL::Derivation::Rails.reset_for_reload!` (see §8.2) also clears this cache
entirely as a coarser reset, for use alongside `before_class_unload`.

### 9.3 Null Handling

All AR-derived fields default to `null: true`. Columns with a NOT NULL database constraint
(`column.null == false`) default to `null: false`. The pick block may override either
direction with `pick.override(:field_name, null: true/false)`.

### 9.4 Excluded Columns by Default

The following columns are excluded from the candidate set and cannot be selected:
- `id` — primary key; use an explicit `field :id` if needed
- `created_at`, `updated_at` — timestamps; include explicitly if needed

All other columns, including foreign key columns (`*_id`), are candidates. Foreign key columns
map to `GraphQL::Types::ID`.

---

## 10. Testing Requirements

### 10.1 Framework

RSpec. No Rails application required in the test suite. Fixture classes live in
`spec/support/fixture_schema/`.

### 10.2 Fixture Schema

A small set of test-only GraphQL types in `spec/support/fixture_schema/`:

```
fixture_schema/
  types/
    expense_type.rb        # ObjectType with scalar, enum, nested, and connection fields
    expense_status_enum.rb
    address_type.rb        # nested Object type (for testing non-eligible field handling)
    expense_connection.rb  # connection type (for testing exclusion)
  inputs/
    expense_base_input.rb  # InputObject for InputObject-source tests
  ar_stubs/
    expense.rb             # AR model stub (not connected to a DB; stubs .columns)
```

The fixture schema is not wired into a real `GraphQL::Schema` subclass — the engines and
mappers are tested directly with the fixture classes as inputs.

### 10.3 Unit Test Requirements

Each of the following must have isolated unit tests:

- `PickArguments`: selection accumulation, validation (empty block, duplicate field, override
  on unselected field, unknown field name)
- `PickFields`: same validations
- `ObjectTypeToArgument` mapper: each row in the type mapping table; connection exclusion;
  nested Object type without `input_type:` override; nested Object with `input_type:` override
- `InputObjectToArgument` mapper: identity mapping, required/optional propagation
- `ObjectTypeToField` mapper: Case 1, Case 2, Case 3 resolver detection and error
- `ActiveRecordMapper`: each column type; enum generation; null inference; excluded columns
- `ArgumentDerivation`: full resolution with each source type; collision detection; empty
  selection error
- `FieldDerivation`: full resolution with each source type

### 10.4 Integration Test Requirements

- `DerivableInputObject`: verify derived arguments appear in introspection; verify collision
  with inline argument raises
- `DerivableObjectType`: verify derived fields appear; verify resolver handling end-to-end
- `ControllerConcern`: stub ActionController::Base; verify `arguments` returns coerced hash;
  verify `MissingInputTypeError`; verify `ArgumentParsingError`; verify `eager_load!` cycle
  detection
- `ArgumentSchema`: verify one instance per namespace; verify orphan type registration

### 10.5 No DB Required

The ActiveRecord mapper tests stub `Model.columns` and `Model.defined_enums` directly.
No database connection is opened in the test suite.

---

## 11. Open Questions (Deferred to Implementation)

These are genuinely unresolved and require implementation exploration before closing.

### 11.1 Sibling Source Scope in `DerivableInputObject`

The sibling source type (Symbol) is defined within the ControllerConcern context, where the
"sibling" is another controller action. In `DerivableInputObject` context, sibling references
do not have a natural equivalent — there is no action registry. Decision for the implementer:
**disallow Symbol sources in `DerivableInputObject.derive_from`** and raise `ArgumentError`
immediately.

### 11.2 `ArgumentSchema` TypeScript Codegen Interface

The spec states that anonymous InputObjects are registered as orphan types on the
`ArgumentSchema`. The codegen plugin that emits TypeScript types from these is out of scope for
this gem — it lives in the npm package. This gem's responsibility is only registration. The
codegen plugin consumes the schema's `types` list.

### 11.3 `NullWarden` Compatibility for `validates: required:`

The `one_of:` variant of `validates: required:` calls `context.types.arguments(owner)` to
enumerate visible keywords. Confirm `NullWarden` delegates this correctly for InputObject-owned
arguments before marking the feature supported. If it does not, document the limitation and
exclude `validates: { required: { one_of: [...] } }` from supported overrides.

### 11.4 Field Derivation and Inherited Resolver Methods

The resolver detection in §5.3 checks `source.method_defined?("resolve_#{field_name}")`.
However, graphql-ruby also supports the `resolver_method:` field option (a symbol pointing to
an instance method on the underlying object, not on the type class). Confirm whether this is
correctly handled by Case 1 (method on object) or requires a Case 4.

---

## 12. Development Environment (Nix)

Development dependencies (Ruby interpreter, native libraries needed for C-extension gems, git
hook runner) are provisioned via Nix, not via system Ruby/rbenv/rvm/asdf. Goal: identical,
reproducible dev shell for every contributor and for CI, with no manual interpreter management.

### 12.1 Toolchain Shape

- **`flake.nix`** at repo root defines a single `devShells.default` output. `flake.lock` is
  committed and is the pin — no floating nixpkgs refs.
- **direnv** picks the shell up automatically. `.envrc` contains `use flake`. Contributors run
  `direnv allow` once after clone.
- No `shell.nix`/niv. This repo's dependency surface is small enough that flakes' lockfile alone
  is sufficient; no need for the niv-based pinning anywhere's `anywhere` repo uses.

### 12.2 Ruby Version

Pinned to **Ruby 3.4** (nixpkgs `ruby_3_4`), matching Oyster's `anywhere` repo. This diverges from
the gemspec's `required_ruby_version >= 3.1` floor (§1.1) for a practical reason: nixpkgs-unstable
has removed `ruby_3_1` and `ruby_3_2` (upstream EOL — see nixpkgs `aliases.nix`), so the original
"dev shell pins to the compatibility floor" intent isn't achievable without pinning to a stale,
unmaintained nixpkgs snapshot. `ruby_3_3` is the oldest version nixpkgs-unstable still carries;
`3.4` is chosen over `3.3` for parity with Oyster's other repos. The gemspec floor (3.1) remains
the documented minimum supported version — verifying that floor, if ever needed, is a CI matrix
concern (`ruby/setup-ruby` in a separate non-Nix CI job), not a dev-shell concern.

### 12.3 Shell Contents

The `devShells.default` derivation provides, at minimum:

| Package | Purpose |
|---|---|
| `ruby_3_4` | Interpreter |
| `bundler` | Dependency management (or use the bundler bundled with the nixpkgs ruby derivation if present) |
| `libyaml` | Native dep for Ruby's YAML/Psych |
| `openssl` | Native dep for any TLS-touching transitive gem |
| `libxml2`, `libxslt` | Native deps for Nokogiri, pulled in transitively by `activesupport`/`actionpack` |
| `zlib` | Native dep for common C-extension gems |
| `pkg-config` | Build-time discovery of the above libraries |
| `lefthook` | Git hook runner — installs the `pre-commit` hook that runs `rubocop` and `rspec` (see §12.5) |
| `git` | Explicit pin so hook scripts don't depend on system git |

No Node, Postgres, Redis, or other service dependencies — none are required per SPEC.md's
dependency table (§1.2) or testing requirements (§10.5: no DB in the test suite).

### 12.4 Shell Hook (Bundler Isolation)

On shell entry, the flake's `shellHook`:
- Runs `bundle config set --local path 'vendor/bundle'` so installed gems are vendored
  per-repo-checkout rather than into a shared system/user gem path.
- Does **not** auto-run `bundle install` — entering the shell should be fast and side-effect-free
  beyond env setup. `bundle install` remains an explicit, separate step (documented in the
  project README once scaffolded).
- Installs lefthook git hooks (`lefthook install`), idempotently, swallowing errors if `.git` is
  absent (e.g. when the flake is evaluated outside a git checkout, such as in some CI cache-warm
  scenarios).

### 12.5 Git Hooks (lefthook)

A `lefthook.yml` at repo root defines a `pre-commit` group running `rubocop` (changed files only)
and a `pre-push` group running the full `bundle exec rspec` suite. These mirror, but do not
replace, the CI gate (§ AGENTS.md "Required before calling work done") — CI remains the
authoritative check; hooks are a fast local pre-flight.

### 12.6 CI Integration

GitHub Actions CI (already decided: runs `bundle exec rspec` + `bundle exec rubocop`) provisions
its environment via Nix rather than `ruby/setup-ruby`, so CI and local dev share the exact same
toolchain definition:

- A Nix-installer action (e.g. `cachix/install-nix-action` or equivalent) sets up Nix on the
  runner.
- The job runs subsequent steps inside the flake's dev shell, e.g. via
  `nix develop --command bash -c '...'`, rather than installing Ruby directly.
- A Nix binary cache step (e.g. Cachix or GitHub Actions cache keyed on `flake.lock`) is expected
  to keep CI runtime reasonable — first-run cold-cache time is acceptable, steady-state should be
  fast. Exact caching backend is an implementation detail, not specified further here.
- `bundle install` still runs as an explicit CI step (same as local dev — the shell does not
  auto-install gems), using the vendored `vendor/bundle` path so repeated runs can be cached by
  `actions/cache` keyed on `Gemfile.lock`.

### 12.7 What's Explicitly Out of Scope Here

- Editor/IDE integration (e.g. `.tool-versions`, rbenv shims) — not provided; Nix shell is the
  only supported path, consistent with "no manual interpreter management" goal above.
- Cross-platform (non-Linux/macOS) support — not addressed; nixpkgs' standard Linux/Darwin
  coverage is assumed sufficient.
- Release/publish tooling (`gem push` credentials, trusted publishing) — unrelated to the dev
  shell, deferred to a future spec section if/when this gem is published.

---

## Appendix: Derivation Direction Rules

```
ActiveRecord model        →  ObjectType fields     ✓  (via FieldDerivation + AR adapter)
ActiveRecord model        →  InputObject args      ✗  not supported (no direct path; derive
                                                       via ObjectType if needed)
ObjectType fields         →  InputObject args      ✓  (primary use case)
ObjectType fields         →  ObjectType fields     ✓  (field copying)
InputObject args          →  InputObject args      ✓  (cross-input sharing)
InputObject args          →  ObjectType fields     ✗  forbidden; raises ArgumentError
Symbol (sibling action)   →  InputObject args      ✓  (ControllerConcern only)
Symbol (sibling action)   →  ObjectType fields     ✗  not applicable
```
