<#
.SYNOPSIS
Installs the Hub onto one computer, from this repository.

.DESCRIPTION
The repository is deliberately not laid out like an installed Hub: code lives in src/,
user-facing text in languages/, example configuration in config/. This script brings them
together into <LocalRoot>\_HUB, which is the arrangement the Hub expects at run time.

It reads where things go from the team configuration, so one prepared config file installs
the same way on every team computer.

Run it once per computer. It is safe to run again to update an existing installation: it
overwrites the program files and the text, and leaves the member's identity, their project
folders and their work alone.

.PARAMETER TeamConfig
The team's configuration file -- a filled-in copy of config/team.example.json. Defaults to
config/team.json in this repository. This file is not in the repository and never should be:
it names your team's shared drive.

.PARAMETER UsersFile
The team's user registry -- a filled-in copy of config/users.example.json. Defaults to
config/users.json in this repository.

.PARAMETER LocalRoot
Where the Hub is installed on this computer. Taken from the team configuration when omitted.

.PARAMETER CentralRoot
The team's shared storage. Taken from the team configuration when omitted.

.PARAMETER UserId
Which team member is using this computer. When given, the installer registers the identity
straight away, so the member never sees the who-are-you prompt. Must be an enabled id in
the user registry.

.PARAMETER UiLanguage
The language of the Hub for this member. Must be one of the translations in languages/.
Defaults to en.

.PARAMETER PublishUserRegistry
Also copy the user registry to <CentralRoot>\_DISTRIBUTION\Users.json, which the Hub reads
in preference to the local copy. Do this once, from the administrator's computer, and the
team list can then be updated in one place instead of on every machine.

.PARAMETER RepoRoot
This repository's root. Defaults to the folder above this script, which is correct when
running it from src/.

.EXAMPLE
    # On the administrator's computer, publishing the team list centrally:
    ./Install-TeamHub.ps1 -UserId ADMIN -PublishUserRegistry

.EXAMPLE
    # On a member's computer, with everything coming from the prepared config:
    ./Install-TeamHub.ps1 -UserId ALICE -UiLanguage fr
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string] $TeamConfig,

    [Parameter()]
    [string] $UsersFile,

    [Parameter()]
    [string] $LocalRoot,

    [Parameter()]
    [string] $CentralRoot,

    [Parameter()]
    [string] $UserId,

    [Parameter()]
    [string] $UiLanguage = 'en',

    [Parameter()]
    [switch] $PublishUserRegistry,

    [Parameter()]
    [string] $RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$engineName = 'SAB-Team-Hub.ps1'
$launcherName = 'SAB Team Hub.cmd'

function Read-JsonFile {
    param([Parameter(Mandatory)][string] $Path)
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Assert-InstallableRoot {
    param([Parameter(Mandatory)][string] $Path)

    if (-not [System.IO.Path]::IsPathRooted($Path)) { throw "LocalRoot must be an absolute path. Received: $Path" }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $drive = [System.IO.Path]::GetPathRoot($full).TrimEnd('\')
    if ($full -eq $drive) { throw "Refusing to install into a drive root: $full" }
    return $full
}

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { throw "Repository root not found: $RepoRoot" }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')

$sourceCode = Join-Path $RepoRoot 'src'
$sourceText = Join-Path $RepoRoot 'languages'
$sourceConfig = Join-Path $RepoRoot 'config'
foreach ($folder in @($sourceCode, $sourceText)) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        throw "Not a copy of this repository: $folder is missing. Pass -RepoRoot, or run the script from the repository's src/ folder."
    }
}

if (-not $TeamConfig) { $TeamConfig = Join-Path $sourceConfig 'team.json' }
if (-not $UsersFile) { $UsersFile = Join-Path $sourceConfig 'users.json' }

foreach ($pair in @(
    @{ Path = $TeamConfig; Example = 'team.example.json'; Switch = 'TeamConfig' }
    @{ Path = $UsersFile;  Example = 'users.example.json'; Switch = 'UsersFile' }
)) {
    if (-not (Test-Path -LiteralPath $pair.Path -PathType Leaf)) {
        $template = "Not found: {0}" + [Environment]::NewLine +
                    "        Copy config\{1} to that name and fill in your team's details first, " +
                    "or pass -{2} with its location. The filled-in file is never committed."
        throw ($template -f $pair.Path, $pair.Example, $pair.Switch)
    }
}

$config = Read-JsonFile -Path $TeamConfig
if (-not $LocalRoot) { $LocalRoot = [string]$config.localRoot }
if (-not $CentralRoot) { $CentralRoot = [string]$config.centralRoot }
if ([string]::IsNullOrWhiteSpace($LocalRoot)) { throw "No localRoot in $TeamConfig, and no -LocalRoot given." }
if ([string]::IsNullOrWhiteSpace($CentralRoot)) { throw "No centralRoot in $TeamConfig, and no -CentralRoot given." }

$LocalRoot = Assert-InstallableRoot -Path $LocalRoot
if (-not (Test-Path -LiteralPath $CentralRoot -PathType Container)) {
    throw "The team's shared storage is unavailable: $CentralRoot. Connect it, then run this again."
}
$CentralRoot = (Resolve-Path -LiteralPath $CentralRoot).Path.TrimEnd('\')

# Validated against what is actually translated, not against a fixed list, so adding a
# translation to languages/ never requires editing this script.
$available = @(Get-ChildItem -LiteralPath $sourceText -File -Filter '*.json' |
    ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } | Sort-Object)
if ($available.Count -eq 0) { throw "No translations found in $sourceText" }
if ($UiLanguage -notin $available) {
    throw ("Not a translated language: {0}. Available: {1}" -f $UiLanguage, ($available -join ', '))
}

if ($UserId) {
    $registry = Read-JsonFile -Path $UsersFile
    $known = @($registry.users | Where-Object { $_.enabled -eq $true } | ForEach-Object { [string]$_.id })
    if ([string]$UserId -notin $known) {
        throw ("Not an enabled user id in {0}: {1}. Known: {2}" -f $UsersFile, $UserId, ($known -join ', '))
    }
}

$hub = Join-Path $LocalRoot '_HUB'
if (-not $PSCmdlet.ShouldProcess($hub, 'Install the Hub')) { return }

New-Item -ItemType Directory -Force -Path @(
    $LocalRoot, $hub, (Join-Path $hub 'Languages'), (Join-Path $hub 'Config')
) | Out-Null

$scripts = @(Get-ChildItem -LiteralPath $sourceCode -File -Filter '*.ps1')
$scriptNames = @($scripts | ForEach-Object { $_.Name })
if ($engineName -notin $scriptNames) { throw "The engine is missing from $sourceCode : $engineName" }
foreach ($file in $scripts) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $hub $file.Name) -Force }

foreach ($file in @(Get-ChildItem -LiteralPath $sourceCode -File -Filter '*.cmd')) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $hub $file.Name) -Force
}

foreach ($file in @(Get-ChildItem -LiteralPath $sourceText -File -Filter '*.json')) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $hub (Join-Path 'Languages' $file.Name)) -Force
}

Copy-Item -LiteralPath $TeamConfig -Destination (Join-Path $hub 'TeamConfig.json') -Force
Copy-Item -LiteralPath $UsersFile -Destination (Join-Path $hub 'Users.json') -Force
Write-Host ("[OK] Installed the Hub into {0}" -f $hub)

if ($PublishUserRegistry) {
    $distribution = Join-Path $CentralRoot '_DISTRIBUTION'
    New-Item -ItemType Directory -Force -Path $distribution | Out-Null
    Copy-Item -LiteralPath $UsersFile -Destination (Join-Path $distribution 'Users.json') -Force
    Write-Host ("[OK] Published the team list to {0}" -f (Join-Path $distribution 'Users.json'))
    Write-Host '     The Hub reads this in preference to the copy on each computer.'
}

# One click for the member. The launcher shipped in src/ runs the engine from beside itself;
# this one at the top of LocalRoot just calls it, so the member never browses into _HUB.
$rootLauncher = Join-Path $LocalRoot $launcherName
if (Test-Path -LiteralPath (Join-Path $hub $launcherName) -PathType Leaf) {
    $text = "@echo off`r`ncall `"%~dp0_HUB\$launcherName`"`r`n"
    [System.IO.File]::WriteAllText($rootLauncher, $text, [System.Text.ASCIIEncoding]::new())
    Write-Host ("[OK] Start the Hub from {0}" -f $rootLauncher)
}
else {
    Write-Host ("[WARN] No {0} in src/, so no shortcut was created. Start the Hub with:" -f $launcherName)
    Write-Host ("       powershell -ExecutionPolicy Bypass -File `"{0}`"" -f (Join-Path $hub $engineName))
}

# Only the two top-level folders per project. The engine creates the full substructure
# itself, on first use, in Ensure-LocalProjectStructure -- and a second copy of that folder
# list here would be one more place to forget to update. The existing deployment has three
# copies of it, and they have already drifted apart.
$centralProjects = @(Get-ChildItem -LiteralPath $CentralRoot -Directory -Force |
    Where-Object {
        -not $_.Name.StartsWith('_') -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'CONTROL\PROJECT.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'MASTER') -PathType Container)
    })

# Never $centralProjects.Name: member enumeration on an empty array throws under
# Set-StrictMode -Version Latest, and an empty shared drive is the normal state on a
# first install. That mistake made the very first installation fail at the last line.
$projectNames = @($centralProjects | ForEach-Object { $_.Name })

foreach ($project in $centralProjects) {
    New-Item -ItemType Directory -Force -Path @(
        (Join-Path (Join-Path $LocalRoot $project.Name) '_PARTAGE')
        (Join-Path (Join-Path $LocalRoot $project.Name) '_LOCALE')
    ) | Out-Null
}
if ($centralProjects.Count -gt 0) {
    Write-Host ("[OK] Prepared local folders for {0} project(s): {1}" -f $centralProjects.Count, ($projectNames -join ', '))
}
else {
    Write-Host '[INFO] No projects found on the shared storage yet. An administrator creates the first one with New-TeamProject.ps1.'
}

if ($UserId) {
    & (Join-Path $hub $engineName) -Action Identify -UserId $UserId -UiLanguage $UiLanguage `
        -LocalRoot $LocalRoot -CentralRoot $CentralRoot
    Write-Host ("[OK] Registered this computer as {0}" -f $UserId)
}
elseif (Test-Path -LiteralPath (Join-Path $hub 'Config\Identity.json') -PathType Leaf) {
    Write-Host '[INFO] Kept the identity already registered on this computer.'
}
else {
    Write-Host '[INFO] No -UserId given. The Hub will ask who is using this computer the first time it starts.'
}

Write-Host ''
Write-Host '[DONE] Installation complete.' -ForegroundColor Green

[pscustomobject][ordered]@{
    Hub            = $hub
    LocalRoot      = $LocalRoot
    CentralRoot    = $CentralRoot
    Launcher       = $rootLauncher
    Languages      = $available
    Projects       = $projectNames
    RegisteredUser = if ($UserId) { $UserId } else { $null }
}
