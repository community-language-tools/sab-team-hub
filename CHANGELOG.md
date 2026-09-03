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
- `src/New-TeamProject.ps1` — creates a central project on shared storage. The engine can
  receive, send and lock a project but never could create one; every deployment so far had
  its central project built by hand. Without this a new team could not start at all.
- Tests for provisioning, including the check that matters: a project the script creates is
  one the real engine accepts. They are skipped, not silently passed, when the code under
  test is a deployment that has no provisioning script.
- `src/Install-TeamHub.ps1` — installs the Hub onto one computer from this repository,
  assembling `src/`, `languages/` and the prepared configuration into the single folder the
  engine expects. It validates the chosen member against the team list and the chosen
  language against what is actually translated, so neither is a fixed list in code, and it
  can optionally publish the team list to the shared drive so it is maintained in one place.
- `src/SAB Team Hub.cmd` — a launcher, so a member starts the Hub without a command line.
- Tests for installation, which run the real engine out of what was installed.
- Characterization test suite (Pester): authorized deletion of central files, and lock
  ownership. Both parameterised on the code under test, so the same tests run against an
  existing deployment and against this repository's own code.
- Repository skeleton: folder structure, `.gitignore`, MIT `LICENSE`, `README.md`,
  `CONTRIBUTING.md`, `AGENTS.md`/`CLAUDE.md`.

### Changed
- `config/team.example.json` and `config/users.example.json` now match the schema the
  engine actually reads. They previously described fields that did not exist.
- Two places in the engine chose their wording by testing which language was active. Both
  now read the text from `languages/`, as the architecture requires.
- `tests/Invoke-Tests.ps1 -RepoRoot` now installs every script in `src/`, not only the one
  under test, because that is what an installer does.
