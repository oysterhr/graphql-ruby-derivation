# Usage

Getting-started guide, runnable examples. Full behavior/edge cases: see
[`docs/SPEC.md`](docs/SPEC.md) — this doc friendlier front door onto it, not replacement.

## The problem

GraphQL mutations/types duplicate fields that exist elsewhere in schema:
`CreateExpenseInput` re-declares half `ExpenseType`'s fields, `TeamMemberExpenseType`
re-declares half `ExpenseType` again, Rails controller re-declares input's fields
third time as inline `argument`s. Each duplication = place three can silently drift.

Gem lets you declare relationship once — "this InputObject's arguments subset
of that ObjectType's fields" — derives actual `GraphQL::Schema::Argument`/`Field`
definitions from source, instead hand-copying.

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
```

`CreateExpenseInput` now has `title`/`expense_date`/`category` (required), `description`
(optional, `prepare: :strip`), `receipt_id` (declared inline, coexists fine) —
all sourced from `ExpenseType`'s existing field definitions.

`derive_from`'s source can also be **Mutation class** with arguments declared
directly on it (common graphql-ruby style, no separate InputObject):

```ruby
class UpdateExpenseInput < GraphQL::Schema::InputObject
  include GraphQL::Derivation::DerivableInputObject

  derive_from Mutations::CreateExpense do |pick| # < GraphQL::Schema::Mutation
    pick.required :title
    pick.optional :category
  end
end
```

Works transparently — Mutation class exposes arguments same way InputObject
does, so derives identically, no separate API to learn. Same applies to Rails
`arguments_from` DSL (Example 4 below): pass Mutation class wherever InputObject
class accepted.

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

Column types map to GraphQL types auto (strings, numerics, dates, enums, foreign keys
→ `ID`, etc.) — see type table in `docs/SPEC.md` §9.1 for every case.

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

Call `ExpensesController.eager_load_argument_sources!` in CI spec so cycles/typos in
`arguments_from` sources fail build instead of live request.

Default: arguments read flat, top level of request body. For Rails-idiomatic
nested shape instead — `{ expense: { title: ..., amountCents: ... } }`, matching `form_for`/
strong-parameters conventions — wrap relevant declarations in `resource_arguments`:

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

`resource_arguments` also defines private `"#{key}_params"` helper (`expense_params` above),
for familiar Rails call site. `required:` defaults `true` (pass `required: false` if
whole nested key optional); flat/nested declarations freely mixed on one action;
`resource_arguments` blocks can't nest inside one another.

## Resolution timing

`derive_from`/`arguments_from` blocks stored **unevaluated** at declaration time,
evaluated once, **on first use**: first time graphql-ruby reads class's arguments or
fields (schema build, SDL dump, introspection, validation, execution — under both legacy
`Warden` and `GraphQL::Schema::Visibility`). Nothing needs calling for derived members
to appear; declaring inline `argument`/`field` members never triggers resolution, so
order of declarations in class body doesn't matter. Resolution serialized behind one
process-wide lock, so first read on request thread safe.

`GraphQL::Derivation::DerivableInputObject.resolve_all!` and
`GraphQL::Derivation::DerivableObjectType.resolve_all!` optional eager warm-ups: call
from schema initializer, Rails `to_prepare` block, or test helper when you want
misconfiguration (collision, cycle) to fail at boot or CI instead of first request
touching class. Failed resolution not remembered as done — next read runs it
again, raises again — so misconfigured class stays loud, not quietly serving only
inline members.

If app reloads classes in dev/test, wire cache-clearing through Rails reloader — see
`docs/SPEC.md` §6.3/§7.3/§8.2 for exact hooks (`Rails.application.reloader.before_class_unload`
+ `GraphQL::Derivation::Rails.reset_for_reload!`).

## Pick DSL cheat sheet

| Method | Used by | Does |
|---|---|---|
| `pick.required(*names)` | `PickArguments` | select fields, mark `required: true` |
| `pick.optional(*names)` | `PickArguments` | select fields, mark `required: false` |
| `pick.fields(*names)` | `PickFields` | select fields (no required/optional distinction) |
| `pick.override(name, **opts)` | both | tweak already-selected field/argument |

`pick.override` opts differ by type:

- **`PickArguments`**: `description:`, `default_value:`, `prepare:`, `validates:`, `as:`,
  `deprecation_reason:`, `input_type:` (required when selecting non-connection Object-type
  field — see SPEC §4.3).
- **`PickFields`**: `description:`, `deprecation_reason:`, `null:`, `method:`, `resolver:`,
  `name:`, `camelize:`.

Option outside these lists → raises `ConfigurationError` immediately, with
"did you mean" suggestion for likely typos.

## Error glossary

| Error | Raised when |
|---|---|
| `GraphQL::Derivation::ConfigurationError` | Any invalid declaration: unknown field, unselected-field override, empty pick block, double `derive_from`, inline/derived name collision, unknown override key. Always at load/resolution time, never mid-request. |
| `GraphQL::Derivation::CyclicDependencyError` | A `derive_from` chain cycles back on itself, e.g. `A → B → A` (message includes full path). Also raised by `eager_load_argument_sources!` for sibling-action cycles. |
| `GraphQL::Derivation::UnresolvableFieldError` | Field resolves via custom class-method resolver (Case 3, SPEC §5.3), selected without explicit `method:`/`resolver:` override. |
| `GraphQL::Derivation::UnsupportedColumnTypeError` | ActiveRecord column type has no GraphQL mapping (e.g. `:jsonb`, unmappable `:array` element type). |
| `GraphQL::Derivation::Rails::MissingInputTypeError` | `arguments` called from controller action that never declared `argument`/`arguments_from`. |
| `GraphQL::Derivation::Rails::ArgumentCoercionError` | Request-time coercion failure (missing required arg, bad type, bad enum value) — only error in list that's **not** `ConfigurationError`. |

## Where to go next

- Full behavior, every edge case, exact resolution algorithms: [`docs/SPEC.md`](docs/SPEC.md).
- Agent-oriented compressed reference: [`USAGE.CAVEKIT.md`](USAGE.CAVEKIT.md).