# Usage

Getting-started guide, runnable examples. Full behavior/edge cases → [`docs/SPEC.md`](docs/SPEC.md). Doc friendly front door, not replacement.

## The problem

GraphQL mutations/types duplicate fields elsewhere in schema: `CreateExpenseInput` re-declares half `ExpenseType`'s fields, `TeamMemberExpenseType` re-declares half `ExpenseType` again, Rails controller re-declares input's fields third time as inline `argument`s. Each duplication = place three can silently drift.

Gem let declare relationships once — "this InputObject's arguments subset of that ObjectType's fields" — derives actual `GraphQL::Schema::Argument`/`Field` definitions from source, no hand-copy.

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

`CreateExpenseInput` now got `title`/`expense_date`/`category` (required), `description`
(optional, `prepare: :strip`), `receipt_id` (inline, coexists fine) — all sourced from `ExpenseType`'s existing fields.

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

Column types map to GraphQL types auto (strings, numerics, dates, enums, foreign keys → `ID`, etc.) — full type table `docs/SPEC.md` §9.1.

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

Call `ExpensesController.eager_load_argument_sources!` in CI spec so cycles/typos in `arguments_from` sources fail build, not live request.

## Resolution timing

`derive_from`/`arguments_from` blocks stored **unevaluated** at declaration, evaluated once on resolution. Outside Rails: call `resolve_all!` yourself (schema initializer or test helper). Inside Rails: plugin resolve lazy on first use, but if app reloads classes dev/test, wire re-resolution + cache-clearing through Rails reloader — see `docs/SPEC.md` §6.3/§7.3/§8.2 for exact hooks
(`Rails.application.reloader.to_prepare` / `before_class_unload` +
`GraphQL::Derivation::Rails.reset_for_reload!`).

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

Option outside these lists raises `ConfigurationError` immediately, with "did you mean" suggestion for likely typos.

## Error glossary

| Error | Raised when |
|---|---|
| `GraphQL::Derivation::ConfigurationError` | Any invalid declaration: unknown field, unselected-field override, empty pick block, double `derive_from`, inline/derived name collision, unknown override key. Always at load/resolution time, never mid-request. |
| `GraphQL::Derivation::CyclicDependencyError` | A `derive_from` chain cycles back on itself, e.g. `A → B → A` (message includes full path). Also raised by `eager_load_argument_sources!` for sibling-action cycles. |
| `GraphQL::Derivation::UnresolvableFieldError` | Field resolves via custom class-method resolver (Case 3, SPEC §5.3), selected without explicit `method:`/`resolver:` override. |
| `GraphQL::Derivation::UnsupportedColumnTypeError` | ActiveRecord column type has no GraphQL mapping (e.g. `:jsonb`, unmappable `:array` element type). |
| `GraphQL::Derivation::Rails::MissingInputTypeError` | `arguments` called from controller action that never declared `argument`/`arguments_from`. |
| `GraphQL::Derivation::Rails::ArgumentParsingError` | Request-time coercion failure (missing required arg, bad type, bad enum value) — one error here **not** a `ConfigurationError`. |

## Where to go next

- Full behavior, every edge case, exact resolution algorithms: [`docs/SPEC.md`](docs/SPEC.md).
- Human-readable version of this doc: [`USAGE.md`](USAGE.md).