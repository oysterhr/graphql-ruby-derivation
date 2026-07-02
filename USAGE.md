# Usage

A getting-started guide with runnable examples. For full behavior/edge cases, see
[`docs/SPEC.md`](docs/SPEC.md) — this document is a friendlier front door onto it, not a
replacement for it.

## The problem

GraphQL mutations and types tend to duplicate fields that already exist elsewhere in the schema:
a `CreateExpenseInput` re-declares half of `ExpenseType`'s fields, a `TeamMemberExpenseType`
re-declares half of `ExpenseType` again, and a Rails controller re-declares the input's fields a
third time as inline `argument`s. Every duplication is a place the three can silently drift.

This gem lets you declare those relationships once — "this InputObject's arguments are a subset
of that ObjectType's fields" — and derives the actual `GraphQL::Schema::Argument`/`Field`
definitions from the source, instead of hand-copying them.

## Example 1 — derive InputObject arguments from an ObjectType

```ruby
require 'graphql/derivation'

class CreateExpenseInput < GraphQL::Schema::InputObject
  include GraphQL::Derivation::DerivableInputObject

  derive_from ExpenseType do |pick|
    pick.required :title, :expense_date, :category
    pick.optional :description
    pick.override :description, prepare: :strip
  end

  argument :receipt_id, GraphQL::Types::ID, required: true
end

GraphQL::Derivation::DerivableInputObject.resolve_all! # triggers derivation (see "Resolution timing" below)
```

`CreateExpenseInput` now has `title`/`expense_date`/`category` (required), `description`
(optional, with `prepare: :strip`), and `receipt_id` (declared inline, coexists fine) —
all sourced from `ExpenseType`'s existing field definitions.

`derive_from`'s source can just as well be a **Mutation class** with arguments declared
directly on it (the common graphql-ruby style, no separate InputObject):

```ruby
class UpdateExpenseInput < GraphQL::Schema::InputObject
  include GraphQL::Derivation::DerivableInputObject

  derive_from Mutations::CreateExpense do |pick| # < GraphQL::Schema::Mutation
    pick.required :title
    pick.optional :category
  end
end
```

This works transparently — a Mutation class exposes its arguments the same way an InputObject
does, so it is derived from identically, with no separate API to learn. The same applies to the
Rails `arguments_from` DSL (Example 4 below): pass a Mutation class wherever an InputObject class
is accepted.

## Example 2 — derive ObjectType fields from another ObjectType

```ruby
class TeamMemberExpenseType < GraphQL::Schema::Object
  include GraphQL::Derivation::DerivableObjectType

  derive_from ExpenseType do |pick|
    pick.fields :title, :description, :amount_cents
    pick.override :amount_cents, name: :amount, description: 'Amount in cents'
  end

  field :team_member_notes, String, null: true
end

GraphQL::Derivation::DerivableObjectType.resolve_all!
```

## Example 3 — derive ObjectType fields from an ActiveRecord model

```ruby
require 'graphql/derivation/rails/active_record'

class ExpenseType < GraphQL::Schema::Object
  include GraphQL::Derivation::DerivableObjectType

  derive_from Expense do |pick|              # Expense < ActiveRecord::Base
    pick.fields :title, :amount_cents, :category   # category is a Rails enum column
    pick.override :category, description: 'Expense category'
  end
end
```

Column types map to GraphQL types automatically (strings, numerics, dates, enums, foreign keys
→ `ID`, etc.) — see the type table in `docs/SPEC.md` §9.1 for every case.

## Example 4 — Rails controller arguments

```ruby
require 'graphql/derivation/rails'

class ApplicationController < ActionController::Base
  include GraphQL::Derivation::Rails::ControllerConcern
end

class ExpensesController < ApplicationController
  arguments_from CreateExpenseInput do |pick|
    pick.required :title, :amount_cents
    pick.optional :description
  end

  def create
    arguments # => { title: "Lunch", amount_cents: 1200, description: nil }
    # ... use the coerced hash
  end
end
```

Call `ExpensesController.eager_load_argument_sources!` in a CI spec so cycles/typos in
`arguments_from` sources fail the build instead of a live request.

By default, arguments are read flat, at the top level of the request body. For a Rails-idiomatic
nested shape instead — `{ expense: { title: ..., amountCents: ... } }`, matching `form_for`/
strong-parameters conventions — wrap the relevant declarations in `resource_arguments`:

```ruby
class ExpensesController < ApplicationController
  argument :page, GraphQL::Types::Int, required: false   # stays flat: params['page']

  resource_arguments :expense do                          # nested: params['expense']
    arguments_from CreateExpenseInput do |pick|
      pick.required :title, :amount_cents
      pick.optional :description
    end
  end

  def create
    arguments        # => { page: 2, expense: { title: "Lunch", amount_cents: 1200, description: nil } }
    expense_params    # => { title: "Lunch", amount_cents: 1200, description: nil } -- shorthand for arguments[:expense]
  end
end
```

`resource_arguments` also defines a private `"#{key}_params"` helper (`expense_params` above),
for the familiar Rails call site. `required:` defaults to `true` (pass `required: false` if the
whole nested key is optional) and flat/nested declarations may be freely mixed on one action;
`resource_arguments` blocks may not be nested inside one another.

## Resolution timing

`derive_from`/`arguments_from` blocks are stored **unevaluated** at declaration time and only
evaluated once, on resolution. Outside Rails, call `resolve_all!` yourself (schema
initializer or test helper). Inside Rails, the plugin resolves lazily on first use, but if your
app reloads classes in dev/test, wire re-resolution and cache-clearing through the Rails
reloader — see `docs/SPEC.md` §6.3/§7.3/§8.2 for the exact hooks
(`Rails.application.reloader.to_prepare` / `before_class_unload` +
`GraphQL::Derivation::Rails.reset_for_reload!`).

## Pick DSL cheat sheet

| Method | Used by | Does |
|---|---|---|
| `pick.required(*names)` | `PickArguments` | select fields, mark `required: true` |
| `pick.optional(*names)` | `PickArguments` | select fields, mark `required: false` |
| `pick.fields(*names)` | `PickFields` | select fields (no required/optional distinction) |
| `pick.override(name, **opts)` | both | tweak an already-selected field/argument |

`pick.override` opts differ by type:

- **`PickArguments`**: `description:`, `default_value:`, `prepare:`, `validates:`, `as:`,
  `deprecation_reason:`, `input_type:` (required when selecting a non-connection Object-type
  field — see SPEC §4.3).
- **`PickFields`**: `description:`, `deprecation_reason:`, `null:`, `method:`, `resolver:`,
  `name:`, `camelize:`.

Passing an option outside these lists raises `ConfigurationError` immediately, with a
"did you mean" suggestion for likely typos.

## Error glossary

| Error | Raised when |
|---|---|
| `GraphQL::Derivation::ConfigurationError` | Any invalid declaration: unknown field, unselected-field override, empty pick block, double `derive_from`, inline/derived name collision, unknown override key. Always at load/resolution time, never mid-request. |
| `GraphQL::Derivation::CyclicDependencyError` | A `derive_from` chain cycles back on itself, e.g. `A → B → A` (message includes the full path). Also raised by `eager_load_argument_sources!` for sibling-action cycles. |
| `GraphQL::Derivation::UnresolvableFieldError` | A field resolves via a custom class-method resolver (Case 3, SPEC §5.3) and was selected without an explicit `method:`/`resolver:` override. |
| `GraphQL::Derivation::UnsupportedColumnTypeError` | An ActiveRecord column type has no GraphQL mapping (e.g. `:jsonb`, unmappable `:array` element type). |
| `GraphQL::Derivation::Rails::MissingInputTypeError` | `arguments` called from a controller action that never declared `argument`/`arguments_from`. |
| `GraphQL::Derivation::Rails::ArgumentParsingError` | Request-time coercion failure (missing required arg, bad type, bad enum value) — the one error in this list that is **not** a `ConfigurationError`. |

## Where to go next

- Full behavior, every edge case, and the exact resolution algorithms: [`docs/SPEC.md`](docs/SPEC.md).
- Agent-oriented compressed reference: [`USAGE.CAVEKIT.md`](USAGE.CAVEKIT.md).
