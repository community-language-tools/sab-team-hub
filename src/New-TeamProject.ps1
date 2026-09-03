<#
.SYNOPSIS
Creates a new central project on shared storage, ready for a team to use.

.DESCRIPTION
SAB Team Hub can receive, send and lock a project, but it cannot create one. Every
existing deployment had its central project built by hand, once, by an administrator.
This script is that missing step, so a new team can start from nothing.

It creates the central project folder, seeds the master copy, writes the first master
manifest, and writes the PROJECT.json control file that the Hub reads. Afterwards the
project satisfies everything the Hub checks before it will let a member start work.

Provisioning writes to shared storage WITHOUT holding a project lock, because no lock
can exist before the project does. That is why this is a separate script: inside the
Hub every central write happens under a lock, and this operation cannot honour that
rule. Keeping it out preserves the rule for everything else.

Run this once per project, before anyone runs the Hub against it.

.PARAMETER Code
The project code. Becomes the folder name under the central root, and the value passed
to the Hub as -Project. Letters, digits, hyphen and underscore; must start with a letter
or digit -- the same rule the Hub itself enforces.

.PARAMETER CentralRoot
The shared storage root, for example P:\SABTEAMHUB. Taken from -ConfigPath when omitted.

.PARAMETER ConfigPath
A TeamConfig.json to read centralRoot, requiredVersion and requiredRelease from, so the
new project agrees with the team's installed configuration. Omit and pass the values
explicitly instead.

.PARAMETER SeedFrom
A folder whose contents become version 1 of the master copy -- normally the administrator's
existing Scripture App Builder project folder. Omit to create an empty master, which a
team member then fills and sends.

.PARAMETER DisplayName
A human-readable name for the project. Defaults to the code.

.PARAMETER RequiredSabVersion
The Scripture App Builder version the team must run, for example 14.4.

.PARAMETER RequiredSabRelease
The required Scripture App Builder build release, for example 179.

.PARAMETER AdministratorId
The user id recorded as having created the project, for the history log. Optional; no
Windows account or machine name is recorded.

.PARAMETER Force
Overwrite the control files of a project that already exists. The master copy, backups
and history are left alone. Refuses without this switch.

.EXAMPLE
    # Read the shared storage location and required SAB version from the installed config:
    ./New-TeamProject.ps1 -Code LSK1 -ConfigPath 'C:\SABTEAMHUB\_HUB\TeamConfig.json' -SeedFrom 'C:\My SAB Projects\LSK1'

.EXAMPLE
    # Everything explicit, empty master:
    ./New-TeamProject.ps1 -Code PILOT -CentralRoot 'P:\SABTEAMHUB' -RequiredSabVersion 14.4 -RequiredSabRelease 179
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $Code,

    [Parameter()]
    [string] $CentralRoot,

    [Parameter()]
    [string] $ConfigPath,

    [Parameter()]
    [string] $SeedFrom,

    [Parameter()]
    [string] $DisplayName,

    [Parameter()]
    [string] $RequiredSabVersion,

    [Parameter()]
    [string] $RequiredSabRelease,

    [Parameter()]
    [string] $AdministratorId,

    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)][string] $Path
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.{0}.{1}.tmp' -f ([System.IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString('N'))
    $json = $Value | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

# Must produce exactly what the Hub's own New-MasterManifest produces, or the Hub will
# reject the project it is handed: same columns, same relative paths, same ordering.
function New-ManifestFile {
    param(
        [Parameter(Mandatory)][string] $MasterPath,
        [Parameter(Mandatory)][string] $ControlPath,
        [Parameter(Mandatory)][int] $Version
    )

    $files = @(Get-ChildItem -LiteralPath $MasterPath -Recurse -File -Force | Sort-Object FullName)
    $rows = @(foreach ($file in $files) {
        [pscustomobject]@{
            Path   = $file.FullName.Substring($MasterPath.Length).TrimStart('\')
            Bytes  = $file.Length
            SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    })

    $name = 'MASTER-MANIFEST-v{0:D4}.csv' -f $Version
    $path = Join-Path $ControlPath $name
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'

    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $temporary -NoTypeInformation -Encoding UTF8
    }
    else {
        # Export-Csv writes nothing at all for an empty collection, which leaves a file
        # that is not valid CSV. Write the header so an empty master still reads back as
        # zero rows rather than as a broken manifest.
        $header = '"Path","Bytes","SHA256"' + "`r`n"
        [System.IO.File]::WriteAllText($temporary, $header, [System.Text.UTF8Encoding]::new($false))
    }
    Move-Item -LiteralPath $temporary -Destination $path -Force

    $totalBytes = 0
    if ($rows.Count -gt 0) { $totalBytes = [int64](($rows | Measure-Object Bytes -Sum).Sum) }

    [pscustomobject]@{
        Name  = $name
        Path  = $path
        Hash  = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Count = $rows.Count
        Bytes = $totalBytes
    }
}

if ($Code -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
    throw "Invalid project code: $Code. Use letters, digits, hyphen and underscore, starting with a letter or digit."
}

if ($ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Team config not found: $ConfigPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $CentralRoot) { $CentralRoot = [string]$config.centralRoot }
    if (-not $RequiredSabVersion) { $RequiredSabVersion = [string]$config.requiredVersion }
    if (-not $RequiredSabRelease) { $RequiredSabRelease = [string]$config.requiredRelease }
}

foreach ($pair in @(
    @{ Name = 'CentralRoot'; Value = $CentralRoot }
    @{ Name = 'RequiredSabVersion'; Value = $RequiredSabVersion }
    @{ Name = 'RequiredSabRelease'; Value = $RequiredSabRelease }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$pair.Value)) {
        throw ("Missing -{0}. Pass it, or pass -ConfigPath to read it from a TeamConfig.json." -f $pair.Name)
    }
}

if (-not (Test-Path -LiteralPath $CentralRoot -PathType Container)) {
    throw "Central root is unavailable: $CentralRoot. Create it, or connect the shared storage, before provisioning a project."
}
$CentralRoot = (Resolve-Path -LiteralPath $CentralRoot).Path.TrimEnd('\')

if (-not $DisplayName) { $DisplayName = $Code }

$centralProject = Join-Path $CentralRoot $Code
$controlPath    = Join-Path $centralProject 'CONTROL'
$masterPath     = Join-Path $centralProject 'MASTER'
$projectJson    = Join-Path $controlPath 'PROJECT.json'
$lockPath       = Join-Path $controlPath 'PROJECT-LOCK.json'

if ((Test-Path -LiteralPath $projectJson -PathType Leaf) -and -not $Force) {
    throw "Project $Code already exists at $centralProject. Use -Force to rewrite its control files, or choose another code."
}
if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
    throw "Project $Code is currently locked by a team member. Provisioning must not run while a lock is held: $lockPath"
}

if ($SeedFrom) {
    if (-not (Test-Path -LiteralPath $SeedFrom -PathType Container)) { throw "Seed folder not found: $SeedFrom" }
    $SeedFrom = (Resolve-Path -LiteralPath $SeedFrom).Path.TrimEnd('\')
    if ($SeedFrom -eq $masterPath.TrimEnd('\')) { throw "Seed folder and the new master are the same folder: $SeedFrom" }
}

if (-not $PSCmdlet.ShouldProcess($centralProject, 'Create central project')) { return }

New-Item -ItemType Directory -Path @(
    $centralProject
    $controlPath
    $masterPath
    (Join-Path $centralProject 'BACKUPS')
    (Join-Path $centralProject 'HISTORY')
) -Force | Out-Null

Write-Host ("[INFO] Central project: {0}" -f $centralProject)

if ($SeedFrom) {
    $seedFiles = @(Get-ChildItem -LiteralPath $SeedFrom -Recurse -File -Force)
    foreach ($file in $seedFiles) {
        $relative = $file.FullName.Substring($SeedFrom.Length).TrimStart('\')
        $target = Join-Path $masterPath $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    Write-Host ("[OK] Seeded the master copy with {0} file(s) from {1}" -f $seedFiles.Count, $SeedFrom)
}
else {
    Write-Host '[INFO] No -SeedFrom given, so the master copy starts empty. A team member fills it and sends.'
}

$manifest = New-ManifestFile -MasterPath $masterPath -ControlPath $controlPath -Version 1
Write-Host ("[OK] Wrote {0}: {1} file(s), {2} byte(s)" -f $manifest.Name, $manifest.Count, $manifest.Bytes)

# Only fields the Hub actually reads, plus provenance. The example configuration files
# once listed fields nothing consumed, and anyone setting up from them configured
# nothing -- so unread fields are not added here either.
$control = [pscustomobject][ordered]@{
    schemaVersion  = 1
    projectCode    = $Code
    displayName    = $DisplayName
    masterVersion  = 1
    masterState    = 'VERIFIED'
    teamUseAllowed = $true
    workflowState  = 'ACTIVE'
    workflowReason = 'Collaboration safeguards active.'
    requiredSab    = [pscustomobject][ordered]@{
        version = $RequiredSabVersion
        release = $RequiredSabRelease
    }
    master         = [pscustomobject][ordered]@{
        relativePath   = '..\MASTER'
        fileCount      = $manifest.Count
        totalBytes     = $manifest.Bytes
        manifest       = $manifest.Name
        manifestSha256 = $manifest.Hash
    }
    createdUtc     = (Get-Date).ToUniversalTime().ToString('o')
}
if ($AdministratorId) { $control | Add-Member -NotePropertyName createdBy -NotePropertyValue $AdministratorId }

Write-JsonAtomic -Value $control -Path $projectJson
Write-Host ("[OK] Wrote {0}" -f $projectJson)

$details = "code=$Code files=$($manifest.Count) manifest=$($manifest.Name)"
if ($AdministratorId) { $details += " administrator=$AdministratorId" }
$historyLine = '{0} | {1} | {2}' -f (Get-Date).ToUniversalTime().ToString('o'), 'PROVISION', $details
Add-Content -LiteralPath (Join-Path $centralProject 'HISTORY\HISTORY.log') -Value $historyLine -Encoding UTF8

Write-Host ''
Write-Host ("[DONE] Project {0} is ready for the team." -f $Code) -ForegroundColor Green
Write-Host ("       Master version 1, {0} file(s), Scripture App Builder {1} release {2} required." -f $manifest.Count, $RequiredSabVersion, $RequiredSabRelease)
Write-Host ''
Write-Host '       Next: each team member runs the Hub and chooses Start work.'

[pscustomobject][ordered]@{
    Code           = $Code
    CentralProject = $centralProject
    MasterVersion  = 1
    FileCount      = $manifest.Count
    TotalBytes     = $manifest.Bytes
    Manifest       = $manifest.Name
    ManifestSha256 = $manifest.Hash
}
