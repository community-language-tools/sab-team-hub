# Changelog

All notable changes to this project are recorded here.

## [Unreleased]

### Added
- The engine, in `src/SAB-Team-Hub.ps1`, and its user-facing text in `languages/`. Carried
  over from an existing deployment and made deployment-neutral: the team name, and the word
  that authorizes deleting central files, now come from configuration instead of being
  fixed in the code.
- `tests/Invoke-Tests.ps1 -RepoRoot` assembles a Hub from this repository's own layout, so
  the same suite runs against both an installed deployment and the code here.

### Changed
- `config/team.example.json` and `config/users.example.json` now match the schema the
  engine actually reads. They previously described fields that did not exist.
- Two places in the engine chose their wording by testing which language was active. Both
  now read the text from `languages/`, as the architecture requires.

- Characterization test suite (Pester): authorized deletion of central files, and lock
  ownership. Both parameterised on the code under test, so the same tests run against an
  existing deployment and against this repository's own code.
- Repository skeleton: folder structure, `.gitignore`, MIT `LICENSE`, `README.md`,
  `CONTRIBUTING.md`, `AGENTS.md`/`CLAUDE.md`.
