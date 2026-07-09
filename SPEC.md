§G GOAL
Ruby gem: composable `GraphQL::Schema::Argument`/`Field` derivation from ObjectTypes, InputObjects, Mutations, AR models; Rails `ControllerConcern` for typed coerced request params replacing strong parameters.

---

§M MILESTONES

| ID  | Status | Milestone                                                                                             |
|-----|--------|-------------------------------------------------------------------------------------------------------|
| M.1 | x      | Implementation complete: core + Rails plugin + AR adapter, CI green (317 examples)                    |
| M.2 | .      | Spec complete: `ck:check` clean, impl + RSpec read, `docs/SPEC.md` gaps closed, no `?` in §V         |
| M.3 | .      | Correctness sign-off: independent `ControllerConcern` review (T.47), all §V confirmed by 2nd human   |
| M.4 | .      | OSS release: PR #28 merged, RubyGems name reserved (T.48), security features enabled (T.49), repo public |

---

§C CONSTRAINTS

- `graphql >= 2.1, < 3.0` runtime dep; 2.1.x verified floor (CI matrix against real install, not stub)
- `activesupport` `actionpack` `activerecord` dev deps only — optional; behind require guards; core loads without them
- Ruby >= 3.1 gemspec floor; dev shell pins `ruby_3_4` (nixpkgs; 3.1/3.2 removed from nixpkgs-unstable)
- `# frozen_string_literal: true` on every file
- Dev env via `flake.nix` + `direnv` only (no rbenv/asdf/system Ruby)
- `ConfigurationError` load-time only; `ArgumentParsingError` request-time only — never crossed (V.1)
- `loads:` kwarg not supported in `ControllerConcern#argument` DSL
- Symbol sibling sources disallowed in standalone `DerivableInputObject.derive_from` (V.30)
- No auto-wiring into Rails reloader — consumer calls `reset_for_reload!` explicitly
- Gem marked experimental until stable release; `summary`/`description` wording kept in sync
- `main` branch-protected (GitHub); all changes via PR; Conventional Commits
- RubyGems publish deferred (name not final); install from GitHub for now
- Every `lib/` Ruby file has a 1-to-1 `spec/` counterpart — no orphan lib files (V.36)
- SimpleCov (or successor): all available coverage types enabled; every type at 100% minimum; CI fails below threshold (V.37)
- RuboCop Metrics cops configured with explicit frozen limits (Sandi Metz style preferred: `ClassLength` 100, `MethodLength` 5, `ParameterLists` 4, `CyclomaticComplexity` 4); violations tracked in §D, never blanket-disabled (V.40)
- Request path (`ControllerConcern#arguments`) does zero re-resolution and zero re-coercion per request — all hot-path work is memoized or deferred to load time (V.41 V.42)
- `to_definition` / codegen path is not on the request path — rebuild cost is acceptable there
- Every `ConfigurationError`/`ArgumentError` message includes: offending identifier + available alternatives + corrective action — no bare "invalid" messages (V.43)
- Zero-configuration defaults: `argument_namespace` → `:default`; `resource_arguments required:` → `true` — defaults explicit in docs (V.44)
- `reset_for_reload!` must appear with a runnable example in docs, not just a mention — consumers must not need to read source to wire it correctly (V.45)
- All public-API behavioral changes in `CHANGELOG.md` (Keep a Changelog) before merge; no silent breaking changes

---

§I INTERFACES

require:   `graphql/derivation` (core) | `graphql/derivation/rails` | `graphql/derivation/rails/active_record` | `graphql-ruby-derivation` (core alias)

mixins:    `GraphQL::Derivation::DerivableInputObject` — `.derive_from(src, &blk)` `.resolve_all!` `.clear!`
           `GraphQL::Derivation::DerivableObjectType`  — `.derive_from(src, &blk)` `.resolve_all!` `.clear!`

engines:   `GraphQL::Derivation::ArgumentDerivation.resolve(src, blk, context:)` → `[Argument]`
           `GraphQL::Derivation::FieldDerivation.resolve(src, blk)` → `[Field]`

pick-dsl:  `PickArguments` — `.required(*names)` `.optional(*names)` `.override(name, **opts)`
           `PickFields`    — `.fields(*names)` `.override(name, **opts)`
           arg override opts:   `description` `default_value` `prepare` `validates` `as` `deprecation_reason` `input_type`
           field override opts: `description` `deprecation_reason` `null` `method` `resolver` `name` `camelize`

rails:     `ControllerConcern` class — `argument(name, type, **opts)` `arguments_from(src, &blk)` `resource_arguments(key, required:, &blk)` `argument_namespace(name)` `eager_load_argument_sources!`
           `ControllerConcern` instance — `arguments` → Hash (memoized) | `graphql_argument_input` (overridable; default: `params` → `to_unsafe_h` → `deep_stringify_keys`)
           `ArgumentSchema.for(namespace)` | `.reset!` | `#to_definition` | `#coercion_context`
           `Rails.reset_for_reload!` — clears four registries (V.33)

errors:    `GraphQL::Derivation::Error` (base)
           `ConfigurationError < Error` (load-time programming errors)
           `CyclicDependencyError < ConfigurationError`
           `UnresolvableFieldError < ConfigurationError`
           `UnsupportedColumnTypeError < Error`
           `Rails::MissingInputTypeError < ConfigurationError` (action has no declared arguments)
           `Rails::ArgumentParsingError < Error` (request-time coercion failure — NOT ConfigurationError)

sources (args):   `ObjectType < GraphQL::Schema::Object` | `InputObject < GraphQL::Schema::InputObject` | `Mutation < GraphQL::Schema::Mutation` | `Symbol` (sibling action; ControllerConcern only)
sources (fields): `ObjectType < GraphQL::Schema::Object` | `ActiveRecord::Base` subclass (AR adapter required)

ar-type-map:  `:string/:text/:citext` → `String` | `:integer/:bigint` → `Int` (or `ID` if col ends `_id`) | `:float/:decimal/:numeric` → `Float` | `:boolean` → `Boolean` | `:date` → `ISO8601Date` | `:datetime/:timestamp/:timestamptz` → `ISO8601DateTime` | `:uuid` → `ID` | `:enum` → generated enum via `defined_enums` | `:array` → `[elem]` if elem mappable (via `sql_type` suffix strip) | `:jsonb/:json/:hstore` → `UnsupportedColumnTypeError`
ar-excluded:  `id` `created_at` `updated_at`

---

§V INVARIANTS

V.1   `ConfigurationError` at class load time only; `ArgumentParsingError` at request time only — never swapped (T.1)
V.2   `CyclicDependencyError` for any `derive_from` cycle across DerivableInputObject and/or DerivableObjectType via shared `DerivationResolutionGuard` stack (T.2)
V.3   `derive_from` at most once per class; second call raises `ConfigurationError` (T.3)
V.4   Zero-selection pick block raises `ConfigurationError` from `PickDsl::Base#validate!` (T.4)
V.5   Same name in both `pick.required` and `pick.optional` raises `ConfigurationError`; same-bucket re-select is idempotent (T.5)
V.6   `pick.override` on unselected name raises `ConfigurationError` (T.6)
V.7   Unknown name in `required`/`optional`/`fields` raises `ConfigurationError` with `DidYouMean::SpellChecker` suggestion (T.7)
V.8   Connection-type fields (name ends `Connection` or includes `BaseConnection` ancestor) excluded from ObjectType candidates in both arg and field derivation (T.8)
V.9   List-of-Object fields excluded from ObjectType argument candidates (T.9)
V.10  Non-connection Object-type field selected as argument without `input_type:` override raises `ConfigurationError` (deferred from enumeration to build step) (T.10)
V.11  Derived arg/field `graphql_name` colliding with inline declaration raises `ConfigurationError` at resolution time (T.11)
V.12  `ArgumentDerivation`: unsupported source type raises `ArgumentError` at enumeration time (T.12)
V.13  `FieldDerivation`: unsupported source type raises `ArgumentError`; AR loaded but adapter not required → `NotImplementedError` (T.13)
V.14  Case 3 custom resolver detected via `source.respond_to?("resolve_#{name}")` (not `method_defined?` — singleton methods only) → `UnresolvableFieldError` unless `method:` or `resolver:` override present (T.14)
V.15  AR columns `id` `created_at` `updated_at` never offered as candidates (T.15)
V.16  AR unsupported-type column raises `UnsupportedColumnTypeError` only when selected (lazy `Candidate` block) — unselected unsupported columns do not raise (T.16)
V.17  AR-derived fields default `null: true`; `column.null == false` (NOT NULL constraint) → `null: false` default (T.17)
V.18  AR int/bigint columns ending `_id` mapped to `GraphQL::Types::ID` (FK name override — only narrows Int to ID; uuid already maps to ID via type table) (T.18)
V.19  AR enum resolved via `Model.defined_enums`; native pg `:enum` with no `defined_enums` entry raises `UnsupportedColumnTypeError` (T.19)
V.20  AR enum cached per `[model.name, column_name]` + `equal?` identity check — rebuilt on model-class reload (T.20)
V.21  `ControllerConcern#arguments` memoized per request via `@arguments` ivar (T.21)
V.22  Unknown top-level request params silently ignored — sliced to `input_object.arguments.keys` before coercion (T.22)
V.23  `arguments` raises `MissingInputTypeError` when action has no registered InputObject (T.23)
V.24  `arguments` raises `ArgumentParsingError` wrapping `GraphQL::ExecutionError` or `GraphQL::CoercionError` (T.24)
V.25  `ArgumentSchema` one instance per namespace cached for process lifetime; `nil` → `:default` (T.25)
V.26  `ArgumentSchema#to_definition` uses disposable fresh schema with real synthetic query root (not `extra_types`) — makes nested `resource_arguments` InputObjects reachable in SDL; rebuilt on every call (T.26)
V.27  `ArgumentSchema#register_input_object` deduplicates by `graphql_name` not identity — reload-safe, stale entry replaced (T.27)
V.28  `arguments_from` at most once per action/resource scope; second call raises `ConfigurationError` (T.28)
V.29  `resource_arguments` block inside another `resource_arguments` block raises `ConfigurationError` immediately (T.29)
V.30  Symbol source in standalone `DerivableInputObject.derive_from` raises `ArgumentError`; ControllerConcern auto-generated InputObjects opt in via private `allow_sibling_sources!` (T.30)
V.31  Sibling action must exist on same controller or ancestor by resolution time; absent → `ConfigurationError` (T.31)
V.32  `eager_load_argument_sources!` raises `CyclicDependencyError` for sibling action cycles (DFS `sibling_resolution_stack`, separate from `DerivationResolutionGuard`) (T.32)
V.33  `reset_for_reload!` clears: `DerivableInputObject.included_classes`, `DerivableObjectType.included_classes`, `ArgumentSchema` namespace cache, AR enum cache (T.33)
V.34  `ArgumentSchema::NullQueryContext` compatible with graphql-ruby 2.1.x–2.x — exposes `#warden` (2.1–2.3) and `#types` (2.4+) without depending on `NullContext` singleton (T.34)
V.35  `validates: required: { one_of: [...] }` override compatible with `NullWarden` — confirmed or limitation documented ? (T.35)
V.36  Every `lib/graphql/derivation/**/*.rb` has a corresponding `spec/graphql/derivation/**/*_spec.rb` — 1-to-1, no orphan lib files (T.52)
V.37  All SimpleCov (or successor) coverage types enabled; every type at 100% minimum; CI fails below threshold (T.51)
V.40  RuboCop Metrics cops (`ClassLength` `MethodLength` `ParameterLists` `CyclomaticComplexity` `PerceivedComplexity`) configured with frozen explicit limits; violations go to §D, never blanket-disabled (T.53)
V.41  Derivation resolution fires exactly once per class — `@derivation_pick_block = nil` sentinel prevents re-evaluation; `resolve_derivation!` is idempotent (T.52)
V.42  `ControllerConcern#arguments` hot path: memoized via `@arguments`; no re-resolution, no re-coercion per request (V.21)
V.43  Every `ConfigurationError`/`ArgumentError` message includes offending identifier + available alternatives + corrective action hint — no bare "invalid" messages (T.55)
V.44  Zero-configuration defaults explicit in docs: `argument_namespace` → `:default`; `resource_arguments required:` → `true` (T.56)
V.45  `reset_for_reload!` documented with runnable example code — consumer must not need to read source to wire it (T.56)

---

§T TASKS

| ID   | Status | Task                                                                                                    |
|------|--------|---------------------------------------------------------------------------------------------------------|
| T.1  | x      | `ConfigurationError`/`ArgumentParsingError` separation — `errors.rb` + `rails/errors.rb`               |
| T.2  | x      | Cross-mixin cycle detection via shared `DerivationResolutionGuard` stack                                |
| T.3  | x      | `derive_from` at-most-once guard in `DerivableInputObject` + `DerivableObjectType`                     |
| T.4  | x      | Zero-selection `ConfigurationError` in `PickDsl::Base#validate!`                                        |
| T.5  | x      | Cross-bucket duplicate detection in `PickArguments#validate!`                                           |
| T.6  | x      | `override`-on-unselected check in `PickDsl::Base#override`                                              |
| T.7  | x      | Unknown-name `ConfigurationError` + `DidYouMean::SpellChecker` suggestion in `PickDsl::Base`            |
| T.8  | x      | Connection-type exclusion in `ObjectTypeToArgument` + `ObjectTypeToField` candidates                    |
| T.9  | x      | List-of-Object exclusion in `ObjectTypeToArgument` candidates                                           |
| T.10 | x      | `NestedObjectCandidate` deferred eligibility check in `ArgumentDerivation#build_argument`               |
| T.11 | x      | Collision detection in `DerivableInputObject` + `DerivableObjectType`                                   |
| T.12 | x      | Unsupported-source `ArgumentError` in `ArgumentDerivation#enumerate_candidates`                         |
| T.13 | x      | Unsupported-source `ArgumentError`/`NotImplementedError` in `FieldDerivation#enumerate_candidates`      |
| T.14 | x      | Case 3 `respond_to?` detection → `UnresolvableFieldError` in `FieldDerivation#check_resolver!`          |
| T.15 | x      | `EXCLUDED_COLUMNS` in `ActiveRecordMapper`                                                              |
| T.16 | x      | Lazy type resolution via `Candidate` block in `ActiveRecordMapper`                                      |
| T.17 | x      | `null_default?` from `column.null` in `ActiveRecordMapper`                                              |
| T.18 | x      | `apply_foreign_key_override` (int/bigint + `*_id` → `ID`) in `ActiveRecordMapper`                       |
| T.19 | x      | Enum via `defined_enums` + `UnsupportedColumnTypeError` for unmapped native enum in `ActiveRecordMapper` |
| T.20 | x      | `@enum_cache` with `equal?` model identity check in `ActiveRecordMapper`                                |
| T.21 | x      | `@arguments` memoization in `ControllerConcern#arguments`                                               |
| T.22 | x      | `raw_input.slice(*input_object.arguments.keys)` in `ControllerConcern#coerce_with_input_object`         |
| T.23 | x      | `MissingInputTypeError` raise in `ControllerConcern#coerce_request_arguments`                           |
| T.24 | x      | `ArgumentParsingError` wrapping `ExecutionError`/`CoercionError` in `ControllerConcern`                 |
| T.25 | x      | `ArgumentSchema.for(namespace)` cache                                                                   |
| T.26 | x      | Disposable `build_print_schema` with synthetic query root in `ArgumentSchema`                           |
| T.27 | x      | `register_input_object` graphql_name-based dedup in `ArgumentSchema`                                    |
| T.28 | x      | `arguments_from` at-most-once guard in `ControllerConcern`                                              |
| T.29 | x      | Nested `resource_arguments` guard in `ControllerConcern#check_no_nested_resource_scope!`                |
| T.30 | x      | `check_supported_source!` + `allow_sibling_sources!` in `DerivableInputObject`                          |
| T.31 | x      | Missing sibling `ConfigurationError` in `ControllerConcern#resolve_sibling_arguments`                   |
| T.32 | x      | DFS `sibling_resolution_stack` + `detect_sibling_cycle!` in `ControllerConcern`                         |
| T.33 | x      | `Rails.reset_for_reload!` clears four registries                                                        |
| T.34 | x      | `NullQueryContext` dual-path `#warden`/`#types` in `ArgumentSchema`                                     |
| T.35 | .      | Confirm `validates: required: { one_of: [...] }` NullWarden compat or document limitation               |
| T.36 | ~      | `docs/SPEC.md` §5.3: `method_defined?` → `respond_to?` (spec error — edit applied, commit pending)     |
| T.37 | .      | `docs/SPEC.md` §2: add `Rails::MissingInputTypeError` + `Rails::ArgumentParsingError` to error hierarchy |
| T.38 | .      | `docs/SPEC.md` §1.3: add `derivation_resolution_guard.rb` `pick_dsl/base.rb` `rails/errors.rb`          |
| T.39 | .      | `docs/SPEC.md` §5.1: source validation fires at resolution time via DerivableObjectType, not declaration |
| T.40 | .      | `docs/SPEC.md` §4.2 sibling source: NonNull stripped (not pure identity) — same as InputObject source   |
| T.41 | .      | `docs/SPEC.md` §8.1: document `graphql_argument_input` override point                                   |
| T.42 | .      | `docs/SPEC.md` §6.3/§7.3: document `DerivableInputObject.clear!` + `DerivableObjectType.clear!`         |
| T.43 | .      | `docs/SPEC.md` §9.4: FK override only narrows int/bigint to ID, not all `*_id` types                    |
| T.44 | .      | `docs/SPEC.md` §10.2: add `money_amount_type.rb` + `mutations/create_expense_mutation.rb` to fixture list |
| T.45 | .      | `docs/SPEC.md` §11.1 + §11.4: close open questions (both resolved in implementation)                    |
| T.46 | x      | `docs/SPEC.md` §1 + §10 status table: Specified → Implemented (commit 320f4d0)                          |
| T.47 | .      | Independent code review of `ControllerConcern` param-parsing (Edwin's open item, PR #28)                |
| T.48 | .      | Reserve RubyGems gem name before OSS flip                                                               |
| T.49 | .      | Enable GitHub secret scanning + private vulnerability reporting on OSS flip                              |
| T.50 | .      | Regenerate `USAGE.CAVEKIT.md` from `USAGE.md` once `docs/SPEC.md` gaps closed                          |
| T.51 | .      | Configure SimpleCov: enable all available coverage types; set minimum 100% for each; fail CI on miss   |
| T.52 | .      | Audit 1-to-1 `lib/`↔`spec/` mapping; add missing spec files or capture gaps in §D                     |
| T.53 | .      | Configure RuboCop Metrics cops with frozen limits (Sandi Metz preferred); capture current violations in §D |
| T.54 | .      | Performance review: profile `ControllerConcern#arguments` under realistic load; verify no re-resolution on hot path |
| T.55 | .      | Audit all `ConfigurationError`/`ArgumentError` messages: each must include offending identifier + available alternatives + corrective hint (V.43) |
| T.56 | .      | Verify zero-config defaults (V.44) and `reset_for_reload!` runnable example (V.45) are in `docs/SPEC.md` + `USAGE.md` |
| T.57 | .      | Extract `source_name` helper — duplicated verbatim in `ArgumentDerivation` + `FieldDerivation`; move to shared utility |
| T.58 | .      | Extract `connection_type?` detection — duplicated in `ObjectTypeToArgument` + `ObjectTypeToField`; move to shared utility |

---

§S SPECS

| File                                                                         | Covers                         | Description                                            |
|------------------------------------------------------------------------------|--------------------------------|--------------------------------------------------------|
| `spec/graphql/derivation/pick_dsl/arguments_spec.rb`                        | V.4 V.5 V.6 V.7                | PickArguments selection, validation, override           |
| `spec/graphql/derivation/pick_dsl/fields_spec.rb`                           | V.4 V.6 V.7                    | PickFields selection, validation, override              |
| `spec/graphql/derivation/mappers/object_type_to_argument_spec.rb`           | V.8 V.9 V.10                   | ObjectType → Argument type mapping, exclusions          |
| `spec/graphql/derivation/mappers/input_object_to_argument_spec.rb`          | V.12                           | InputObject/Mutation identity map                       |
| `spec/graphql/derivation/mappers/object_type_to_field_spec.rb`              | V.8 V.14                       | ObjectType → Field, resolver cases 1–3                  |
| `spec/graphql/derivation/engines/argument_derivation_spec.rb`               | V.4 V.11 V.12                  | Full resolution, all source types, collision            |
| `spec/graphql/derivation/engines/field_derivation_spec.rb`                  | V.13 V.14                      | Full resolution, ObjectType + AR sources                |
| `spec/graphql/derivation/derivation_resolution_guard_spec.rb`               | V.2                            | Cross-mixin cycle detection                             |
| `spec/graphql/derivation/derivable_input_object_spec.rb`                    | V.2 V.3 V.11 V.30              | Mixin, introspection, cycle, sibling-source guard       |
| `spec/graphql/derivation/derivable_object_type_spec.rb`                     | V.2 V.3 V.11                   | Mixin, introspection, cycle                             |
| `spec/graphql/derivation/rails/controller_concern_spec.rb`                  | V.21 V.22 V.23 V.24 V.28 V.29 V.30 V.31 V.32 | ControllerConcern DSL, coercion, cycles |
| `spec/graphql/derivation/rails/argument_schema_spec.rb`                     | V.25 V.26 V.27                 | ArgumentSchema namespace, to_definition, reload dedup   |
| `spec/graphql/derivation/rails/adapters/active_record_mapper_spec.rb`       | V.15 V.16 V.17 V.18 V.19 V.20 | AR mapper: type map, null, FK, enum, lazy resolve       |
| `spec/graphql/derivation/errors_spec.rb`                                    | V.1                            | Error hierarchy structure                               |
| `spec/graphql/derivation/rails_spec.rb`                                     | V.33                           | `reset_for_reload!`                                     |
| `spec/graphql/derivation/integration_spec.rb`                               | V.2 V.21 V.34                  | Cross-layer integration, graphql-ruby version compat    |
| `spec/graphql/derivation_spec.rb`                                           | I.require                      | Core require path loads correctly                       |
| `spec/support/fixture_schema_spec.rb`                                       | —                              | Fixture schema integrity sanity check                   |

---

§B BUGS

| ID | Bug | Fix |
|----|-----|-----|

---

§P POTENTIAL

| ID  | Idea                              | Description                                                                                                                                                                  |
|-----|-----------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| P.1 | Merge Derivable twin modules      | `DerivableInputObject` + `DerivableObjectType` share ~70% logic (`included_classes`, `clear!`, `resolve_all!`, `resolve_derivation!`, cycle guard, collision check). A shared `Derivable` base mixin would DRY this. Tradeoff: adds abstraction layer + meta-programming; current duplication is explicit and readable. Defer until a third Derivable type appears or maintenance cost is felt. |
