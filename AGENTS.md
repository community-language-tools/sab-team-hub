# Instructions for AI agents

## What this project is

SAB Team Hub lets a Scripture App Builder translation team collaborate over ordinary shared
storage (pCloud, Google Drive), using a lock mechanism that prevents two people from
overwriting the same project files.

## Absolute rules

- Never work directly on `main`. Always create a branch and a pull request.
- Never put real team names, real project codes or real paths into source code, tests,
  examples or comments. Use invented names (see `demo-data/`).
- `config/team.json`, `config/users.json` and `config/projects.json` exist only locally and
  are listed in `.gitignore` — never commit them. Work with the `*.example.json` variants.
- Never commit `.env`, keys or passwords.
- Do not remove or change existing functionality unless explicitly asked to.
- Tests are never edited to make them pass after code has been rewritten. A failing test
  after a rebuild means the code is wrong, not the test.
- This is a generalised offshoot of an existing production deployment that continues to
  exist separately. Never modify files outside this repository.

## Before you open a pull request

- Run the tests. If they are red, do not open a PR — report what is going wrong instead.
- Keep the change small: 1-5 files where possible.
- Write the PR description in **plain English, without jargon**. The reviewer is not a
  programmer. Describe: what the problem was, what you changed, and how the reviewer can
  see that it works.
- Say so explicitly if you are unsure whether something falls outside the task. Asking is
  better than assuming.

## Architecture

The application code is language-neutral. All user-facing text comes from
`languages/*.json` and is loaded via a language parameter. Code should never know which
language is selected, beyond that single lookup.

- `src/` — generic application code (PowerShell)
- `config/` — example configuration (`*.example.json`, may be committed); real
  configuration (`team.json`, `users.json`, `projects.json`) stays local, never in Git
- `languages/` — user-facing text per language (en/fr/nl). Language-specific additions
  belonging to one individual deployment do not belong in this repository.
- `demo-data/` — synthetic test data with invented names, may be committed
- `docs/` — documentation
- `tests/` — automated tests (Pester)

## Platform

Windows, PowerShell 5.1. The goal is removing *accidental* machine dependencies —
hardcoded drive letters, path assumptions — not abstracting over operating systems, which
would weaken filesystem-level guarantees this tool depends on.

## Tests

_To be written (Pester, running in GitHub Actions on `windows-latest`)._
