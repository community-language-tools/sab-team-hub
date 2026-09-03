# src/

Generic application code.

- `SAB-Team-Hub.ps1` — the engine: identity, locking, receive, send, release, and the
  menu. It knows no team, no project code and no language; all three come from
  configuration and from `languages/`.

The repository is deliberately not laid out like an installed Hub. Code lives here,
user-facing text in `languages/`, example configuration in `config/`; an installer brings
them together. `tests/Invoke-Tests.ps1 -RepoRoot '..'` assembles them the same way, so the
test suite exercises the real arrangement.
