# Pull request review checklist

For a reviewer who is not a programmer — including the case where you are reviewing a
pull request that you had an AI write for you.

**Why this file exists.** You are not going to review a pull request the way a specialist
does, line by line, looking for subtle mistakes. That is not realistic. What *is*
realistic is a fixed process, in which the things you *can* judge — how big the change is,
whether it actually works, whether the tests pass, whether anything odd is in the diff —
catch the things you cannot see. This checklist is that process.

Do not skip a step because a change "looks small". A small change is exactly when the
whole list costs thirty seconds.

Two situations, with different risks:

- **A — the pull request is yours** (you or your AI wrote it). Risk: an accidental mistake.
- **B — the pull request is from a stranger** (possible once this repository is public).
  Risk: also deliberate harm, which is precisely what a non-specialist is worst at seeing.
  See section 3.

---

## 1. The fixed checks, in this order

- [ ] **The size matches the description.**
      Open the "Files changed" tab. Does the pull request touch only the files it should
      touch? One that says "fixed a typo in the README" but changes eight source files is
      suspicious, even if you do not read a single line of the code. This is the
      highest-yield check there is.

- [ ] **It is small enough to review at all.**
      More than roughly 400 changed lines is not reviewable by anyone, specialists
      included. Ask for it to be split up rather than merging it anyway.

- [ ] **The tests pass.**
      If continuous integration is set up, this is the check mark at the top of the pull
      request; red means do not merge, full stop. This repository does not have it yet —
      see section 5 — so for now you run the tests yourself, which is the next check.

- [ ] **It actually works.**
      Fetch the branch and try it. You know what this tool is supposed to do; that is your
      strongest asset, stronger than reading code.

          gh pr checkout <number>

      Then run the test suite. It needs to be pointed at a copy of the scripts to test,
      because it deliberately does not know where the code lives:

          cd tests
          ./Invoke-Tests.ps1 -HubSource '<folder holding the hub script>' -HubScriptName '<script filename>' -ConfirmationWord '<the word that authorizes deletion>'

      Red error text scrolling past during the run is normal. Several tests deliberately
      provoke a refusal, and the refusal message is what you are seeing. Only the summary
      line at the end counts: `Tests Passed: N, Failed: 0`.

- [ ] **Nothing is in the diff that does not belong there.**
      In "Files changed", search (Ctrl+F) for:
      - your own name and user name
      - paths such as `C:\Users\`
      - real team member names, real project codes, real project data
      - `password`, `token`, `key`, `secret`, `api`
      - `.env`, `team.json`, `users.json`, `projects.json`, or anything else that belongs
        in `.gitignore`

- [ ] **The description matches the diff.**
      Does the pull request say something other than what it does? That is a signal in
      itself, whatever the content turns out to be.

- [ ] **A second pair of eyes, from a FRESH context.**
      The AI that wrote the code must not be the one to review it — it has the same blind
      spots. Concretely: `gh pr checkout <number>`, then `/code-review` in a **new**
      session, or GitHub Copilot code review on the pull request itself. Two models
      disagreeing is useful information, not noise.

- [ ] **Tests were not adjusted to make them pass.**
      If a test file changed, ask why. A test that fails after a rebuild means the code is
      wrong, not the test. Adjusting the test until it goes green quietly removes the
      safety net. This is also a rule in `CLAUDE.md`.

      A test file may legitimately change for other reasons — being moved, renamed, or
      having shared setup pulled out of it. What matters is whether the *assertions*
      changed: the lines saying what must be true.

## 2. Decide the risk category first, before you review

Knowing which category a change falls into is something you can do perfectly well. That
is the skill — not reading the code.

| Category | Examples | What to do |
|---|---|---|
| **Green — handle it yourself** | text, translations, documentation, colours, an extra button, a new language file | section 1, then merge |
| **Orange — go extra slowly** | a new dependency added, existing logic rewritten, configuration changed | section 1 + AI review + run it yourself + sleep on it |
| **Red — get a human involved** | deleting files, network traffic, passwords or authentication, user data, payments, anything that runs automatically | do not merge it yourself; ask a programmer |

For this repository in particular, treat anything touching the **lock mechanism** as red.
It is the one thing standing between two team members and overwriting each other's work.

## 3. If the pull request comes from a stranger

Never merge what you cannot judge. That is not rudeness, it is the norm — experienced
maintainers do exactly this.

- [ ] Thank the contributor and say you need time. There is no hurry.
- [ ] Check whether it resolves an existing issue or arrives out of nowhere.
- [ ] Be extra alert to: new dependencies, changed build or CI files, network code. These
      are the classic places where malicious code gets in.
- [ ] Not green? Get someone who can actually read it.

## 4. Managing expectations when you have no time for pull requests

You are not obliged to do anything. The MIT licence says "as is, without warranty", and
culturally that covers maintenance too. But there is a large difference between *saying
no* and *saying nothing*.

**Fine:**
- Closing a pull request with one friendly sentence ("thank you, this is outside what I
  can maintain — feel free to fork"). Costs a minute, entirely accepted.
- Being slow. Weeks is normal in volunteer projects.
- Saying you cannot judge it yourself and need someone else to look.
- Doing pull requests in batches ("I look on the first Saturday of the month").

**Not fine:**
- Leaving a pull request open for a year without a word. This is contributors' number one
  complaint — not the rejection, the silence.
- Closing without explanation.
- Taking someone's idea and rewriting it yourself without credit.

**The real solution is to say it in advance.** Nobody can be angry about something you
warned them about. `CONTRIBUTING.md` in this repository already does this, under
"Maintenance status": it asks people to open an issue first, and says pull requests may be
reviewed slowly. That sentence — **open an issue first** — is the important one. It stops
someone spending five hours on something you were never going to merge.

A note for a repository heading for an organisation such as sillsdev: there, pull requests
will probably come from *colleagues*, not strangers. Ignoring a colleague costs something
quite different from ignoring a stranger. Shared maintenance is one of the reasons for
handing a project over in the first place.

## 5. One-time setup for this repository

Once these are in place they protect you automatically. Current status:

- [ ] **Branch protection on `main`** — Settings → Branches → Add rule
      - "Require a pull request before merging" — never straight onto `main`
      - "Require status checks to pass before merging" — tests as the gatekeeper

      **Available now, still to be switched on.** This repository is public, so GitHub
      offers branch protection on the free plan. Until the rule is added, "never commit
      directly to `main`" is a rule kept by hand, not a gate the server enforces. Add the
      rule, and mark the `Pester on Windows PowerShell 5.1` check as required.

- [x] **Continuous integration running the tests**, in `.github/workflows/tests.yml`. Every
      pull request, and every push to `main`, runs the whole suite on Windows against this
      repository's own `src/`. A pull request whose tests are red must not be merged.

- [x] **`.gitignore`** excluding all real data and secrets, before the first push.

- [x] **`AGENTS.md` / `CLAUDE.md`** stating the rules: small pull requests, descriptions in
      plain language, never straight onto `main`.

## 6. Useful commands

    gh pr list                     # which pull requests are open
    gh pr view <number>            # description and status
    gh pr diff <number>            # the whole diff in the terminal
    gh pr checkout <number>        # fetch the branch locally to try it
    gh pr checks <number>          # are the automated checks green
    git checkout main              # back to main when you are done trying it
