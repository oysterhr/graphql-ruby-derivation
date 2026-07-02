# graphql-ruby-derivation

Composable, independently requireable utilities for deriving `graphql-ruby` arguments and fields
from existing types, instead of hand-writing (and re-writing, and drifting) the same fields twice.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **⚠️ Experimental.** This gem is early-stage and not yet battle-tested in production. The API
> may change without notice before a stable release. Use at your own risk.
>
> All code in this repository — implementation, tests, and documentation — was written with
> agentic coding assistance (AI coding agents operating with human review and direction), not
> hand-written line-by-line. Review it accordingly before depending on it.

## Install

```ruby
# Gemfile
gem 'graphql-ruby-derivation'
```

```
bundle install
```

## What it does

- Derive `GraphQL::Schema::Argument`s for a mutation's InputObject from an existing ObjectType,
  InputObject, or sibling controller action.
- Derive `GraphQL::Schema::Field`s for an ObjectType from another ObjectType or an ActiveRecord
  model.
- Optional Rails controller integration (`argument`/`arguments_from`/`arguments`) and an
  ActiveRecord column-to-GraphQL-type adapter.

Three independently requireable layers — use only what you need:

| Require | Adds |
|---|---|
| `graphql/derivation` | Core: Pick DSL, derivation engines, `DerivableInputObject`/`DerivableObjectType` |
| `graphql/derivation/rails` | `ControllerConcern`, `ArgumentSchema` |
| `graphql/derivation/rails/active_record` | ActiveRecord column adapter |

See **[USAGE.md](USAGE.md)** for a getting-started guide with runnable examples, or
**[USAGE.CAVEKIT.md](USAGE.CAVEKIT.md)** for a token-minimized reference meant to be fed to an
AI coding agent.

## Documentation

- [`docs/SPEC.md`](docs/SPEC.md) — full design spec, the source of truth for behavior.
- [`USAGE.md`](USAGE.md) — human getting-started guide.
- [`USAGE.CAVEKIT.md`](USAGE.CAVEKIT.md) — agent-oriented compressed reference, generated from
  `USAGE.md`.
- [`CHANGELOG.md`](CHANGELOG.md) — notable changes, [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## Developing

Dev environment is [Nix](https://nixos.org/) + [direnv](https://direnv.net/) — no system
Ruby/rbenv/asdf required. See `docs/SPEC.md` §12 for the full rationale.

```
direnv allow        # once, after clone — provisions the dev shell via flake.nix
bundle install
bundle exec rspec
bundle exec rubocop
```

Git hooks (via [lefthook](https://github.com/evilmartians/lefthook)) run rubocop on commit and
the full test suite on push.

Contribution/process conventions (commit style, PR scope, how the spec and docs relate) live in
[`AGENTS.md`](AGENTS.md).

## License

[MIT](LICENSE).
