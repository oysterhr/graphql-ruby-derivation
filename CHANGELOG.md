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
  handling (SPEC §5). ActiveRecord-model sources are not yet supported — deferred until the
  ActiveRecord adapter lands (SPEC §9).
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
