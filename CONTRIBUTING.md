# Contributing

Thanks for considering a contribution to `graphql-ruby-derivation`. This is a human-oriented
quick start; [`AGENTS.md`](AGENTS.md) is the full source of truth for repo conventions (and is
what AI coding agents working in this repo read first) — this file summarizes the parts that
matter most for an external contribution.

## Before you start

- Read [`docs/SPEC.md`](docs/SPEC.md) first — it's the source of truth for intended behavior.
  Any change to public behavior should update the spec in the same PR, not just the code.
- For anything larger than a small fix, please open an issue first to discuss the approach
  before writing code — this avoids spending effort on something that doesn't fit the project's
  scope or direction.

## Making a change

1. Fork the repo and create a branch off `main` (`main` is branch-protected — direct pushes
   aren't possible, all changes land via pull request).
2. Set up the dev environment: [Nix](https://nixos.org/) + [direnv](https://direnv.net/)
   (`direnv allow` after clone), or install Ruby >= 3.1 and Bundler yourself if you'd rather not
   use Nix. See `docs/SPEC.md` §12 for the full dev-environment rationale.
3. Make your change. Keep one logical change per commit and per PR where practical — e.g. don't
   bundle an unrelated bug fix into a feature PR.
4. Before opening a PR, both of these must pass clean:
   ```
   bundle exec rspec
   bundle exec rubocop
   ```
   New behavior needs test coverage, not just a happy-path check — see `docs/SPEC.md` §10 for
   this project's testing conventions.
5. Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`,
   `refactor:`, `test:`, `chore:`) for commit messages.
6. Update [`CHANGELOG.md`](CHANGELOG.md) (Keep a Changelog format) for any user-facing change —
   new public API, behavior change, or bug fix.
7. Open a pull request against `main` describing what changed and why.

## Reporting a bug or requesting a feature

Open a [GitHub issue](https://github.com/oysterhr/graphql-ruby-derivation/issues). For a bug,
include a minimal reproduction if you can — this gem has no runtime dependency on a real Rails
app or database (see `docs/SPEC.md` §10), so most bugs can be reproduced with a small, self
-contained script.

## Project status

This gem is marked **experimental** (see the README) — the public API may still change. It is
maintained by Oyster's engineering team; issues and pull requests are reviewed, but response
time isn't guaranteed.

## Code of conduct

Be respectful and constructive. Reports of unacceptable behavior can be sent to
[developers@oysterhr.com](mailto:developers@oysterhr.com).
