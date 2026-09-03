# src/

Generic application code.

- `SAB-Team-Hub.ps1` — the engine: identity, locking, receive, send, release, and the
  menu. It knows no team, no project code and no language; all three come from
  configuration and from `languages/`.

- `New-TeamProject.ps1` — creates a central project on shared storage, once, before a team
  starts. It writes the control file, the master copy and the first manifest that the
  engine then checks. Kept separate from the engine on purpose: inside the engine every
  write to shared storage happens while holding the project lock, and provisioning cannot
  honour that rule because no lock can exist before the project does. Keeping it out
  preserves the rule everywhere else.

The repository is deliberately not laid out like an installed Hub. Code lives here,
user-facing text in `languages/`, example configuration in `config/`; an installer brings
them together. `tests/Invoke-Tests.ps1 -RepoRoot '..'` assembles them the same way, so the
test suite exercises the real arrangement.
