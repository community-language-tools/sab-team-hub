# tests/

Pester tests, version 5 or later. Windows PowerShell ships Pester 3.4.0, whose syntax is
incompatible; install a current one with
`Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0.0`.

The suite does not know where the code lives. Point it at whichever copy you want to
verify, and the same tests must pass against both:

    # This repository's own code, assembled into a Hub in TEMP the way an installer would:
    ./Invoke-Tests.ps1 -RepoRoot '..'

    # An existing installed deployment, whose script may have a different filename:
    ./Invoke-Tests.ps1 -HubSource 'C:\path\to\deployment' -HubScriptName 'Your-Script.ps1' -ConfirmationWord 'yourword'

That is the point of the suite rather than a convenience: tests describing how a working
deployment already behaves are only evidence if the same tests, unedited, also pass against
the rewritten code.

Every world is generated in TEMP and deleted afterwards. Nothing is read from a real
deployment except the scripts under test -- no team list, no project data, no real names.
Copying a deployment's own configuration into a test couples the suite to whoever happens
to be on that team, and can pin it to one machine.

Red error text scrolling past during a run is expected. The tests deliberately provoke
refusals, and the refusals print.

## What is covered

- Authorized deletion of central files -- deletion requires the confirmation word.
- Lock ownership -- only the holder may send or release.
- Creating a central project -- including the check that matters, that the engine accepts
  what the provisioning script produces.
- Installing onto a computer -- ending by running the real engine out of what was installed.

Provisioning and installing are new behaviour: there is nothing in an existing deployment to
characterize, so those tests state a specification instead. They are skipped, not silently
passed, when the code under test is a deployment that does not have those scripts.

## What is not covered

- Two people racing for the same lock. `Acquire-ProjectLock` is only reachable through
  Start work, which checks the Scripture App Builder version first and so cannot run where
  SAB is not installed at an exact version -- including any automated runner. Making it
  testable needs a seam in the engine.
- Receive, status and the menu. `Receive-Project` is the largest untested action, and it
  writes into a member's local folder.
- Whether shared storage honours exclusive locking between two computers. That needs two
  real machines; no test file can answer it.
