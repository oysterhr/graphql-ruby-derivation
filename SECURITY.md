# Security Policy

## Supported Versions

This gem is currently **experimental** (`0.x`, see the README). It is not yet published to
RubyGems and has no versioned releases; consumers install directly from `main`. Security fixes
land on `main`, and there is no backport policy while the gem is pre-1.0.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for a security vulnerability.

Report it through Oyster's [Responsible Disclosure Program](https://www.oysterhr.com/trust/rdp-program)
submission form. For questions about the disclosure process itself, contact
[infosec@oysterhr.com](mailto:infosec@oysterhr.com). Please include:

- A description of the vulnerability and its potential impact.
- Steps to reproduce it (a minimal script is ideal, and this gem has no runtime dependency on a
  real Rails app or database; see `docs/SPEC.md` §10).
- Any suggested remediation, if you have one.

We'll acknowledge reports within a few business days and coordinate disclosure with you. Please
give us a reasonable amount of time to address the issue before any public disclosure.

## Scope

Exploiting a vulnerability against Oyster's production surfaces (`*.oysterhr.com`) falls under the
[Responsible Disclosure Program](https://www.oysterhr.com/trust/rdp-program), including its
[safe-harbor and bounty terms](https://legal.oysterhr.com/mpc-terms/rdp-terms). This repository is not currently a named target of that program, so
reports about the gem in isolation are handled on a best-effort, coordinated-disclosure basis and
are not eligible for bounty awards.
