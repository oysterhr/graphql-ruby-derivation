# AGENTS.md

Instructions for AI coding agents (Claude Code, Cursor, Copilot, Aider, etc.) working in
`graphql-ruby-derivation`.

## What this repo is

Ruby gem. Spec lives at `docs/SPEC.md` — read it before touching code. SPEC.md is the source of
truth for design; this file is the source of truth for *how to work* in the repo.

Repo is a fresh scaffold as of 2026-06. No Gemfile/gemspec/rubocop/CI yet — early work is
bootstrapping the skeleton per SPEC.md §1.3, not just feature code.

## Core rule: ask before deciding ambiguous setup

SPEC.md leaves implementation details open (§11 "Open Questions" and gaps elsewhere — e.g. CI
shape, gemspec metadata, lint config). When scaffolding or hitting an undocumented decision:

- **Stop and ask** rather than guessing, for anything not pinned down in SPEC.md or this file.
- Once a decision is made (by the user, or recorded below), don't re-litigate it — follow it.
- Decisions made so far are recorded in this file. Update this file when new ones are made.

## Keep SPEC.md's status table current

SPEC.md opens with a "Table of Contents & Implementation Status" table (Specified / In Progress /
Implemented / N/A per section). Whenever you start or finish implementing part of the spec:

- Mark the relevant section **In Progress** when you open a PR for it.
- Mark it **Implemented** in the same PR that merges the implementation — don't leave this for a
  follow-up commit.
- If a PR only partially implements a section, leave it **In Progress** and say what's left in
  the PR description, rather than marking it Implemented early.

## Decisions on record

- **Gemspec authors:** `Oyster HR, Inc. Engineers`, email `developers@oysterhr.com` — matches the
  convention Legal and Oyster's `tabasco` gem settled on for OSS releases: a departmental
  name/email with "no chance of being decommissioned," not an individual's.
- **OSS release process:** every dependency declared in the gemspec is mirrored in `NOTICE`
  (name + license). Update `NOTICE` in the same PR as any gemspec dependency change — this is
  the artifact Legal asks for when reviewing a release for license-compatibility (MIT vs. any
  copyleft dependency). The gem is marked **experimental** (README + gemspec `summary`/
  `description`) until a stable release is cut; keep that wording in sync with reality rather
  than removing it prematurely. Oyster's OSS release policy (Engineering review + Legal
  coordination, pre-release security review, `CONTRIBUTING.md` requirement) also applies — see
  `CONTRIBUTING.md` for the contributor-facing side of it.
- **Not published to RubyGems yet, by choice:** deliberately deferred rather than blocking on it.
  The gem name isn't final (may change before a real release), and publishing early would mean
  reserving a name that might not stick. Consumers install directly from GitHub (README's
  Install section) in the meantime. Reserving the RubyGems name, enabling MFA on the owning
  account, and preferring Trusted Publishing over API keys are all deferred alongside it — revisit
  together once the name is settled, not piecemeal.
- **CI:** GitHub Actions (`.github/workflows/ci.yml`), runs `bundle exec rspec` and
  `bundle exec rubocop` on push/PR.
- **Lint:** rubocop + `rubocop-rspec` + `rubocop-performance`. Base ruleset mirrors
  `../oyster/.rubocop_standard.yml` (Oyster's general Ruby standards) — **not** `.rubocop_oyster.yml`
  or `.rubocop.yml`, since those carry Rails/anywhere-app-specific cops and custom cop files that
  don't apply to a standalone gem. Pull in generic Style/Layout/Naming/Lint/Performance/RSpec
  sections; skip Rails-specific and `Oyster/*` custom cops.
- **Commits:** Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
  One logical change per commit.
- **Changelog:** `CHANGELOG.md` in Keep a Changelog format, updated alongside any user-facing
  change (new public API, behavior change, bug fix).
- **Multi-tool support:** `CLAUDE.md` is a symlink to `AGENTS.md` (or thin pointer) so other
  tools that look for `CLAUDE.md` get the same instructions without duplication.
- **Dev environment:** Nix, via `flake.nix` + `direnv` (`use flake`) — not `shell.nix`/niv, not
  rbenv/asdf/system Ruby. Ruby pinned to **3.1** (the gemspec floor, not the newest available).
  Git hooks via `lefthook` (pre-commit: rubocop on changed files; pre-push: full rspec). Gems
  vendor to `vendor/bundle` (set via `bundle config set --local path`), not a shared gem path.
  CI provisions the same flake shell (via a Nix-installer action + `nix develop`) instead of
  `ruby/setup-ruby`, so CI and local dev share one toolchain definition. Full spec: SPEC.md §12.
- **Docs derivation:** three user-facing docs, each derived from SPEC.md (source of truth,
  never the reverse):
  - `README.md` — standard OSS front matter (license, install, dev setup, links out). No
    feature/API detail beyond a pitch — that lives in USAGE.md.
  - `USAGE.md` — human getting-started guide: problem statement, runnable examples, Pick DSL
    cheat-table, error glossary. Public-API-only — mirrors what SPEC.md documents as public,
    never introduces a fact SPEC.md doesn't already state.
  - `USAGE.CAVEKIT.md` — agent-oriented, token-minimized reference (method signatures, override
    allowlists, source-type support matrix, error hierarchy, the reload/cycle-detection
    footguns). **Mechanically generated from `USAGE.md`** via the `caveman:compress` skill
    (`/caveman:compress USAGE.md`) — never hand-edited independently, to prevent drift.
  - Sync rule: any PR that changes public API surface documented in SPEC.md (new/removed method,
    changed error hierarchy, changed Pick DSL override allowlist, etc.) updates `USAGE.md` in the
    same PR, then regenerates `USAGE.CAVEKIT.md` from it in the same commit — same discipline as
    the SPEC.md status table and CHANGELOG.md rules above. Internal-only changes (caching,
    private helpers) touch neither.

## Required before calling work done

Inside the nix/direnv shell (i.e. after `direnv allow`, or via `nix develop`):

```
bundle exec rspec
bundle exec rubocop
```

Both must pass clean. No skipping/disabling cops to make lint pass — fix the code, or if a cop
is genuinely wrong for this codebase, add a scoped exception with a comment explaining why
(see Oyster's own `.rubocop_oyster.yml` for the pattern: exceptions are file/cop-scoped with a
one-line reason, never blanket-disabled).

If asked to run these commands outside an interactive shell (e.g. scripted/non-direnv context),
wrap with `nix develop --command bash -c '...'` rather than relying on a system Ruby being
present — there isn't one to rely on.

## Code conventions

- Ruby >= 3.1 (per SPEC.md §1.1). `# frozen_string_literal: true` at the top of every file.
- Follow SPEC.md exactly for: file structure (§1.3), error hierarchy (§2), evaluation model
  (derive blocks stored unevaluated, resolved once — §3.1, §4.4, §5.4), and the
  `ConfigurationError`-at-load-time / hard-error-at-resolution-time split. Don't invent new error
  types outside `GraphQL::Derivation::*` without asking.
- No new runtime deps beyond what's in SPEC.md §1.2 without asking first.
- Rails/ActiveRecord code must stay behind `require` guards — core (`graphql/derivation`) must
  load and run with neither installed.

## Git workflow

`main` is branch-protected on GitHub (`oysterhr/graphql-ruby-derivation`) — direct pushes are
rejected (`GH013: Repository rule violations ... Changes must be made through a pull request`).
Always work on a feature branch and open a PR; never attempt `git push origin main` directly.

## Testing

- RSpec, no real Rails app, no DB connection (SPEC.md §10). Fixture types live in
  `spec/support/fixture_schema/`. AR tests stub `.columns`/`.defined_enums` directly.
- New code needs the unit/integration coverage SPEC.md §10.3/§10.4 calls for, not just
  happy-path specs.

## PR/commit scope

One spec section (or one coherent unit, e.g. "Pick DSL", "ArgumentDerivation engine") per
PR/commit where practical — don't bundle unrelated SPEC sections into one change.
