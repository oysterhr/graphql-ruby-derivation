# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `NOTICE` file listing every gemspec dependency and its license (all currently MIT), for Legal's
  OSS license-compatibility review. Update it in the same PR as any gemspec dependency change.
- README disclosure: the gem is experimental (use at your own risk) and all code in the
  repository was written with agentic coding assistance.
- `gemfiles/graphql_2.3.gemfile`, pinning `graphql ~> 2.3.0` (this gem's floor). CI now runs
  `bundle exec rspec` against both this and the main `Gemfile` (SPEC.md §12.6), so
  `ArgumentSchema`'s graphql-ruby-2.3-and-up assumptions are exercised against a real old install,
  not just the latest release.
- `GraphQL::Derivation::Rails::ArgumentSchema::NullQueryContext`: this gem's own permanent
  replacement for `GraphQL::Query::NullContext` as the context `coerce_input` runs against.
  `NullContext` cannot be bound to a caller-supplied schema on any graphql-ruby version this gem
  supports (it stays a `Singleton` fixed to its own internal schema through at least 2.5.x, per
  SPEC.md §8.2), so this gem builds its own from the same stable primitives graphql-ruby's
  `NullContext` composes internally.

### Changed

- **Breaking:** raised the `graphql` dependency floor from `~> 2.0` to `>= 2.3, < 3.0`. 2.3.0 is
  graphql-ruby's first release with `extra_types`, which `ArgumentSchema` needs to make anonymous
  InputObjects introspectable (SPEC.md §1.2/§8.2) -- earlier releases (2.1.x/2.2.x) only have
  `orphan_types`, which cannot make an InputObject visible in `Schema#to_definition` at all
  (confirmed against a real graphql-ruby 2.1.15 install; this is an upstream limitation, not
  something worth carrying a permanently-incomplete compatibility shim for).

### Changed

- Gemspec `authors`/`email` changed from `Oyster HR Developers` / `engineering-paperwork@oysterhr.com`
  to `Oyster HR, Inc. Engineers` / `developers@oysterhr.com`, matching the convention Legal and
  the `tabasco` gem settled on for OSS releases (a durable departmental identity, not an
  individual's).
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
  `MissingInputTypeError` (load-time) and `ArgumentParsingError` (request-time) errors (SPEC §8).
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
