# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
