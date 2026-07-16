# Security Policy

## Supported Versions

This gem is currently **experimental** (`0.x`, see the README) — there is no long-term support
window yet. Security fixes are applied to the latest release on `main`; there is no backport
policy while the gem is pre-1.0.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for a security vulnerability.

Instead, use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
feature on this repository ("Security" tab → "Report a vulnerability"), or email
[developers@oysterhr.com](mailto:developers@oysterhr.com) with:

- A description of the vulnerability and its potential impact.
- Steps to reproduce it (a minimal script is ideal — this gem has no runtime dependency on a
  real Rails app or database, see `docs/SPEC.md` §10).
- Any suggested remediation, if you have one.

We'll acknowledge reports within a few business days and keep you updated as we investigate and
address the issue. Please give us a reasonable amount of time to fix the issue before any public
disclosure.
