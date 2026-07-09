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
- `activesupport` `actionpack` `activerecord` dev deps only — optional; behind require guards; core loads without them; `>= 7.0, < 9.0` (Rails 7 + 8); community-driven support: gem does not gatekeep on minor/patch beyond the CI-verified floor (V.59)
- De-facto target versions: `graphql ~> 2.3.x`, Rails `7.2.x` — CI "current 2.x" job must cover 2.3.x (V.60)
- `graphql-batch` is a known co-dependency — DataLoader batching is field-resolution-time; no interaction with `ControllerConcern` argument coercion; coexistence undocumented (V.61)
- `inertia_graphql` is a known co-dependency — controllers may include both `InertiaRails::ControllerHelpers` and `ControllerConcern`; this co-usage pattern is undocumented (V.62)
- `graphql-rails_logger` — query execution logging, no interaction with argument derivation
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
- Language purity: no language B syntax embedded inside language A files — shell stays in `.sh`, XML in `.xml`, large data in `.yml`/`.json`; interpolation via `.erb`; applies to all file types in the repo (Ruby, YAML, Nix, etc.) (V.46)

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
V.7   Unknown name in `required`/`optional`/`fields` raises `ConfigurationError` with full candidate list; unknown override opt raises with `DidYouMean::SpellChecker` suggestion — did_you_mean scoped to override opts only (T.7)
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
V.46  Language purity: no language B syntax embedded in language A files across the whole repo — shell in `.sh`, XML in `.xml`, large data in `.yml`/`.json`, interpolation via `.erb`; known violations: CI `run:` blocks, `flake.nix` shellHook, `lefthook.yml` run entries (T.59)
V.47  Trust boundary documented: pick blocks + argument declarations are always developer-controlled; HTTP `params` values are user-controlled; the gem never executes user-supplied code (T.60)
V.48  `to_unsafe_h` bypass of `ActionController::Parameters` is intentional and safe — `validate_input` + `coerce_input` are the actual validation gate; this assumption is documented in `USAGE.md` and `docs/SECURITY_HARDENING.md` (T.60)
V.49  `class_exec(&block)` in `evaluate_resource_scope_block` receives only developer-authored blocks — never constructed from or influenced by user input; documented invariant (T.60)
V.50  Dependabot configured for `Gemfile`/gemspec dependency updates (T.62)
V.51  Trusted Publishing (Sigstore, `rubygems_mfa_required: true` already set) configured before first `gem push` (T.63)
V.52  Thread-safety scope documented: gem class-level registries are not protected by Mutex; concurrent class loading must happen before requests start (Zeitwerk eager load in production); limitation explicit in docs (T.68)
V.53  `graphql_argument_input` override path tested — a controller subclass returning custom input exercises the full coercion pipeline with non-default input source (T.69)
V.54  `argument_namespace` inheritance tested — subclass controller inherits namespace from superclass without redeclaring it (T.70)
V.55  `resource_arguments` + `arguments_from` combo tested — resource scope with a derivation source (ObjectType or sibling) exercises both coercion paths together (T.71)
V.56  camelCase wire format tested — HTTP params with camelCase keys (`amountCents`) coerce correctly to snake_case argument hash (`amount_cents`) via `deep_stringify_keys` path (T.72)
V.57  `rake release` guarded — gemspec `allowed_push_host` set or `bundler/gem_tasks` removed until publish-ready; no accidental RubyGems push possible (T.73)
V.58  `DerivationResolutionGuard.in_progress` reset between spec examples — `around` hook or equivalent ensures no state leaks across tests in random order (T.74)
V.59  Rails 7 + 8 both supported — gemspec `activesupport/actionpack/activerecord >= 7.0, < 9.0` (current `~> 7.0` blocks Rails 8 installation); CI matrix covers both; community-driven: gem does not gatekeep on minor/patch; newer versions are best-effort until CI confirms (T.75)
V.60  CI "current graphql 2.x" job covers graphql 2.3.x — primary consumer pinned to 2.3.23; `NullQueryContext` `#warden` path handles 2.1–2.3.x (already verified); upgrade to 2.4+ activates `#types` path automatically via existing dual-path impl (T.76)
V.61  `graphql-batch` coexistence documented in `USAGE.md` — DataLoader batching is field-resolution-time; `ControllerConcern#arguments` coercion is request-param-time; no interaction between the two (T.77)
V.62  `inertia_graphql` co-usage pattern documented in `USAGE.md` — known real-world pattern: controller includes both `InertiaRails::ControllerHelpers` and `ControllerConcern`; `arguments` available alongside Inertia rendering (T.77)
V.63  Review artifacts (`REPORT.md`, root `SPEC.md`) excluded from gem package — gemspec `files` reject filter updated (B.10) (T.78)
V.64  Gemspec declares standard metadata URIs: `changelog_uri` `documentation_uri` `bug_tracker_uri` (B.11) (T.79)
V.65  `check_known_candidate!` error includes corrective action hint — "Use pick.required/optional/fields :name to select it" alongside available names list (V.43 partial) (T.80)
V.66  Ruby version matrix CI-ready — gemspec floor `>= 3.1`; CI currently pins 3.4 (nixpkgs); post-release matrix adds 3.x and eventually 4.x as community-driven (T.81)

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
| T.7  | ~      | Unknown-name `ConfigurationError` in `PickDsl::Base` — done for override opts (did_you_mean); field-name selection uses available_names_list, not did_you_mean; V.7 corrected (B.7), T.67 resolves |
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
| T.47 | .      | Independent code review of `ControllerConcern` param-parsing (flagged in security review, PR #28)       |
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
| T.59 | .      | Language purity audit across all repo files (V.46): extract CI `run:` shell blocks to `.sh`, `flake.nix` shellHook to `.sh`, `lefthook.yml` run entries to `.sh`; audit Ruby + spec files for embedded non-Ruby syntax |
| T.60 | .      | Write `docs/SECURITY_HARDENING.md`: threat model, trust boundary (V.47), `to_unsafe_h` rationale (V.48), `class_exec` assumption (V.49), known deliberate internals (`instance_variable_set`, `send(:allow_sibling_sources!)`) |
| T.61 | .      | Add `to_unsafe_h` safety rationale to `USAGE.md` — consumers must understand why strong-params bypass is safe here |
| T.62 | .      | Configure Dependabot for `Gemfile`/gemspec (V.50)                                                               |
| T.63 | .      | Configure Trusted Publishing (Sigstore) on RubyGems.org before first `gem push` (V.51)                         |
| T.64 | .      | Rename `ArgumentParsingError` → `ArgumentCoercionError` (B.1) — public API, pre-release window; update all references in lib/, spec/, docs/ |
| T.65 | .      | Vocabulary standardization (B.2–B.5): "inline" not "standalone"/"top-level" for declarations; "flat" for wire shape; differentiate "resolve" overloads in docs; "derivation source" canonical; timing language "class load time" vs "resolution time" |
| T.66 | .      | Amend V.1: `MissingInputTypeError < ConfigurationError` is raised at request time by design — V.1 "ConfigurationError load-time only" is factually wrong; note the exception (B.6) |
| T.67 | .      | Resolve B.7: decide whether to add `did_you_mean` to `check_known_candidate!` for field-name selection, or confirm available_names_list is the intended pattern and close V.7 as corrected |
| T.68 | .      | Document thread-safety scope (V.52, B.8): add explicit note to `docs/SECURITY_HARDENING.md` + `USAGE.md` that class-level registries are not Mutex-protected; safe only when class loading completes before concurrent access begins |
| T.69 | .      | Add spec for `graphql_argument_input` override — subclass overrides method, verify custom input flows through coercion (V.53) |
| T.70 | .      | Add spec for `argument_namespace` inheritance — subclass controller inherits namespace from base class (V.54) |
| T.71 | .      | Add spec for `resource_arguments` + `arguments_from` combo — resource scope with ObjectType derivation source (V.55) |
| T.72 | .      | Add spec for camelCase wire format — params with camelCase keys coerce to snake_case hash via `deep_stringify_keys` path (V.56) |
| T.73 | .      | Guard `rake release` (B.9, V.57): add `spec.metadata['allowed_push_host']` to gemspec or remove `bundler/gem_tasks` from Rakefile until RubyGems publish is intentional |
| T.74 | .      | Add `around` reset for `DerivationResolutionGuard.in_progress` in `derivation_resolution_guard_spec.rb` — prevent state leak across examples in random order (V.58) |
| T.75 | .      | Broaden Rails support to 7 + 8 (V.59): change gemspec `~> 7.0` → `>= 7.0, < 9.0` for activesupport/actionpack/activerecord; add `gemfiles/rails_8.gemfile` to CI matrix targeting Rails 7.2.x + Rails 8; update `docs/SPEC.md` §1.2 + `USAGE.md` |
| T.76 | .      | Verify CI "current graphql 2.x" job runs against >= 2.3.x (V.60) — confirm gemfiles/graphql_2.1.gemfile floor + current Gemfile covers 2.3.x range; document target graphql version in `docs/SPEC.md` §1.2 |
| T.77 | .      | Document `graphql-batch` coexistence (V.61) and `inertia_graphql` co-usage pattern (V.62) in `USAGE.md` — these are real-world integration patterns and a primary motivation for the gem |
| T.78 | .      | Exclude review + dev-env files from gem package (B.10, V.63): add `REPORT.md` `SPEC.md` `flake.nix` `flake.lock` `lefthook.yml` `gemfiles/` to gemspec `files` reject filter |
| T.79 | .      | Add standard gemspec metadata (B.11, V.64): `changelog_uri` `documentation_uri` `bug_tracker_uri` |
| T.80 | .      | Add corrective action hint to `check_known_candidate!` error (V.65): "Use pick.required/optional/fields :name to include it" alongside the available names list |
| T.81 | .      | Ruby version matrix (V.66): document community-driven support policy for Ruby 3.x+; gemspec floor stays `>= 3.1`; post-release CI matrix adds 3.x range; Ruby 4 tracked as future milestone, not a release blocker |
| T.82 | .      | Scrub internal project/path references from `AGENTS.md`: `../oyster/.rubocop_standard.yml` path, `Oyster/*` custom cops mention, `Oyster's OSS release policy` — replace with generic descriptions; no internal project names in a public repo |

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
| B.1 | `ArgumentParsingError` names the operation "parsing"; every other use in code + docs calls it "coercion" (`coerce_input`, `coerce_request_arguments`, `ArgumentCoercionError` would be correct) — inconsistent public API name | Rename to `ArgumentCoercionError` before first release (pre-release window, breaking change acceptable now); add alias + deprecation warning if needed — T.64 |
| B.2 | "inline", "standalone", "flat", "top-level" used interchangeably for non-derived `argument` declarations — no single canonical term | Standardize: "inline" for the declaration concept; "flat" for wire shape (vs "nested"); drop "standalone" and "top-level" for this concept — T.65 |
| B.3 | `resolve` overloaded across 4 distinct operations: (a) engine execution (`FieldDerivation.resolve`), (b) class-level trigger (`resolve_all!`), (c) sibling lookup (`resolve_sibling_arguments`), (d) graphql-ruby field resolution — ambiguous in docs | Differentiate in docs/prose: "derive" or "run" for (a); "resolve" for (b); "look up" for (c); keep graphql-ruby's own "resolve" for (d) — T.65 |
| B.4 | "composable source" (§8.1 ControllerConcern) vs "derivation source" (§4/§5/§6/§7) — same concept, two names | Use "derivation source" everywhere; define "composable source" only if the composability aspect is specifically relevant — T.65 |
| B.5 | Timing language: "class load time", "load time", "at load time", "resolution time" mixed for the same events | Canonical: "class load time" for Ruby class body execution; "resolution time" for explicit `resolve_all!`/`resolve_derivation!` call — T.65 |
| B.6 | V.1 states "ConfigurationError load-time only — never at request time" but `MissingInputTypeError < ConfigurationError` is raised at request time (`controller_concern.rb:433`); intentional (programming error surfaced on first action exercise) but V.1 is factually wrong as written | Amend V.1 to note the exception — T.66 |
| B.7 | V.7 claimed `DidYouMean::SpellChecker` fires for unknown names in `required`/`optional`/`fields`; implementation applies it only to unknown override opts (`raise_unknown_override_opt_error`); unknown field names get `available_names_list` (all candidates) instead — V.7 overstated; T.7 was marked `x` prematurely | Corrected V.7 to match implementation; T.67 decides whether to extend did_you_mean or leave available_names_list as the pattern |
| B.8 | Six class-level mutable structures have no `Mutex`: `DerivationResolutionGuard.@in_progress`, `DerivableInputObject/ObjectType.@included_classes`, `ArgumentSchema.@schemas`, `ActiveRecordMapper.@enum_cache`, `ControllerConcern.@own_action_input_objects`; concurrent class loading (Puma boot, Zeitwerk lazy autoload) is a real race window; no documentation of this limitation | Either add `Mutex` protection or explicitly document "not thread-safe during concurrent class loading" — T.68 |
| B.9 | `Rakefile` includes `bundler/gem_tasks` (provides `rake release`); gemspec has no `allowed_push_host` guard; `rake release` would push to rubygems.org unconditionally if credentials present — accidental-publish risk while gem name is unfinalized | Add `spec.metadata['allowed_push_host']` guard or remove `bundler/gem_tasks` until publish-ready — T.73 |
| B.10 | `REPORT.md` + root `SPEC.md` (review artifacts) are tracked by git → `spec.files` via `git ls-files` includes them → review artifacts would ship to gem consumers on `gem push`; `flake.nix` `flake.lock` `lefthook.yml` `gemfiles/` also ship unnecessarily | Add review artifacts + dev-env files to gemspec `files` reject filter — T.78 |
| B.11 | Gemspec missing standard RubyGems metadata: `changelog_uri` `documentation_uri` `bug_tracker_uri` — these populate rubygems.org gem page and are expected by standard tooling | Add to gemspec `spec.metadata` — T.79 |
| B.12 | NOTICE file still declares `~> 7.0` for Rails deps; AGENTS.md rule: "update NOTICE in same PR as any gemspec dependency change"; T.75 broadens those constraints — NOTICE must update in the same PR | Update NOTICE when T.75 lands — T.75 dependency |

---

§P POTENTIAL

| ID  | Idea                              | Description                                                                                                                                                                  |
|-----|-----------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| P.1 | Merge Derivable twin modules      | `DerivableInputObject` + `DerivableObjectType` share ~70% logic (`included_classes`, `clear!`, `resolve_all!`, `resolve_derivation!`, cycle guard, collision check). A shared `Derivable` base mixin would DRY this. Tradeoff: adds abstraction layer + meta-programming; current duplication is explicit and readable. Defer until a third Derivable type appears or maintenance cost is felt. |
| P.2 | Ruby 4 compatibility              | Gemspec floor `>= 3.1`; dev shell pins 3.4; post-release CI matrix covers 3.1 + 3.4 + latest 3.x. Ruby 4 is not a release blocker. Risks when it arrives: `did_you_mean` stdlib changes, `frozen_string_literal` behavior, graphql-ruby's own Ruby 4 support. No code changes needed now — no 3.x-specific syntax in use. Track via CI matrix addition once Ruby 4 is stable in nixpkgs. |
