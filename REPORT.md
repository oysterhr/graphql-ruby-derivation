# Review Report — graphql-ruby-derivation

**Branch:** `review/oss-spec-completion` · **Base:** `docs/oss-release-policy-compliance` (PR #28)
**Date:** 2026-07-09
**Purpose:** Independent peer review required by project OSS release policy before making the repo public.

---

## Methodology

1. Distilled implementation into root `SPEC.md` (caveman/ck format) — 35 behavioural invariants, 50 initial tasks.
2. Ran `/ck:check` against all §V invariants — evidence-first, grep-based.
3. Vocabulary analysis across all text-bearing files (lib/ error messages, spec strings, all docs).
4. Security threat model + hardening assessment.
5. Quality gate anchors added for coverage, complexity, language purity, performance, usability.

`docs/SPEC.md` (the original verbose spec) was **not modified** — preserved as reference.

---

## Confirmed Good

The core implementation is solid. All 34 behavioural invariants (V.2–V.34, V.41–V.42) confirmed HOLD:

- Error hierarchy correctly separates `ConfigurationError` (load-time) from `ArgumentParsingError` (request-time) — with one nuance, see §Findings
- Cross-mixin cycle detection (`DerivationResolutionGuard`) works for both `DerivableInputObject` and `DerivableObjectType`
- All Pick DSL validations present and correct (empty block, cross-bucket duplicate, override-on-unselected, unknown candidate)
- Connection-type + list-of-Object exclusions implemented in both mappers
- `NestedObjectCandidate` deferred eligibility check correct
- `ArgumentDerivation` + `FieldDerivation` handle all source types, unsupported sources raise immediately
- Case 3 resolver detection correctly uses `respond_to?` not `method_defined?` (singleton methods)
- AR adapter: EXCLUDED_COLUMNS, lazy type resolution, null inference, FK override, enum cache with `equal?` identity check — all correct
- `ControllerConcern`: memoization, unknown-key slicing, MissingInputTypeError, ArgumentParsingError wrapping, sibling DFS cycle detection — all correct
- `ArgumentSchema`: per-namespace cache, disposable synthetic query root (not `extra_types`), graphql_name-based reload dedup — all correct
- `NullQueryContext` dual-path (`#warden` 2.1–2.3, `#types` 2.4+) — correct
- `reset_for_reload!` clears all four registries
- `allow_sibling_sources!` escape hatch correctly scoped to ControllerConcern-generated classes only
- Security: `to_unsafe_h` bypass intentional and safe; `class_exec` bounded to developer blocks; `instance_variable_set` on `@owner` necessary and bounded; `send(:allow_sibling_sources!)` scoped

CI already hardened (PR #28): `permissions: contents: read`, SHA-pinned actions, SECURITY.md, gitleaks clean, `rubygems_mfa_required: true`, branch protection.

---

## Findings — Must Fix Before OSS Sign-off

### F1 · Vocabulary: `ArgumentParsingError` naming (B.1)

**Severity:** Medium — public API, breaking rename; pre-release window is now.

The error class is named `ArgumentParsingError` but the operation is called "coercion" everywhere in code and docs (`coerce_input`, `coerce_request_arguments`, "Could not coerce arguments for..."). The name misleads — "parsing" implies a syntax error; "coercion" is the correct term for graphql-ruby's type-coercion pipeline.

**Fix:** Rename to `ArgumentCoercionError` before first release. All references in `lib/`, `spec/`, and docs must update.

---

### F2 · Spec error: `docs/SPEC.md` §5.3 uses `method_defined?` (T.36)

**Severity:** Low — spec only, no code bug.

`docs/SPEC.md` §5.3 states the engine detects Case 3 via `source.method_defined?("resolve_#{field_name}")`. The implementation correctly uses `source.respond_to?(...)`. `method_defined?` only detects instance methods; graphql-ruby resolver methods are singleton/class methods, so `method_defined?` always returns false for them. The code already has a comment documenting this deviation; the spec needs correcting.

---

### F3 · Invariant imprecision: V.1 MissingInputTypeError timing (B.6)

**Severity:** Low — spec imprecision, not a code bug.

V.1 states "`ConfigurationError` at class load time only — never at request time." `MissingInputTypeError` inherits `ConfigurationError` but is raised at request time (when `arguments` is first called on an action with no declared arguments). This is intentional and documented in the code comments — it is semantically a programming error (config mistake), so `ConfigurationError` is the right superclass — but V.1 as written is factually wrong.

**Fix:** Amend V.1 to note the exception: `MissingInputTypeError` is a `ConfigurationError` raised at request time (programming error surfaced on first exercise of the action).

---

### F4 · Invariant imprecision: V.7 `did_you_mean` scope (B.7)

**Severity:** Low — spec imprecision, T.7 marked done incorrectly.

V.7 claims `did_you_mean` fires for unknown names in `required`/`optional`/`fields`. The implementation applies `DidYouMean::SpellChecker` only to unknown **override opts** (`raise_unknown_override_opt_error`). Unknown **field names** in selection methods produce a list of all available candidates (`available_names_list`) — arguably better UX, but does not match the V.7 claim. T.7 is marked `x` but the V.7 claim does not hold.

**Fix:** Either add `did_you_mean` to `check_known_candidate!`, or narrow V.7 to "override opts only, field names get full candidate list."

---

### F5 · Missing spec files — 1-to-1 coverage not met (V.36, T.52)

**Severity:** Medium — quality gate.

Four lib files have no dedicated spec:
- `lib/graphql/derivation/pick_dsl/base.rb` → no `pick_dsl/base_spec.rb`
- `lib/graphql/derivation/version.rb` → no `version_spec.rb`
- `lib/graphql/derivation/rails/errors.rb` → no `rails/errors_spec.rb`
- `lib/graphql/derivation/rails/active_record.rb` → no `rails/active_record_spec.rb`

`PickDsl::Base` is the most significant gap — it contains the core validation, override-opt checking, and `did_you_mean` logic. `pick_dsl/arguments_spec.rb` and `pick_dsl/fields_spec.rb` exercise it indirectly but no direct unit tests exist for the shared base.

---

### F6 · No SimpleCov configuration (V.37, T.51)

**Severity:** Medium — quality gate.

`spec/spec_helper.rb` has no SimpleCov setup. No coverage is collected, no threshold enforced in CI. All available coverage types (line, branch, method) should be enabled at 100% minimum with CI failure.

---

### F7 · RuboCop Metrics incomplete (V.40, T.53)

**Severity:** Low — quality gate, not a correctness issue.

`.rubocop.yml` configures `Metrics/ClassLength` and `Metrics/ModuleLength` but is missing `Metrics/MethodLength`, `Metrics/ParameterLists`, `Metrics/CyclomaticComplexity`, `Metrics/PerceivedComplexity`. Sandi Metz limits (MethodLength: 5, ParameterLists: 4, Complexities: 4) are the preferred baseline; any current violations should be captured in `SPEC.md §D` as tracked debt rather than silently excluded.

---

### F8 · Language purity violations (V.46, T.59)

**Severity:** Low — hygiene.

Shell commands embedded in non-shell files:
- `.github/workflows/ci.yml`: `run: nix develop --command bash -c '...'` (4 occurrences)
- `lefthook.yml`: `run: bundle exec rubocop ...` and `run: bundle exec rspec`

Each should be a `.sh` script referenced from the YAML `run:` field. `flake.nix` shellHook is currently empty — no violation.

---

### F9 · No Dependabot configuration (V.50, T.62)

**Severity:** Low — supply-chain hygiene.

No `.github/dependabot.yml`. Gem dependencies (`Gemfile`/gemspec) receive no automated update PRs.

---

## Findings — Open Questions

### Q1 · `validates: required: { one_of: [...] }` with NullWarden (V.35, T.35)

Not confirmed or ruled out. The `one_of:` variant calls `context.types.arguments(owner)` to enumerate visible keywords. Whether `NullQueryContext#types` (which delegates to `warden.visibility_profile`) handles this correctly is untested. If it does not, this override option is silently broken and must be documented as unsupported.

### Q2 · ControllerConcern independent code review (T.47)

A prior security review (PR #28) explicitly flagged the Rails ControllerConcern param-parsing layer as needing a second set of eyes with Rails Controller context. This is a blocking item for M.3 (Correctness sign-off). Not covered by this review — needs a separate reviewer.

---

## Findings — docs/SPEC.md Gaps (tracked in §T T.36–T.45)

These are documentation gaps in the original spec, not code bugs. None are blockers for correctness; all should be fixed before calling the spec accurate.

| Task | Gap |
|------|-----|
| T.36 | §5.3: `method_defined?` → `respond_to?` |
| T.37 | §2: missing `Rails::MissingInputTypeError` + `Rails::ArgumentParsingError` |
| T.38 | §1.3: missing `derivation_resolution_guard.rb`, `pick_dsl/base.rb`, `rails/errors.rb` |
| T.39 | §5.1: source validation timing wrong for `DerivableObjectType` path |
| T.40 | §4.2: sibling source strips NonNull (not pure identity) |
| T.41 | §8.1: `graphql_argument_input` override point undocumented |
| T.42 | §6.3/§7.3: `clear!` undocumented |
| T.43 | §9.4: FK override only applies to int/bigint columns |
| T.44 | §10.2: fixture schema incomplete (`money_amount_type.rb`, `create_expense_mutation.rb`) |
| T.45 | §11.1 + §11.4: open questions resolved in implementation, not closed in spec |

---

## Modularization Notes

Two DRY opportunities identified (T.57–T.58):
- `source_name` helper duplicated verbatim in `ArgumentDerivation` + `FieldDerivation` → extract to shared utility
- `connection_type?` detection duplicated in `ObjectTypeToArgument` + `ObjectTypeToField` → extract to shared utility

One deferred potential (P.1): merging `DerivableInputObject` + `DerivableObjectType` (~70% shared logic) — deferred until a third Derivable type appears.

---

## Milestone Status

| Milestone | Status | Blocker |
|-----------|--------|---------|
| M.1 Implementation complete | ✓ done | — |
| M.2 Spec complete | ~ in progress | F5–F9, Q1, T.36–T.45 |
| M.3 Correctness sign-off | blocked | Q2 (ControllerConcern human review) |
| M.4 OSS release | blocked | M.2, M.3, T.48 (RubyGems name) |

---

## Sign-off Statement

The core implementation is **correct and well-structured**. The Pick DSL, derivation engines, mappers, DerivableInputObject/ObjectType, and ArgumentSchema all implement their specifications faithfully with good test coverage of the happy path and error cases.

**Blocking items before this reviewer can sign off (M.3):**
1. F1 — `ArgumentParsingError` rename (public API, now-or-never)
2. F5 — `PickDsl::Base` needs dedicated unit tests
3. F6 — SimpleCov must be configured and enforced
4. Q2 — ControllerConcern independent Rails-context review (separate reviewer required)

**Non-blocking but should complete before OSS (M.2):**
F2–F4, F7–F9, Q1, T.36–T.45, T.57–T.58

---

*Generated from `SPEC.md` on branch `review/oss-spec-completion`. See `SPEC.md §B`, `§T`, `§P` for machine-readable tracking.*
