# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Lazy resolution on first use. A pending `derive_from` now resolves the first time graphql-ruby
  reads the class: `DerivableInputObject` hooks `arguments`, `get_argument`,
  `all_argument_definitions` and `any_arguments?` (plus `dummy` on a `RelayClassicMutation`
  host), `DerivableObjectType` hooks `fields`, `get_field` and `all_field_definitions`. Those are
  the paths schema build, SDL dump, introspection, validation and execution actually go
  through, under both the legacy `Warden` and `GraphQL::Schema::Visibility`, so derived
  arguments/fields appear on the very first request with no `resolve_all!` and no
  `Schema.execute` hook. The hooks also resolve every Derivable ancestor, so a Ruby subclass of
  a derivable type gets its parent's derived members. Declaring inline members never triggers a
  resolution, so declaration order in the class body does not matter. `resolve_all!` is
  unchanged and still useful as an eager warm-up that fails at boot instead of on first use.
- Derived arguments on a `RelayClassicMutation` host are now mirrored into the generated
  `<Name>Input` type, the same way graphql-ruby mirrors inline `argument` declarations.
  Previously they were registered on the mutation class only and never reached the type a
  request is validated against.
- Resolution is now serialized behind a process-wide re-entrant lock shared with the cycle
  guard (`DerivationResolutionGuard`), so a first read on a request thread is safe: a second
  thread reading the same class waits, then sees it fully resolved. Resolving one chain from
  both ends concurrently cannot deadlock (one lock, not one per class).
- Controller-generated InputObjects remember their controller class as the sibling-resolver
  context, so a lazy first read of one with an `arguments_from :sibling` source (e.g.
  `ArgumentSchema#to_definition`) resolves without `ControllerConcern` driving the call.

- `CONTRIBUTING.md`, per Oyster's OSS release policy's "Release Requirements" (README must
  document contribution guidelines; a `CONTRIBUTING.md`, if applicable, should be included).
  Human-oriented; points to `AGENTS.md` for full process detail.

### Changed

- A derivation that raises (collision, cycle, failing pick block) is no longer remembered as
  attempted: it stays pending and the next read, lazy or explicit, raises again. A misconfigured
  class therefore stays loud on every access instead of surfacing the error once and then
  quietly serving only its inline members.
- `resolve_pending_derivation!` reads the pre-existing member names via
  `all_argument_definitions` / `all_field_definitions` instead of `arguments.keys` /
  `fields.keys`, which drops the visibility pass and graphql-ruby's "types must have
  arguments/fields" warning that a derive-only class used to emit mid-resolution.
- `GraphQL::Derivation::Rails::ArgumentParsingError` renamed to
  `GraphQL::Derivation::Rails::ArgumentCoercionError` -- "parsing" misnamed the operation; every
  other reference to it in code and docs already says "coercion" (`coerce_input`,
  `coerce_request_arguments`). Breaking rename, made in the pre-release window before the gem has
  any external consumers pinning the old name.

### Fixed

- `derive_from` (via `pick.required`/`pick.optional`) no longer drops a picked argument's own
  option metadata. `ArgumentDerivation#build_argument` used to build the derived argument from
  only `{required:}` plus any `pick.override` opts, discarding everything else the source
  `GraphQL::Schema::Argument` was declared with. A derived argument now also carries across the
  source's `prepare:`, `description:`, `default_value:` (when configured), `validates:`, and
  `deprecation_reason:`. An explicit `pick.override(name, **opts)` still wins over any of these,
  and `required:` itself is still controlled solely by `pick.required`/`pick.optional`, exactly as
  before. Applies to InputObject, Mutation, and Symbol (sibling action) sources -- not to
  ObjectType-field sources, whose candidates come from `GraphQL::Schema::Field`, which has no
  `prepare:`/`validates:` equivalent to carry.
  - If the source argument is deprecated and `pick.required` would make the derived argument
    non-null, `derive_from` raises `ConfigurationError` instead of silently dropping
    `deprecation_reason:` -- graphql-ruby forbids a deprecated required argument, and the caller
    must choose explicitly between `pick.optional(name)` (keep the deprecation) and
    `pick.override(name, deprecation_reason: nil)` (state that the derived argument is not
    deprecated).
  - `validates:` is carried by transplanting the source argument's own compiled `Validator`
    instances onto the derived argument (there is no raw config hash left to re-read once
    graphql-ruby has built them), with each validator's `@validated` rebound to the derived
    argument so a validation error names the derived argument, not the source's.
  - A Symbol `prepare:` carries across as-is; since graphql-ruby resolves a Symbol `prepare:`
    against the argument's owner at request time, the TARGET class (not the source) must define
    an instance method with that name, or coercion raises `Could not find prepare method` the
    first time a client sends the argument. See `USAGE.md`'s "`prepare:` — Symbol vs. lambda".
- `ControllerConcern#arguments` no longer raises `ArgumentCoercionError` ("Field is not defined")
  for Rails routing internals (`controller`, `action`) or any dynamic route segment not declared
  as an argument (e.g. `params[:engagement_id]` on a nested resource route). A real Rails
  `params` always includes these regardless of what an action declares; they are now filtered
  out (`raw_input.slice(*input_object.arguments.keys)`) before validation/coercion, matching
  Rails' own strong-parameters philosophy of silently dropping unpermitted keys rather than
  raising (SPEC.md §8.1). Found via a real controller spec in a consuming app -- every existing
  spec here stubbed `params` as a bare Hash containing only the fields under test, so none of
  them exercised a `params` shaped like a real request.

### Added

- `GraphQL::Derivation::Rails::ControllerConcern.resource_arguments(key, required: true, &block)`:
  declares a Rails-idiomatic nested resource scope for an action (SPEC.md §8.1), so the request
  wire format can match `form_for`/strong-parameters conventions (`{ expense: { title: ... } }`)
  instead of every argument sitting flat at the top level. `argument`/`arguments_from` calls
  inside the block are scoped to that resource; flat and nested arguments may be freely mixed on
  one action. Mechanically sugar over the existing InputObject machinery: the block's own nested
  InputObject is added as a plain, ordinary `argument key, NestedInputObjectClass, required:
  required` on the action's InputObject, so all of `coerce_input`, collision detection, and
  `arguments_from` cycle detection already handle it as a normal case. `required:` defaults to
  `true` and is deliberately not inferable, since the nested type's own nullability
  (`ExpensesCreateExpenseInput!` vs `...Input`) must be explicit for TypeScript codegen off the
  generated SDL. Also defines a private `"#{key}_params"` instance helper (e.g. `expense_params`),
  equivalent to `arguments[key]`, for familiar Rails-style call sites.
  `#arguments`/`#{key}_params` now return nested values as plain, recursively-unwrapped Ruby
  Hashes (via `#to_h`, not `#to_kwargs` -- see the `Changed` entry below), not
  `GraphQL::Schema::InputObject` instances.

### Changed

- **`GraphQL::Derivation::Rails::ArgumentSchema`'s introspection design.** Previously,
  `register_input_object` registered every InputObject via `extra_types`. Building
  `resource_arguments` surfaced a real bug in that design: `extra_types` can never make an
  argument reachable in `Schema#to_definition` if the argument's own type is *also* an
  InputObject (exactly the `resource_arguments` case), because graphql-ruby's SDL printer
  explicitly skips InputObject-kind `extra_types` entries when computing reachability
  (InputObject cannot be a field return type) -- confirmed with a minimal graphql-ruby-only
  repro, not an `ArgumentSchema` bug specifically. `to_definition` is now overridden to delegate
  printing to a fresh, disposable schema built on every call, with a real (synthetic, never
  executed) `query` root exposing each registered *top-level* InputObject as a field argument.
  Once the top-level InputObject is reachable via a real root, graphql-ruby's normal reachability
  traversal correctly walks everything it references at any nesting depth, with no
  `extra_types`/`orphan_types` special-casing needed -- so only top-level InputObjects need
  registering now; a `resource_arguments` scope's own nested InputObject is reached automatically.
  `#arguments`'s coercion path also switched from `Interpreter::Arguments#to_kwargs` to the
  coerced InputObject instance's own `#to_h`, which (unlike `to_kwargs`) recursively unwraps a
  nested InputObject argument value into a plain Hash -- identical output to `to_kwargs` for the
  previously-only-supported flat case.
- **Verified `graphql` dependency floor: `>= 2.1, < 3.0`.** An earlier iteration of this work
  briefly raised the floor to `>= 2.3` in response to `extra_types` never being able to make a
  nested-InputObject argument reachable -- but that turned out to be a general limitation of the
  `extra_types`-based design on *any* graphql-ruby version, not a 2.1.x-specific gap. The
  synthetic-query-root design (above) uses only plain, long-stable root-based reachability, and
  works identically on graphql-ruby 2.1.x -- confirmed by running the full test suite against a
  real graphql-ruby 2.1.15 install (SPEC.md §12.6's `gemfiles/graphql_2.1.gemfile`).
- `GraphQL::Derivation::Rails::ArgumentSchema::NullQueryContext#types` now documents (and is
  tested against) both `context.warden.arguments(...)`-based coercion (graphql-ruby 2.1.x-2.3.x)
  and `context.types.arguments(...)`-based coercion (2.4+), reflecting the restored 2.1.x floor.

### Added

- `NOTICE` file listing every gemspec dependency and its license (all currently MIT), for Legal's
  OSS license-compatibility review. Update it in the same PR as any gemspec dependency change.
- README disclosure: the gem is experimental (use at your own risk) and all code in the
  repository was written with agentic coding assistance.
- `gemfiles/graphql_2.1.gemfile`, pinning `graphql ~> 2.1.0` (this gem's floor). CI now runs
  `bundle exec rspec` against both this and the main `Gemfile` (SPEC.md §12.6), so
  `ArgumentSchema`'s graphql-ruby-2.1.x-and-up assumptions are exercised against a real old
  install, not just the latest release.
- `GraphQL::Derivation::Rails::ArgumentSchema::NullQueryContext`: this gem's own permanent
  replacement for `GraphQL::Query::NullContext` as the context `coerce_input` runs against.
  `NullContext` cannot be bound to a caller-supplied schema on any graphql-ruby version this gem
  supports (it stays a `Singleton` fixed to its own internal schema through at least 2.5.x, per
  SPEC.md §8.2), so this gem builds its own from the same stable primitives graphql-ruby's
  `NullContext` composes internally.

### Changed

- Gemspec `authors`/`email` changed from `Oyster HR Developers` / `engineering-paperwork@oysterhr.com`
  to `Oyster HR, Inc. Engineers` / `developers@oysterhr.com`, matching the convention Legal
  settled on for OSS releases (a durable departmental identity, not an individual's).
- Gemspec `summary`/`description` now note the gem is experimental.

- `GraphQL::Derivation::ArgumentDerivation` now accepts a Mutation class
  (`< GraphQL::Schema::Mutation`, including `GraphQL::Schema::RelayClassicMutation`) as a source,
  in addition to ObjectType/InputObject/Symbol (SPEC §4.1/§4.2). A mutation's arguments are
  identity-mapped exactly like an InputObject's -- both extend
  `GraphQL::Schema::Member::HasArguments`, so the existing `InputObjectToArgument` mapper handles
  Mutation sources unchanged. `DerivableInputObject#derive_from` and the Rails
  `ControllerConcern#arguments_from` accept a Mutation class transparently, with no caller-side
  special-casing required.
- `GraphQL::Derivation` error hierarchy: `Error`, `ConfigurationError`, `CyclicDependencyError`,
  `UnresolvableFieldError`, `UnsupportedColumnTypeError` (SPEC §2).
- Pick DSL: `PickArguments` and `PickFields`, the block interface used by argument and field
  derivation (SPEC §3).
- `GraphQL::Derivation::ArgumentDerivation` engine plus `ObjectTypeToArgument` and
  `InputObjectToArgument` mappers, deriving `GraphQL::Schema::Argument` instances from an
  ObjectType, InputObject, or sibling-action (`Symbol`) source (SPEC §4). Symbol sources resolve
  through a `context:` object that responds to `resolve_sibling_arguments(symbol)`; the Rails
  `ControllerConcern` supplies the controller class as that resolver.
- `GraphQL::Derivation::FieldDerivation` engine plus `ObjectTypeToField` mapper, deriving
  `GraphQL::Schema::Field` instances from an ObjectType source, including resolver Case 1/2/3
  handling (SPEC §5). ActiveRecord-model sources are now also supported, dispatching to the
  ActiveRecord adapter (SPEC §9) once it has been required.
- `GraphQL::Derivation::DerivableInputObject` mixin: `derive_from` on `GraphQL::Schema::InputObject`
  subclasses, with deferred resolution via `resolve_all!`, collision detection against inline
  `argument` declarations, and idempotent re-resolution (SPEC §6).
- `GraphQL::Derivation::DerivableObjectType` mixin: `derive_from` on `GraphQL::Schema::Object`
  subclasses, with deferred resolution via `resolve_all!`, collision detection against inline
  `field` declarations, and idempotent re-resolution (SPEC §7).
- Rails plugin (`require 'graphql/derivation/rails'`): `GraphQL::Derivation::Rails::ControllerConcern`
  (`argument`, `arguments_from`, instance-level `arguments`, `argument_namespace`, and
  `eager_load_argument_sources!` with sibling-cycle detection) and per-namespace
  `GraphQL::Derivation::Rails::ArgumentSchema` (`.for(namespace)`), plus the
  `MissingInputTypeError` (load-time) and `ArgumentCoercionError` (request-time) errors (SPEC §8).
  `activesupport` and `actionpack` (`~> 7.0`) are declared as optional development dependencies,
  consumed only through this require path (core stays Rails-free).
- ActiveRecord adapter (`require 'graphql/derivation/rails/active_record'`):
  `GraphQL::Derivation::Rails::Adapters::ActiveRecordMapper`, mapping AR column definitions to
  GraphQL field type/null information for `FieldDerivation` (SPEC §9). Covers the full §9.1 column
  type table (including `:array` of a mappable element type, and `UnsupportedColumnTypeError` for
  `:jsonb`/`:json`/`:hstore` and other unmapped types), Rails-enum/native-enum generation with
  per-`(model, column)` memoization (§9.2), NOT-NULL-derived `null:` defaults overridable via
  `pick.override` (§9.3), and the `id`/`created_at`/`updated_at` exclusion (§9.4). Reconciles §9.1's
  type-keyed mapping table with §9.4's "foreign key columns map to `GraphQL::Types::ID`" note as a
  name-based override: a column whose name ends in `_id` (and isn't the already-excluded `id`
  primary key) is mapped to `GraphQL::Types::ID` instead of `GraphQL::Types::Int` whenever its
  underlying type would otherwise resolve to `Int`. `activerecord` (`~> 7.0`) is declared as an
  optional development dependency, consumed only through this require path.
- `GraphQL::Derivation::Rails.reset_for_reload!`: a reload-safety utility for Rails apps running
  with class reloading enabled (dev/test). Clears `DerivableInputObject.included_classes`,
  `DerivableObjectType.included_classes` (via new `.clear!` methods on both), all cached
  per-namespace `ArgumentSchema`s, and (if loaded) `ActiveRecordMapper.enum_cache`. Not
  auto-wired into anything -- intended to be called explicitly from
  `Rails.application.reloader.before_class_unload` (SPEC §8.2/§9.2).

### Changed

- `pick.override` now validates its keyword options eagerly, against an explicit per-subclass
  allowlist (SPEC §3.2/§3.3's documented "Valid override opts"), instead of accepting anything and
  letting a typo surface later (or never) at resolution time. An unknown option now raises
  `ConfigurationError` immediately, at the `pick.override` call site, with a "did you mean" typo
  suggestion where one is found.
- Improved several `ConfigurationError`/message-quality issues flagged in review (addressing
  PR #7, #11, #13 review comments): unknown-field errors now name the derivation source and list
  its available names (sorted); the empty-selection and not-yet-selected `override` errors now say
  what to call next; the `required`/`optional` duplicate-field error names the field and both
  methods involved; and the `derive_from` "at most once" and inline-declaration-collision errors on
  `DerivableInputObject`/`DerivableObjectType` are more explicit about what happened and how to fix
  it. No behavior change to the "at most once" `derive_from` restriction itself (SPEC §6.2/§7.2) --
  only its message text.

### Fixed

- `DerivableInputObject`-derived arguments are now built with their owning InputObject class
  attached. Previously they were registered with `owner: nil`, which made `coerce_input` raise
  on any derived InputObject (SPEC §6).
- `resolve_derivation!` (both `DerivableInputObject` and `DerivableObjectType`) now recursively
  resolves a `derive_from` source's own pending derivation, if it is itself Derivable, before
  reading its `.arguments`/`.fields`. Previously resolution was a flat, single pass over each
  mixin's `included_classes` in inclusion order, so a valid `A.derive_from(B)` /
  `B.derive_from(SomeSource)` chain would silently succeed or raise `ConfigurationError` purely
  based on which class happened to be included first -- non-deterministic under autoloading or
  spec-order randomization. Resolution order no longer matters (SPEC §6.2/§7.2).
- A genuine `derive_from` cycle (e.g. `A.derive_from(B)`, `B.derive_from(A)`) now raises
  `GraphQL::Derivation::CyclicDependencyError` with the full cycle path (e.g.
  `Cyclic derive_from dependency: A → B → A`), via a new shared
  `GraphQL::Derivation::DerivationResolutionGuard` in-progress stack consulted by both
  `DerivableInputObject` and `DerivableObjectType` (so a cycle crossing both mixins is caught too).
  Previously this surfaced as a misleading "does not define it, available names: ∅" error,
  indistinguishable from a typo or an empty source.
- `ArgumentSchema#register_input_object` now de-duplicates by `graphql_name`, not object
  identity. Previously, `ControllerConcern`'s auto-generated InputObjects (which have stable
  `graphql_name`s but are rebuilt as new class objects on every Rails class reload) would
  accumulate a second registered type with the same name after each reload, since identity-based
  `include?` never matched the new object -- crashing the next `to_definition`/introspection/
  schema-validation call with `GraphQL::Schema::DuplicateNamesError`. Re-registering under an
  already-registered name now replaces the prior entry with the new one; registering the exact
  same object twice remains a safe no-op (SPEC §8.2).
- `ActiveRecordMapper.enum_cache` is now keyed by `[model.name, column_name]` (a String key) and
  additionally guards against a stale hit by comparing the cached entry's model class object with
  `equal?`. Previously the cache was keyed by `[model, column_name]` (the model class object
  itself), so a Rails class reload -- which produces a new model class object with the same
  `.name` -- never matched the old cache entry: it leaked a stale entry per reload and generated a
  new enum class with the exact same `graphql_name` (derived from `model.name`), risking the same
  `GraphQL::Schema::DuplicateNamesError` crash as the `ArgumentSchema` issue above if the old enum
  class stayed reachable (SPEC §9.2).
