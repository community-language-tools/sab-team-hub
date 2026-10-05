# SAB Team Hub

Shared, version-controlled collaboration on a Scripture App Builder project over ordinary
shared storage (pCloud, Google Drive), with turn-taking that prevents team members from
overwriting each other's work.

## About

Scripture App Builder Team Hub is developed by SIL Global and is free to use by language
communities around the world for digital Scripture publishing.

## Who this is for

Translation teams working with Scripture App Builder (SAB) on more than one computer, who
want to share the same project files without a server to administer — and without two
people overwriting each other.

## Important: this repository holds the software, not your data

`config/` contains example files only (`*.example.json`) with invented names. To use this
for a real team, copy them to their working filenames and fill in your own details. Those
never enter Git — see `.gitignore`.

## Status

Under development. Not yet ready for production use by other teams. See `CHANGELOG.md`.

## Getting started

### What you need first

- **Windows.** PowerShell 5.1 is already part of Windows; nothing to install.
- **Scripture App Builder**, installed on every computer that will take part, at the
  **same version and release**. The Hub checks this and refuses to run when a computer is
  on a different version, because mixed versions can corrupt a project.
- **A Scripture App Builder project that already exists.** The administrator creates it in
  Scripture App Builder in the normal way, on their own computer. SAB Team Hub does not
  create projects and is not needed for that part.
- **Shared storage** that every member already has set up and syncing — pCloud, Google
  Drive, a network drive, anything that appears as an ordinary folder. The team does not
  need a server.
- **A copy of this repository on each computer.** Use the green **Code** button above,
  then **Download ZIP**, and unpack it somewhere you can find again.

### Step 1 — Prepare the team's configuration (administrator, once)

In the `config/` folder, make your own copies of the two example files:

- Copy `team.example.json` to `team.json`
- Copy `users.example.json` to `users.json`

Open `team.json` and fill in your own details: the team name, the folder on shared storage,
the folder on each local computer, where Scripture App Builder is installed, and the SAB
version and release everyone must use.

Open `users.json` and list your team members, giving each one a short id such as `ALICE`.
The id is what the Hub uses to know who holds a project.

These two files stay on your computer and are never part of this repository. They name your
team and your drive, so they are deliberately excluded from Git.

### Step 2 — Put your project onto shared storage (administrator, once per project)

Your project already exists in Scripture App Builder. This step copies it to the shared
drive and sets it up so the team can take turns with it:

    .\src\New-TeamProject.ps1 -Code MYPROJ -ConfigPath config\team.json -SeedFrom "C:\My SAB Projects\MYPROJ"

`-SeedFrom` is your existing Scripture App Builder project folder. Its contents become
version 1, which everyone else will receive. `-Code` is the short name the project will
have on the shared drive.

Run this once per project. Afterwards the project sits on the shared drive, unlocked, and
the first member can take it.

If you ever need to start a team working before the project content exists, leave
`-SeedFrom` out. That creates an empty project for a member to fill and send.

### Step 3 — Install the Hub on your own computer (administrator, once)

Open PowerShell in the unpacked folder and run:

    .\src\Install-TeamHub.ps1 -UserId ADMIN -PublishUserRegistry

This assembles the Hub into the local folder named in your configuration, registers you,
and publishes the team list to the shared drive. Publishing means the team list is
maintained in one place from now on, instead of on every machine.

### Step 4 — Install on each member's computer

On every other computer, unpack the repository and run the same installer with that
member's id, and the language they want:

    .\src\Install-TeamHub.ps1 -UserId ALICE -UiLanguage fr

English (`en`), French (`fr`) and Dutch (`nl`) are available. The member is registered
straight away, so they are never asked who they are.

Running the installer again later updates an existing installation. It replaces the program
and the translations, and leaves the member's identity, their folders and their work
untouched.

### Step 5 — Daily use

Members start the Hub from the **SAB Team Hub** shortcut in their local Hub folder. They
never need a command line. The menu offers:

- **START WORK** — takes the turn, fetches the verified latest version, and opens Scripture
  App Builder
- **SEND AND FINISH** — backs up, checks the work arrived intact, and passes the turn on
- **Need help?** — an explanation in the member's own language

Only one person holds a project at a time. A second member trying to start work is told who
has it, rather than being allowed to overwrite their work.

## Contributing

Questions, ideas, or something that does not work: please open an **issue**. You do not
need to be a programmer to be useful — reporting what went wrong is already valuable.

See `CONTRIBUTING.md` for how pull requests are handled.

## Licence

MIT — see `LICENSE`.

## Team data

Configuration describing a real team (names, project paths) is never part of this
repository. It stays local and is never published.
