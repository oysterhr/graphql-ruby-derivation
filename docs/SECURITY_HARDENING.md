# Security Hardening Plan

Status: living document — updated as hardening work progresses. See `SPEC.md §T` (T.60–T.63) for task tracking.

---

## Threat Model

This is a **library gem**, not an application. It has no network access, stores no state, and handles no authentication. The meaningful attack surface is narrow:

| Surface | User-controlled? | Gate |
|---|---|---|
| HTTP request params (`params`) | Yes | graphql-ruby `validate_input` + `coerce_input` |
| Pick blocks / argument declarations | No — developer-authored only | N/A (trust boundary) |
| Schema definitions (ObjectType, InputObject, Mutation) | No — developer-authored only | N/A |
| `graphql_argument_input` override | No — developer-authored only | N/A |

**Trust boundary:** Everything that comes from application code (pick blocks, `derive_from` declarations, `argument` DSL calls, `resource_arguments` blocks) is developer-controlled and trusted. HTTP `params` values are the only user-controlled input the gem ever touches, and they pass through graphql-ruby's own type coercion and validation layer before the application sees them.

---

## Already Hardened

| Item | How | Where |
|---|---|---|
| CI token permissions | `permissions: contents: read` (least-privilege) | `.github/workflows/ci.yml` |
| Third-party action supply chain | All actions pinned to commit SHAs | `.github/workflows/ci.yml` |
| Vulnerability disclosure policy | Private reporting via GitHub + email | `SECURITY.md` |
| Secret history scan | `gitleaks --log-opts="--all"` across all 69 commits — zero leaks | PR #28 |
| RubyGems MFA | `rubygems_mfa_required: true` | `graphql-ruby-derivation.gemspec` |
| Branch protection | ≥1 review required on `main` | GitHub settings |
| No personal names/internal refs | Stripped from public-facing files | PR #28 |

---

## Active Concerns

### SC1 — `to_unsafe_h` bypass of `ActionController::Parameters`

`ControllerConcern#graphql_argument_input` calls `params.to_unsafe_h` before passing input to graphql-ruby coercion. This intentionally bypasses Rails' `ActionController::Parameters` permit model.

**Why this is safe:** `ActionController::Parameters` is an allowlist-by-omission model — it raises on mass assignment of unpermitted keys. This gem's coercion pipeline does the equivalent and more: `raw_input.slice(*input_object.arguments.keys)` drops unknown keys before validation, then graphql-ruby `validate_input` rejects structurally invalid input, then `coerce_input` type-checks and coerces each value. Unknown keys are silently dropped (mirrors `params.permit` semantics).

**What `to_unsafe_h` is needed for:** `ActionController::Parameters` is not a Hash and does not implement the full Hash interface that graphql-ruby's `InputObject#coerce_input` expects (`dig`, recursive key access). `to_unsafe_h` converts it to a plain Hash without triggering the permit model — safe here because the permit equivalent happens immediately after in the slice step.

**Action:** Document this rationale in `USAGE.md` (T.61). The `graphql_argument_input` override point lets consumers substitute their own input source if their wire format differs.

---

### SC2 — `class_exec(&block)` in `evaluate_resource_scope_block`

`ControllerConcern` evaluates `resource_arguments` blocks via `class_exec(&block)`, running the block in the context of the controller class. This allows `argument`/`arguments_from` calls inside the block to register on the resource scope rather than the action.

**Invariant this relies on:** The block is always written by the developer in the controller class body — it is never constructed from or influenced by user-supplied input. If an application were to dynamically construct and pass a user-influenced Proc to `resource_arguments`, that would be an application-level vulnerability, not a gem vulnerability.

**Action:** Document this assumption explicitly in `USAGE.md` and assert it in `docs/SPEC.md` (V.49, T.60).

---

### SC3 — `instance_variable_set(:@owner, ...)` on graphql-ruby internals

`DerivableInputObject#register_derived_argument` sets `@owner` on `GraphQL::Schema::Argument` instances via `instance_variable_set`. This bypasses the read-only `owner` accessor.

**Why necessary:** `ArgumentDerivation` builds arguments unattached (`owner: nil`) so the engine stays decoupled from the registration target. graphql-ruby's coercion path calls `owner.validate_directive_argument` during `coerce_input`, so `@owner` must be set before coercion runs. No public setter exists; rebuilding the argument would drop configured options.

**Security impact:** Zero. The values written are gem-internal class objects (the InputObject class), not user input. No user data ever flows through this code path.

---

### SC4 — `send(:allow_sibling_sources!)` private method access

`ControllerConcern` calls `input_object.send(:allow_sibling_sources!)` on generated InputObject classes to opt them into Symbol (sibling) sources before calling `derive_from`.

**Why private:** `allow_sibling_sources!` is a deliberate escape hatch for the ControllerConcern's generated classes only. User-defined `DerivableInputObject` subclasses must not call it — Symbol sources are meaningless outside the controller action registry context (SPEC §11.1). Keeping it private enforces this without needing runtime checks on every `derive_from` call.

**Security impact:** Zero. Only called on gem-generated, anonymous InputObject classes, never on user-defined classes and never with user input.

---

## Pending Hardening

| Item | Task | Blocker |
|---|---|---|
| Dependabot for gem dependencies | T.62 | None |
| Trusted Publishing (Sigstore) on RubyGems.org | T.63 | RubyGems name not final (T.48) |
| `ControllerConcern` independent code review | T.47 | Needs human with Rails Controller context |
| `to_unsafe_h` rationale in `USAGE.md` | T.61 | None |
| GitHub secret scanning + private vuln reporting | T.49 | OSS flip (M.4) |

---

## Out of Scope

- Rate limiting, request size limits — application responsibility, not gem responsibility
- Authentication / authorisation — not in scope for this gem
- Content Security Policy, CSRF — application/Rails responsibility
- Multi-tenant data isolation — application responsibility
