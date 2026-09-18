<#
.SYNOPSIS
Controlled receive/send workflow and launcher for collaborative Scripture App Builder projects.

.DESCRIPTION
The script identifies the local user, obtains an exclusive project lock on P:,
checks local and central manifests, receives or sends only under the lock, and
opens the locally configured SAB project. Central deletions require an explicit
confirmation word and are backed up before they are applied.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Menu', 'Identify', 'Help', 'Status', 'StartWork', 'SendFinish', 'ReleaseClean', 'AdminUnlock')]
    [string] $Action = 'Menu',

    [Parameter()]
    [string] $Project,

    [Parameter()]
    [string] $UserId,

    [Parameter()]
    [ValidateSet('fr', 'en', 'nl')]
    [string] $UiLanguage,

    [Parameter()]
    [string] $LocalRoot,

    [Parameter()]
    [string] $CentralRoot,

    [Parameter()]
    [string] $Reason,

    [Parameter()]
    [switch] $NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hubRoot = $PSScriptRoot
$configPath = Join-Path $hubRoot 'TeamConfig.json'
$localUsersPath = Join-Path $hubRoot 'Users.json'
$languagesRoot = Join-Path $hubRoot 'Languages'
$identityPath = Join-Path $hubRoot 'Config\Identity.json'
$script:messages = $null
$script:activeLanguage = ''

function Read-JsonFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter()][int] $Retries = 1
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            $lastError = $_
            if ($attempt -lt $Retries) { Start-Sleep -Milliseconds 300 }
        }
    }
    throw $lastError
}

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

function Get-Text {
    param(
        [Parameter(Mandatory)][string] $Key,
        [Parameter()][object[]] $Values = @()
    )

    $property = $script:messages.PSObject.Properties[$Key]
    if ($null -eq $property) { return "[$Key]" }
    $template = [string]$property.Value
    if ($Values.Count -gt 0) { return $template -f $Values }
    return $template
}

function Get-TeamName {
    $property = $script:Config.PSObject.Properties['teamName']
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return 'SAB Team Hub' }
    return [string]$property.Value
}

function Get-DeletionConfirmationWord {
    $property = $script:Config.PSObject.Properties['deletionConfirmationWord']
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return 'CONFIRM' }
    return [string]$property.Value
}

function Import-Messages {
    param([Parameter(Mandatory)][string] $Language)

    $path = Join-Path $languagesRoot ($Language + '.json')
    $script:messages = Read-JsonFile -Path $path
    $script:activeLanguage = $Language
}

function Select-Language {
    Write-Host ''
    $teamName = Get-TeamName
    Write-Host $teamName -ForegroundColor Cyan
    Write-Host ('=' * $teamName.Length) -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Choisissez la langue / Choose the language / Kies de taal' -ForegroundColor Yellow
    Write-Host '  1. Francais'
    Write-Host '  2. English'
    Write-Host '  3. Nederlands'
    $choice = Read-Host '1 / 2 / 3'
    Write-Host "[TRACE] 1 / 2 / 3 => $choice" -ForegroundColor DarkGray
    switch ($choice) {
        '1' { return 'fr' }
        '2' { return 'en' }
        '3' { return 'nl' }
        default { throw "Choix incorrect / Invalid choice / Ongeldige keuze: $choice" }
    }
}

function Get-UserRegistryPath {
    $centralUsers = Join-Path $script:CentralRoot '_DISTRIBUTION\Users.json'
    if (Test-Path -LiteralPath $centralUsers -PathType Leaf) { return $centralUsers }
    return $localUsersPath
}

function Get-EnabledUsers {
    $registry = Read-JsonFile -Path (Get-UserRegistryPath)
    return @($registry.users | Where-Object {
        if ($_.enabled -ne $true) { return $false }
        $windowsRule = $_.PSObject.Properties['windowsUser']
        $computerRule = $_.PSObject.Properties['computerName']
        if ($null -ne $windowsRule -and -not [string]::IsNullOrWhiteSpace([string]$windowsRule.Value) -and [string]$windowsRule.Value -ne [string]$env:USERNAME) { return $false }
        if ($null -ne $computerRule -and -not [string]::IsNullOrWhiteSpace([string]$computerRule.Value) -and [string]$computerRule.Value -ne [string]$env:COMPUTERNAME) { return $false }
        return $true
    })
}

function Set-TeamIdentity {
    param(
        [Parameter()][string] $SelectedUserId,
        [Parameter(Mandatory)][string] $Language
    )

    $users = @(Get-EnabledUsers)
    if ([string]::IsNullOrWhiteSpace($SelectedUserId)) {
        Write-Host ''
        Write-Host (Get-Text 'choose_user') -ForegroundColor Yellow
        for ($index = 0; $index -lt $users.Count; $index++) {
            Write-Host ('  {0}. {1}' -f ($index + 1), $users[$index].displayName)
        }
        $choiceText = Read-Host (Get-Text 'number_prompt')
        Write-Host "[TRACE] user => $choiceText" -ForegroundColor DarkGray
        $choice = 0
        if (-not [int]::TryParse($choiceText, [ref]$choice) -or $choice -lt 1 -or $choice -gt $users.Count) {
            throw "Invalid user selection: $choiceText"
        }
        $selected = $users[$choice - 1]
    }
    else {
        $selected = $users | Where-Object { $_.id -eq $SelectedUserId } | Select-Object -First 1
        if ($null -eq $selected) { throw "Unknown or disabled user: $SelectedUserId" }
    }

    $identity = [pscustomobject][ordered]@{
        schemaVersion = 1
        userId = [string]$selected.id
        displayName = [string]$selected.displayName
        role = [string]$selected.role
        windowsUser = [string]$env:USERNAME
        computerName = [string]$env:COMPUTERNAME
        uiLanguage = $Language
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-JsonAtomic -Value $identity -Path $identityPath
    Write-Host (Get-Text 'identity_saved' @($identity.displayName, $identity.computerName)) -ForegroundColor Green
    return $identity
}

function Get-TeamIdentity {
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        throw (Get-Text 'identity_invalid')
    }
    $identity = Read-JsonFile -Path $identityPath
    $registered = @(Get-EnabledUsers) | Where-Object { $_.id -eq $identity.userId } | Select-Object -First 1
    if ($null -eq $registered -or
        [string]$identity.computerName -ne [string]$env:COMPUTERNAME -or
        [string]$identity.windowsUser -ne [string]$env:USERNAME) {
        throw (Get-Text 'identity_invalid')
    }
    $identity.displayName = [string]$registered.displayName
    $identity.role = [string]$registered.role
    return $identity
}

function Get-CentralProjects {
    if (-not (Test-Path -LiteralPath $script:CentralRoot -PathType Container)) {
        throw "Central root is unavailable: $script:CentralRoot"
    }
    return @(
        Get-ChildItem -LiteralPath $script:CentralRoot -Directory -Force |
            Where-Object {
                -not $_.Name.StartsWith('_') -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'CONTROL\PROJECT.json') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'MASTER') -PathType Container)
            } |
            Sort-Object Name
    )
}

function Get-ProjectContext {
    param([Parameter(Mandatory)][string] $Code)

    if ($Code -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw "Invalid project code: $Code" }
    $centralProject = Join-Path $script:CentralRoot $Code
    $localProject = Join-Path $script:LocalRoot $Code
    $controlPath = Join-Path $centralProject 'CONTROL\PROJECT.json'
    if (-not (Test-Path -LiteralPath $controlPath -PathType Leaf)) { throw "Project control not found: $controlPath" }
    $control = Read-JsonFile -Path $controlPath -Retries 5

    [pscustomobject][ordered]@{
        Code = $Code
        CentralProject = $centralProject
        CentralMaster = Join-Path $centralProject 'MASTER'
        CentralControl = Join-Path $centralProject 'CONTROL'
        CentralBackups = Join-Path $centralProject 'BACKUPS'
        CentralHistory = Join-Path $centralProject 'HISTORY'
        ProjectControlPath = $controlPath
        LockPath = Join-Path $centralProject 'CONTROL\PROJECT-LOCK.json'
        Control = $control
        LocalProject = $localProject
        LocalShared = Join-Path $localProject '_PARTAGE'
        LocalPrivate = Join-Path $localProject '_LOCALE'
        LocalCollaboration = Join-Path $localProject '_LOCALE\Collaboration'
        LocalBaseline = Join-Path $localProject '_LOCALE\Collaboration\BASELINE-MANIFEST.csv'
        LocalState = Join-Path $localProject '_LOCALE\Collaboration\STATE.json'
        LocalSession = Join-Path $localProject '_LOCALE\Collaboration\SESSION.json'
        LocalReports = Join-Path $localProject '_LOCALE\Collaboration\Reports'
    }
}

function Ensure-LocalProjectStructure {
    param([Parameter(Mandatory)] $Context)

    $folders = @(
        $Context.LocalShared,
        (Join-Path $Context.LocalShared 'App Projects'),
        (Join-Path $Context.LocalShared 'Contents'),
        (Join-Path $Context.LocalShared 'Keystore'),
        (Join-Path $Context.LocalShared 'Resources'),
        (Join-Path $Context.LocalShared 'Resources\Audio'),
        $Context.LocalPrivate,
        (Join-Path $Context.LocalPrivate 'App Output\Apk'),
        (Join-Path $Context.LocalPrivate 'App Output\Epub'),
        (Join-Path $Context.LocalPrivate 'App Output\PWA'),
        (Join-Path $Context.LocalPrivate 'App Output\HTML'),
        (Join-Path $Context.LocalPrivate 'Backups\Settings'),
        (Join-Path $Context.LocalPrivate 'String Translations'),
        (Join-Path $Context.LocalPrivate 'temp_build'),
        (Join-Path $Context.LocalPrivate 'Timings'),
        $Context.LocalCollaboration,
        $Context.LocalReports
    )
    foreach ($folder in $folders) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
}

function Get-ManifestPath {
    param([Parameter(Mandatory)] $Context)
    return Join-Path $Context.CentralControl ([string]$Context.Control.master.manifest)
}

function Assert-CentralManifest {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter()][switch] $AllowRecoveryDrift
    )

    $manifestPath = Get-ManifestPath -Context $Context
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Manifest not found: $manifestPath" }
    $hash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    if ($hash -ne [string]$Context.Control.master.manifestSha256) {
        throw "Central manifest hash mismatch for $($Context.Code)."
    }
    $comparison = Compare-DirectoryToManifest -Directory $Context.CentralMaster -ManifestPath $manifestPath
    $issueCount = $comparison.Missing.Count + $comparison.Different.Count + $comparison.Extra.Count
    if ($issueCount -gt 0) {
        if (-not ($AllowRecoveryDrift -and [string]$Context.Control.masterState -eq 'RECOVERY_REQUIRED')) {
            throw "Central master does not match its manifest: missing=$($comparison.Missing.Count), different=$($comparison.Different.Count), extra=$($comparison.Extra.Count)."
        }
        Write-Host "[RECOVERY] Central drift accepted for controlled retry: missing=$($comparison.Missing.Count), different=$($comparison.Different.Count), extra=$($comparison.Extra.Count)." -ForegroundColor Yellow
    }
    return $manifestPath
}

function Compare-DirectoryToManifest {
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $ManifestPath
    )

    $rows = @(Import-Csv -LiteralPath $ManifestPath)
    $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $missing = [System.Collections.Generic.List[string]]::new()
    $different = [System.Collections.Generic.List[string]]::new()
    $extra = [System.Collections.Generic.List[string]]::new()

    foreach ($row in $rows) {
        [void]$known.Add([string]$row.Path)
        $file = Join-Path $Directory ([string]$row.Path)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $missing.Add([string]$row.Path)
            continue
        }
        $item = Get-Item -LiteralPath $file
        if ($item.Length -ne [int64]$row.Bytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne [string]$row.SHA256) {
            $different.Add([string]$row.Path)
        }
    }
    if (Test-Path -LiteralPath $Directory -PathType Container) {
        foreach ($file in (Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)) {
            $relative = $file.FullName.Substring($Directory.Length).TrimStart('\')
            if (-not $known.Contains($relative)) { $extra.Add($relative) }
        }
    }

    [pscustomobject]@{ Missing=@($missing); Different=@($different); Extra=@($extra); ManifestRows=$rows.Count }
}

function Get-LocalChanges {
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $BaselineManifest
    )

    $rows = @(Import-Csv -LiteralPath $BaselineManifest)
    $baseline = @{}
    foreach ($row in $rows) { $baseline[[string]$row.Path] = $row }
    $newFiles = [System.Collections.Generic.List[string]]::new()
    $different = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()

    $current = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($Directory.Length).TrimStart('\')
        $current[$relative] = $file
        if (-not $baseline.ContainsKey($relative)) {
            $newFiles.Add($relative)
        }
        else {
            $row = $baseline[$relative]
            if ($file.Length -ne [int64]$row.Bytes -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne [string]$row.SHA256) {
                $different.Add($relative)
            }
        }
    }
    foreach ($row in $rows) {
        if (-not $current.ContainsKey([string]$row.Path)) { $missing.Add([string]$row.Path) }
    }
    [pscustomobject]@{ New=@($newFiles); Different=@($different); Missing=@($missing) }
}

function Compare-DirectoriesExact {
    param(
        [Parameter(Mandatory)][string] $ExpectedDirectory,
        [Parameter(Mandatory)][string] $ActualDirectory
    )

    $actual = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $ActualDirectory -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($ActualDirectory.Length).TrimStart('\')
        $actual[$relative] = $file
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    $different = [System.Collections.Generic.List[string]]::new()
    $expectedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in (Get-ChildItem -LiteralPath $ExpectedDirectory -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($ExpectedDirectory.Length).TrimStart('\')
        [void]$expectedPaths.Add($relative)
        if (-not $actual.ContainsKey($relative)) {
            $missing.Add($relative)
            continue
        }
        $actualFile = $actual[$relative]
        if ($file.Length -ne $actualFile.Length -or
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $actualFile.FullName -Algorithm SHA256).Hash) {
            $different.Add($relative)
        }
    }

    $extra = [System.Collections.Generic.List[string]]::new()
    foreach ($relative in $actual.Keys) {
        if (-not $expectedPaths.Contains($relative)) { $extra.Add($relative) }
    }
    return [pscustomobject]@{Missing=@($missing);Different=@($different);Extra=@($extra)}
}

function Write-Report {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines
    )

    New-Item -ItemType Directory -Path $Context.LocalReports -Force | Out-Null
    $path = Join-Path $Context.LocalReports ('{0}-{1}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Name)
    [System.IO.File]::WriteAllLines($path, $Lines, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Append-History {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][string] $Event,
        [Parameter(Mandatory)][string] $Details
    )

    New-Item -ItemType Directory -Path $Context.CentralHistory -Force | Out-Null
    $line = '{0} | {1} | {2}' -f (Get-Date).ToUniversalTime().ToString('o'), $Event, $Details
    Add-Content -LiteralPath (Join-Path $Context.CentralHistory 'HISTORY.log') -Value $line -Encoding UTF8
}

function Get-SabProcessInfo {
    return (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @('java.exe','javaw.exe') -and
            $_.CommandLine -match '(?i)(scripture-app-builder\.jar|org\.sil\.app\.builder\.scripture\.ScriptureAppBuilder)'
        } | Sort-Object CreationDate -Descending | Select-Object -First 1)
}

function Test-SabRunning {
    return $null -ne (Get-SabProcessInfo)
}

function Wait-SabVisibleWindow {
    param([Parameter(Mandatory)][int] $TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $processInfo = Get-SabProcessInfo
        if ($null -ne $processInfo) {
            $process = Get-Process -Id ([int]$processInfo.ProcessId) -ErrorAction SilentlyContinue
            if ($null -ne $process -and $process.MainWindowHandle -ne [IntPtr]::Zero) {
                return $process
            }
        }
        Start-Sleep -Milliseconds 500
    } until ((Get-Date) -ge $deadline)
    return $null
}

function Get-SabVersion {
    $output = & $script:SabCommand -? 2>&1 | Out-String
    [pscustomobject]@{
        Version = [regex]::Match($output, 'Version\s+([0-9.]+)').Groups[1].Value
        Release = [regex]::Match($output, 'Build Release\s+([0-9]+)').Groups[1].Value
    }
}

function Assert-SabVersion {
    param([Parameter(Mandatory)] $Context)
    $found = Get-SabVersion
    $requiredVersion = [string]$Context.Control.requiredSab.version
    $requiredRelease = [string]$Context.Control.requiredSab.release
    if ($found.Version -ne $requiredVersion -or $found.Release -ne $requiredRelease) {
        throw (Get-Text 'sab_required' @($requiredVersion, $requiredRelease, $found.Version, $found.Release))
    }
}

function Read-ProjectLock {
    param([Parameter(Mandatory)] $Context)
    if (-not (Test-Path -LiteralPath $Context.LockPath -PathType Leaf)) { return $null }
    return Read-JsonFile -Path $Context.LockPath -Retries 8
}

function Assert-LockOwner {
    param(
        [Parameter(Mandatory)] $Lock,
        [Parameter(Mandatory)] $Identity
    )
    if ([string]$Lock.userId -ne [string]$Identity.userId -or
        [string]$Lock.computerName -ne [string]$Identity.computerName -or
        [string]$Lock.windowsUser -ne [string]$Identity.windowsUser) {
        throw (Get-Text 'wrong_owner' @($Lock.displayName, $Lock.computerName))
    }
}

function Acquire-ProjectLock {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $Identity
    )

    $existing = Read-ProjectLock -Context $Context
    if ($null -ne $existing) {
        if ([string]$existing.userId -eq [string]$Identity.userId -and
            [string]$existing.computerName -eq [string]$Identity.computerName -and
            [string]$existing.windowsUser -eq [string]$Identity.windowsUser) {
            return $existing
        }
        throw (Get-Text 'lock_busy' @($existing.displayName, $existing.computerName))
    }

    $lock = [pscustomobject][ordered]@{
        schemaVersion = 1
        projectCode = $Context.Code
        token = [guid]::NewGuid().ToString('N')
        userId = [string]$Identity.userId
        displayName = [string]$Identity.displayName
        role = [string]$Identity.role
        windowsUser = [string]$Identity.windowsUser
        computerName = [string]$Identity.computerName
        acquiredUtc = (Get-Date).ToUniversalTime().ToString('o')
        baseMasterVersion = [int]$Context.Control.masterVersion
    }
    $json = $lock | ConvertTo-Json -Depth 6
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    try {
        $stream = [System.IO.File]::Open($Context.LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
    }
    catch [System.IO.IOException] {
        $owner = Read-ProjectLock -Context $Context
        if ($null -ne $owner) { throw (Get-Text 'lock_busy' @($owner.displayName, $owner.computerName)) }
        throw
    }

    Start-Sleep -Seconds ([int]$script:Config.lockConfirmationSeconds)
    $confirmed = Read-ProjectLock -Context $Context
    if ($null -eq $confirmed -or [string]$confirmed.token -ne [string]$lock.token) {
        throw 'Central lock confirmation failed. Do not work on this project.'
    }
    Append-History -Context $Context -Event 'LOCK-ACQUIRED' -Details "user=$($Identity.userId) computer=$($Identity.computerName) token=$($lock.token) baseVersion=$($lock.baseMasterVersion)"
    return $lock
}

function Release-ProjectLock {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)] $ExpectedLock,
        [Parameter(Mandatory)][string] $Event
    )

    $current = Read-ProjectLock -Context $Context
    if ($null -eq $current) { return }
    Assert-LockOwner -Lock $current -Identity $Identity
    if ([string]$current.token -ne [string]$ExpectedLock.token) { throw 'Lock token changed; refusing to release it.' }

    $archiveDirectory = Join-Path $Context.CentralHistory 'Locks'
    New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null
    $archive = Join-Path $archiveDirectory ('{0}-{1}-{2}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Event, $current.token)
    Copy-Item -LiteralPath $Context.LockPath -Destination $archive
    Remove-Item -LiteralPath $Context.LockPath -Force
    if (Test-Path -LiteralPath $Context.LocalSession -PathType Leaf) { Remove-Item -LiteralPath $Context.LocalSession -Force }
    Append-History -Context $Context -Event 'LOCK-RELEASED' -Details "user=$($Identity.userId) computer=$($Identity.computerName) event=$Event token=$($current.token)"
    Write-Host (Get-Text 'released') -ForegroundColor Green
}

function Receive-Project {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)] $Lock
    )

    Ensure-LocalProjectStructure -Context $Context
    $centralManifest = Assert-CentralManifest -Context $Context
    $localFiles = @(Get-ChildItem -LiteralPath $Context.LocalShared -Recurse -File -Force)

    if (Test-Path -LiteralPath $Context.LocalBaseline -PathType Leaf) {
        $dirty = Compare-DirectoryToManifest -Directory $Context.LocalShared -ManifestPath $Context.LocalBaseline
        if ($dirty.Missing.Count + $dirty.Different.Count + $dirty.Extra.Count -gt 0) {
            $reportLines = @('LOCAL CHANGES BLOCK RECEIVE','', 'MISSING:') + $dirty.Missing + @('', 'DIFFERENT:') + $dirty.Different + @('', 'EXTRA:') + $dirty.Extra
            $report = Write-Report -Context $Context -Name 'RECEIVE-BLOCKED-LOCAL-CHANGES' -Lines $reportLines
            throw (Get-Text 'dirty_receive' @($report))
        }
    }
    elseif ($localFiles.Count -gt 0) {
        $initial = Compare-DirectoryToManifest -Directory $Context.LocalShared -ManifestPath $centralManifest
        if ($initial.Missing.Count + $initial.Different.Count + $initial.Extra.Count -gt 0) {
            $reportLines = @('INITIAL LOCAL COPY DOES NOT MATCH CENTRAL MASTER','', 'MISSING:') + $initial.Missing + @('', 'DIFFERENT:') + $initial.Different + @('', 'EXTRA:') + $initial.Extra
            $report = Write-Report -Context $Context -Name 'RECEIVE-BLOCKED-INITIAL-MISMATCH' -Lines $reportLines
            throw (Get-Text 'dirty_receive' @($report))
        }
    }

    Write-Host (Get-Text 'receiving' @($Context.Control.masterVersion)) -ForegroundColor Cyan
    & robocopy.exe $Context.CentralMaster $Context.LocalShared /E /COPY:DAT /DCOPY:DAT /R:2 /W:3 /Z /FFT /XJ /NP /NFL /NDL | Out-Null
    $copyExit = $LASTEXITCODE
    if ($copyExit -ge 8) { throw "Receive copy failed with robocopy exit code $copyExit." }

    $verified = Compare-DirectoryToManifest -Directory $Context.LocalShared -ManifestPath $centralManifest
    if ($verified.Missing.Count + $verified.Different.Count + $verified.Extra.Count -gt 0) {
        throw 'Local verification failed after receive. The lock remains active.'
    }
    Copy-Item -LiteralPath $centralManifest -Destination $Context.LocalBaseline -Force
    $state = [pscustomobject][ordered]@{
        schemaVersion = 1
        projectCode = $Context.Code
        receivedMasterVersion = [int]$Context.Control.masterVersion
        manifest = [string]$Context.Control.master.manifest
        manifestSha256 = [string]$Context.Control.master.manifestSha256
        receivedUtc = (Get-Date).ToUniversalTime().ToString('o')
        userId = [string]$Identity.userId
        computerName = [string]$Identity.computerName
    }
    Write-JsonAtomic -Value $state -Path $Context.LocalState
    $session = [pscustomobject][ordered]@{
        schemaVersion = 1
        projectCode = $Context.Code
        lockToken = [string]$Lock.token
        receivedMasterVersion = [int]$Context.Control.masterVersion
        userId = [string]$Identity.userId
        computerName = [string]$Identity.computerName
        startedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-JsonAtomic -Value $session -Path $Context.LocalSession
    Append-History -Context $Context -Event 'RECEIVE' -Details "user=$($Identity.userId) computer=$($Identity.computerName) version=$($Context.Control.masterVersion) manifest=$($Context.Control.master.manifest)"
    Write-Host (Get-Text 'receive_ok' @($Context.Control.masterVersion)) -ForegroundColor Green
}

function Get-PrimaryAppDefinitions {
    param([Parameter(Mandatory)] $Context)
    return @(
        Get-ChildItem -LiteralPath (Join-Path $Context.LocalShared 'App Projects') -Recurse -File -Filter '*.appDef' -Force |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName ($_.BaseName + '_data')) -PathType Container } |
            Sort-Object FullName
    )
}

function Select-AppDefinition {
    param([Parameter(Mandatory)] $Context)
    $definitions = @(Get-PrimaryAppDefinitions -Context $Context)
    if ($definitions.Count -eq 0) { throw "No primary app definition found for $($Context.Code)." }
    if ($definitions.Count -eq 1 -or $Action -ne 'Menu') { return $definitions[0] }
    for ($index=0; $index -lt $definitions.Count; $index++) { Write-Host ('  {0}. {1}' -f ($index+1), $definitions[$index].BaseName) }
    $choiceText = Read-Host 'App'
    Write-Host "[TRACE] app => $choiceText" -ForegroundColor DarkGray
    $choice = 0
    if (-not [int]::TryParse($choiceText,[ref]$choice) -or $choice -lt 1 -or $choice -gt $definitions.Count) { throw 'Invalid app selection.' }
    return $definitions[$choice-1]
}

function Set-SabFolder {
    param([Parameter(Mandatory)][xml]$Settings,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Value)
    $node = $Settings.SelectSingleNode("//folder[@name='$Name']")
    if ($null -eq $node) { throw "SAB settings folder entry not found: $Name" }
    $node.InnerText = $Value
}

function Configure-And-StartSab {
    param([Parameter(Mandatory)] $Context)

    $appDefFile = Select-AppDefinition -Context $Context
    [xml]$appDefinition = Get-Content -LiteralPath $appDefFile.FullName -Raw
    $projectName = [string]$appDefinition.'app-definition'.'project-name'
    $settingsPath = Join-Path $env:APPDATA 'SIL\App Builder\settings.xml'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw "SAB settings not found: $settingsPath" }
    $settingsBackup = Join-Path $Context.LocalPrivate ('Backups\Settings\settings-before-{0}-{1}.xml' -f $Context.Code,(Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $settingsPath -Destination $settingsBackup
    [xml]$settings = Get-Content -LiteralPath $settingsPath -Raw

    $folders = [ordered]@{
        'apk.output' = Join-Path $Context.LocalPrivate 'App Output\Apk'
        'epub.output' = Join-Path $Context.LocalPrivate 'App Output\Epub'
        'pwa.output' = Join-Path $Context.LocalPrivate 'App Output\PWA'
        'html.output' = Join-Path $Context.LocalPrivate 'App Output\HTML'
        'build' = Join-Path $Context.LocalPrivate 'temp_build'
        'app.def' = Join-Path $Context.LocalShared 'App Projects'
        'keystore' = Join-Path $Context.LocalShared 'Keystore'
        'downloads' = Join-Path $Context.LocalPrivate 'Timings'
        'audio' = Join-Path $Context.LocalShared 'Resources\Audio'
        'audio-timing' = Join-Path $Context.LocalPrivate 'Timings'
        'books' = Join-Path $Context.LocalShared 'Contents'
        'contents' = Join-Path $Context.LocalShared 'Contents'
        'fonts' = Join-Path $Context.LocalShared 'Resources\Fonts'
        'images' = Join-Path $Context.LocalShared 'Resources'
    }
    foreach ($entry in $folders.GetEnumerator()) {
        New-Item -ItemType Directory -Path $entry.Value -Force | Out-Null
        Set-SabFolder -Settings $settings -Name $entry.Key -Value $entry.Value
    }
    $apps = $settings.SelectSingleNode('/settings/apps')
    if ($null -eq $apps) { throw 'SAB settings apps section not found.' }
    $apps.RemoveAll()
    $app = $settings.CreateElement('app')
    $name = $settings.CreateElement('name'); $name.InnerText = $projectName
    $filename = $settings.CreateElement('filename'); $filename.InnerText = $appDefFile.FullName
    [void]$app.AppendChild($name); [void]$app.AppendChild($filename); [void]$apps.AppendChild($app)

    $writerSettings = [System.Xml.XmlWriterSettings]::new()
    $writerSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $writerSettings.Indent = $true
    $writerSettings.NewLineChars = "`r`n"
    $writer = [System.Xml.XmlWriter]::Create($settingsPath,$writerSettings)
    try { $settings.Save($writer) } finally { $writer.Dispose() }

    if ($NoLaunch) { return }
    $launcher = Join-Path (Split-Path -Parent $script:SabCommand) 'sab.vbs'
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $launcher) -WorkingDirectory (Split-Path -Parent $launcher)
    $windowTimeoutSeconds = if ($script:Config.PSObject.Properties['sabWindowTimeoutSeconds']) { [int]$script:Config.sabWindowTimeoutSeconds } else { 60 }
    $visibleSab = Wait-SabVisibleWindow -TimeoutSeconds $windowTimeoutSeconds
    if ($null -eq $visibleSab) {
        if (Test-SabRunning) { throw (Get-Text 'sab_window_missing' @($windowTimeoutSeconds)) }
        throw (Get-Text 'sab_launch_failed')
    }
    $shell = New-Object -ComObject WScript.Shell
    [void]$shell.AppActivate($visibleSab.Id)
    Write-Host "[TRACE] SAB visible: pid=$($visibleSab.Id); title=$($visibleSab.MainWindowTitle)" -ForegroundColor DarkGray
    Write-Host (Get-Text 'sab_started') -ForegroundColor Green
}

function Test-ChangedAppDefinitions {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][string[]] $RelativePaths
    )
    foreach ($relative in ($RelativePaths | Where-Object { [System.IO.Path]::GetExtension($_) -ieq '.appDef' })) {
        $localPath = Join-Path $Context.LocalShared $relative
        try { [xml]$null = Get-Content -LiteralPath $localPath -Raw } catch { throw "Invalid appDef XML: $relative" }
        $newText = Get-Content -LiteralPath $localPath -Raw
        $oldPath = Join-Path $Context.CentralMaster $relative
        $oldText = if (Test-Path -LiteralPath $oldPath -PathType Leaf) { Get-Content -LiteralPath $oldPath -Raw } else { '' }
        $newRefs = @([regex]::Matches($newText,'[A-Za-z]:\\[^<\r\n]+') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Value.Trim()) } | Sort-Object -Unique)
        $oldRefs = @([regex]::Matches($oldText,'[A-Za-z]:\\[^<\r\n]+') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Value.Trim()) } | Sort-Object -Unique)
        foreach ($reference in ($newRefs | Where-Object { $_ -notin $oldRefs })) {
            $normalizedReference = [System.IO.Path]::GetFullPath($reference)
            $normalizedRoot = [System.IO.Path]::GetFullPath($Context.LocalShared).TrimEnd('\') + '\'
            if (-not $normalizedReference.StartsWith($normalizedRoot,[System.StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $normalizedReference)) {
                throw "New unsafe or unavailable external reference in $relative : $reference"
            }
        }
    }
}

function New-MasterManifest {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][int] $Version
    )
    $rows = foreach ($file in (Get-ChildItem -LiteralPath $Context.CentralMaster -Recurse -File -Force | Sort-Object FullName)) {
        [pscustomobject]@{
            Path = $file.FullName.Substring($Context.CentralMaster.Length).TrimStart('\')
            Bytes = $file.Length
            SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
    $name = 'MASTER-MANIFEST-v{0:D4}.csv' -f $Version
    $path = Join-Path $Context.CentralControl $name
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $rows | Export-Csv -LiteralPath $temporary -NoTypeInformation -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $path -Force
    [pscustomobject]@{
        Name=$name; Path=$path; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Count=@($rows).Count; Bytes=(@($rows) | Measure-Object Bytes -Sum).Sum
    }
}

function Send-Project {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $Identity
    )
    if (Test-SabRunning) { throw (Get-Text 'sab_running') }
    Ensure-LocalProjectStructure -Context $Context
    $lock = Read-ProjectLock -Context $Context
    if ($null -eq $lock) { throw 'No active project lock. Use START WORK first.' }
    Assert-LockOwner -Lock $lock -Identity $Identity
    if (-not (Test-Path -LiteralPath $Context.LocalSession -PathType Leaf)) { throw 'Local work session not found.' }
    $session = Read-JsonFile -Path $Context.LocalSession
    if ([string]$session.lockToken -ne [string]$lock.token) { throw 'Local session token does not match the central lock.' }

    $freshContext = Get-ProjectContext -Code $Context.Code
    if ([int]$freshContext.Control.masterVersion -ne [int]$session.receivedMasterVersion) {
        throw 'Central master version changed after receive. Send is blocked.'
    }
    [void](Assert-CentralManifest -Context $freshContext -AllowRecoveryDrift)
    if (-not (Test-Path -LiteralPath $Context.LocalBaseline -PathType Leaf)) { throw 'Local baseline manifest not found.' }
    $changes = Get-LocalChanges -Directory $Context.LocalShared -BaselineManifest $Context.LocalBaseline
    $deletedPaths = @($changes.Missing | Sort-Object -Unique)
    if ($changes.Missing.Count -gt 0) {
        $report = Write-Report -Context $Context -Name 'SEND-DELETIONS-REQUIRE-AUTHORIZATION' -Lines (@('LOCAL DELETIONS DETECTED - AUTHORIZATION REQUIRED','') + $deletedPaths)
        Write-Host (Get-Text 'deleted_detected' @($deletedPaths.Count,$report)) -ForegroundColor Yellow
        foreach ($relativePath in $deletedPaths) {
            Write-Host ('  - {0}' -f $relativePath) -ForegroundColor Red
        }
        Write-Host (Get-Text 'deleted_backup_notice') -ForegroundColor Yellow
        $confirmation = (Read-Host (Get-Text 'deleted_password_prompt')).Trim()
        if ($confirmation -cne (Get-DeletionConfirmationWord)) {
            throw (Get-Text 'deleted_cancelled')
        }
        Write-Host (Get-Text 'deleted_authorized' @($deletedPaths.Count)) -ForegroundColor Yellow
    }
    $changedPaths = @($changes.Different + $changes.New | Sort-Object -Unique)
    if ($changedPaths.Count + $deletedPaths.Count -eq 0) {
        Write-Host (Get-Text 'no_changes') -ForegroundColor Cyan
        Release-ProjectLock -Context $Context -Identity $Identity -ExpectedLock $lock -Event 'NO-CHANGES'
        return
    }

    Test-ChangedAppDefinitions -Context $Context -RelativePaths $changedPaths
    Write-Host (Get-Text 'sending_with_deletions' @($changedPaths.Count,$deletedPaths.Count)) -ForegroundColor Cyan
    $nextVersion = [int]$freshContext.Control.masterVersion + 1
    $transactionId = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'),$Identity.userId,[guid]::NewGuid().ToString('N').Substring(0,8)
    $incoming = Join-Path $freshContext.CentralControl ('INCOMING\' + $transactionId)
    $backup = Join-Path $freshContext.CentralBackups ('v{0:D4}-before-v{1:D4}-{2}' -f [int]$freshContext.Control.masterVersion,$nextVersion,(Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $incoming,$backup -Force | Out-Null

    foreach ($relative in $changedPaths) {
        $source = Join-Path $Context.LocalShared $relative
        $staged = Join-Path $incoming $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $staged) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $staged
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash) {
            throw "Staging verification failed: $relative"
        }
    }
    foreach ($relative in @($changedPaths + $deletedPaths | Sort-Object -Unique)) {
        $oldMaster = Join-Path $freshContext.CentralMaster $relative
        if (Test-Path -LiteralPath $oldMaster -PathType Leaf) {
            $backupFile = Join-Path $backup $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupFile) -Force | Out-Null
            Copy-Item -LiteralPath $oldMaster -Destination $backupFile
        }
    }
    $transaction = [pscustomobject][ordered]@{
        schemaVersion=1; transactionId=$transactionId; status='STAGED'; projectCode=$Context.Code
        fromVersion=[int]$freshContext.Control.masterVersion; toVersion=$nextVersion
        userId=[string]$Identity.userId; computerName=[string]$Identity.computerName
        createdUtc=(Get-Date).ToUniversalTime().ToString('o'); files=$changedPaths; deletedFiles=$deletedPaths
    }
    Write-JsonAtomic -Value $transaction -Path (Join-Path $incoming 'TRANSACTION.json')

    $applyStarted = $false
    try {
        $applyStarted = $true
        foreach ($relative in $changedPaths) {
            $staged = Join-Path $incoming $relative
            $target = Join-Path $freshContext.CentralMaster $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $staged -Destination $target -Force
            if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
                throw "Central verification failed: $relative"
            }
        }
        foreach ($relative in $deletedPaths) {
            $target = Join-Path $freshContext.CentralMaster $relative
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                Write-Host "[RECOVERY] Already absent from central master: $relative" -ForegroundColor DarkYellow
                continue
            }
            Remove-Item -LiteralPath $target -Force
            if (Test-Path -LiteralPath $target) {
                throw "Central deletion verification failed: $relative"
            }
        }
        Write-Host (Get-Text 'verifying_complete_master') -ForegroundColor Cyan
        $finalComparison = Compare-DirectoriesExact -ExpectedDirectory $Context.LocalShared -ActualDirectory $freshContext.CentralMaster
        if ($finalComparison.Missing.Count + $finalComparison.Different.Count + $finalComparison.Extra.Count -gt 0) {
            Write-Host "[RECOVERY] Final master mismatch: missing=$($finalComparison.Missing.Count), different=$($finalComparison.Different.Count), extra=$($finalComparison.Extra.Count)." -ForegroundColor Red
            foreach ($relative in $finalComparison.Missing) { Write-Host "  - MISSING: $relative" -ForegroundColor Red }
            foreach ($relative in $finalComparison.Different) { Write-Host "  - DIFFERENT: $relative" -ForegroundColor Red }
            foreach ($relative in $finalComparison.Extra) { Write-Host "  - EXTRA: $relative" -ForegroundColor Red }
            throw 'Central master does not exactly match the local project after apply.'
        }
        $manifest = New-MasterManifest -Context $freshContext -Version $nextVersion
        $projectMetadataBackup = Join-Path $backup 'PROJECT-before-send.json'
        Copy-Item -LiteralPath $freshContext.ProjectControlPath -Destination $projectMetadataBackup
        $freshContext.Control.masterVersion = $nextVersion
        $freshContext.Control.masterState = 'VERIFIED'
        $freshContext.Control.teamUseAllowed = $true
        $freshContext.Control.workflowState = 'ACTIVE'
        $freshContext.Control.workflowReason = 'Collaboration safeguards active.'
        $freshContext.Control.master.manifest = $manifest.Name
        $freshContext.Control.master.manifestSha256 = $manifest.Hash
        $freshContext.Control.master.fileCount = $manifest.Count
        $freshContext.Control.master.totalBytes = $manifest.Bytes
        $freshContext.Control | Add-Member -NotePropertyName lastSend -NotePropertyValue ([pscustomobject][ordered]@{
            utc=(Get-Date).ToUniversalTime().ToString('o'); userId=$Identity.userId; displayName=$Identity.displayName
            computerName=$Identity.computerName; transactionId=$transactionId; changedFiles=$changedPaths.Count
            deletedFiles=$deletedPaths.Count
        }) -Force
        Write-JsonAtomic -Value $freshContext.Control -Path $freshContext.ProjectControlPath
        Copy-Item -LiteralPath $manifest.Path -Destination $Context.LocalBaseline -Force
        $state = Read-JsonFile -Path $Context.LocalState
        $state.receivedMasterVersion = $nextVersion
        $state.manifest = $manifest.Name
        $state.manifestSha256 = $manifest.Hash
        $state | Add-Member -NotePropertyName sentUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        Write-JsonAtomic -Value $state -Path $Context.LocalState
        $transaction.status = 'COMPLETED'
        $transaction | Add-Member -NotePropertyName completedUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        Write-JsonAtomic -Value $transaction -Path (Join-Path $incoming 'TRANSACTION.json')
        $transactions = Join-Path $freshContext.CentralHistory 'Transactions'
        New-Item -ItemType Directory -Path $transactions -Force | Out-Null
        Move-Item -LiteralPath $incoming -Destination (Join-Path $transactions $transactionId)
        Append-History -Context $freshContext -Event 'SEND' -Details "user=$($Identity.userId) computer=$($Identity.computerName) fromVersion=$($nextVersion-1) toVersion=$nextVersion changed=$($changedPaths.Count) deleted=$($deletedPaths.Count) transaction=$transactionId"
        Release-ProjectLock -Context $freshContext -Identity $Identity -ExpectedLock $lock -Event ('SEND-v' + $nextVersion)
        Write-Host (Get-Text 'send_ok' @($nextVersion)) -ForegroundColor Green
    }
    catch {
        if ($applyStarted) {
            try {
                $freshContext.Control.masterState = 'RECOVERY_REQUIRED'
                $freshContext.Control.teamUseAllowed = $false
                $freshContext.Control.workflowState = 'BLOCKED'
                $freshContext.Control.workflowReason = "Send transaction failed: $transactionId"
                Write-JsonAtomic -Value $freshContext.Control -Path $freshContext.ProjectControlPath
                Append-History -Context $freshContext -Event 'SEND-FAILED' -Details "transaction=$transactionId error=$($_.Exception.Message)"
            } catch { }
        }
        throw
    }
}

function Release-CleanProject {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Identity)
    if (Test-SabRunning) { throw (Get-Text 'sab_running') }
    $lock = Read-ProjectLock -Context $Context
    if ($null -eq $lock) { throw 'No active project lock.' }
    Assert-LockOwner -Lock $lock -Identity $Identity
    if (-not (Test-Path -LiteralPath $Context.LocalBaseline -PathType Leaf)) { throw 'Local baseline not found.' }
    $changes = Get-LocalChanges -Directory $Context.LocalShared -BaselineManifest $Context.LocalBaseline
    if ($changes.New.Count + $changes.Different.Count + $changes.Missing.Count -gt 0) {
        $report = Write-Report -Context $Context -Name 'RELEASE-BLOCKED-LOCAL-CHANGES' -Lines (@('LOCAL CHANGES PREVENT CLEAN RELEASE','','NEW:')+$changes.New+@('','DIFFERENT:')+$changes.Different+@('','MISSING:')+$changes.Missing)
        throw "Local changes exist. Send them or keep the lock. Report: $report"
    }
    Release-ProjectLock -Context $Context -Identity $Identity -ExpectedLock $lock -Event 'CLEAN-RELEASE'
}

function Show-ProjectStatus {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Identity)
    $fresh = Get-ProjectContext -Code $Context.Code
    Write-Host ''
    Write-Host (Get-Text 'identity' @($Identity.displayName,$Identity.computerName))
    Write-Host (Get-Text 'master_version' @($fresh.Control.masterVersion))
    Write-Host ((Get-Text 'status_line') -f $fresh.Control.masterState,$fresh.Control.workflowState,$fresh.Control.teamUseAllowed)
    $lock = Read-ProjectLock -Context $fresh
    if ($null -eq $lock) { Write-Host (Get-Text 'unlocked') -ForegroundColor Green }
    else { Write-Host (Get-Text 'locked_by' @($lock.displayName,$lock.computerName,$lock.acquiredUtc)) -ForegroundColor Yellow }
}

function Show-Help {
    Write-Host ''
    foreach ($line in @($script:messages.help_lines)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { Write-Host '' }
        elseif ([string]$line -match '^## ') { Write-Host ([string]$line).Substring(3) -ForegroundColor Cyan }
        else { Write-Host ([string]$line) }
    }
}

function Show-ResourceChangeList {
    param(
        [Parameter(Mandatory)][string] $HeadingKey,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Paths,
        [Parameter()][ConsoleColor] $Color = [ConsoleColor]::Gray
    )
    if ($Paths.Count -eq 0) { return }
    Write-Host (Get-Text $HeadingKey) -ForegroundColor $Color
    foreach ($path in $Paths) { Write-Host ('  - {0}' -f $path) -ForegroundColor $Color }
}

function Invoke-ResourcePreparation {
    param([Parameter(Mandatory)] $Context)

    $picturesPath = Join-Path $Context.LocalShared 'Resources'
    $audioPath = Join-Path $Context.LocalShared 'Resources\Audio'
    New-Item -ItemType Directory -Force -Path $picturesPath, $audioPath | Out-Null

    while ($true) {
        Write-Host ''
        Write-Host (Get-Text 'prepare_resources') -ForegroundColor Yellow
        Write-Host ('  1. {0}' -f (Get-Text 'prepare_none'))
        Write-Host ('  2. {0}' -f (Get-Text 'prepare_pictures'))
        Write-Host ('  3. {0}' -f (Get-Text 'prepare_audio'))
        Write-Host ('  4. {0}' -f (Get-Text 'prepare_both'))
        $choice = Read-Host '1 / 2 / 3 / 4'
        Write-Host "[TRACE] resources => $choice" -ForegroundColor DarkGray
        if ($choice -eq '1') { return }
        if ($choice -notin @('2', '3', '4')) { continue }

        $folders = @()
        if ($choice -in @('2', '4')) { $folders += $picturesPath }
        if ($choice -in @('3', '4')) { $folders += $audioPath }
        foreach ($folder in $folders) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder)
            Write-Host (Get-Text 'resource_folder_opened' @($folder)) -ForegroundColor Cyan
        }

        Write-Host (Get-Text 'resource_copy_instructions') -ForegroundColor Yellow
        [void](Read-Host (Get-Text 'resource_done_prompt'))

        $changes = Get-LocalChanges -Directory $Context.LocalShared -BaselineManifest $Context.LocalBaseline
        $newResources = @($changes.New | Where-Object { $_ -like 'Resources\*' } | Sort-Object)
        $changedResources = @($changes.Different | Where-Object { $_ -like 'Resources\*' } | Sort-Object)
        $missingResources = @($changes.Missing | Where-Object { $_ -like 'Resources\*' } | Sort-Object)

        Write-Host (Get-Text 'resource_summary' @($newResources.Count, $changedResources.Count, $missingResources.Count)) -ForegroundColor Cyan
        Show-ResourceChangeList -HeadingKey 'resource_new_heading' -Paths $newResources -Color Green
        Show-ResourceChangeList -HeadingKey 'resource_changed_heading' -Paths $changedResources -Color Yellow
        Show-ResourceChangeList -HeadingKey 'resource_missing_heading' -Paths $missingResources -Color Red

        if ($newResources.Count + $changedResources.Count + $missingResources.Count -eq 0) {
            Write-Host (Get-Text 'resource_no_changes') -ForegroundColor Yellow
            return
        }
        if ($missingResources.Count -gt 0) {
            Write-Host (Get-Text 'resource_missing_warning') -ForegroundColor Red
        }
        if ($changedResources.Count -gt 0) {
            Write-Host (Get-Text 'resource_replacement_warning' @($changedResources.Count)) -ForegroundColor Yellow
            $replacementChoice = Read-Host (Get-Text 'resource_replacement_choice')
            if ($replacementChoice -ne '1') {
                Write-Host (Get-Text 'resource_reopen') -ForegroundColor Yellow
                continue
            }
        }
        return
    }
}

function Start-TeamWork {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Identity)
    if (Test-SabRunning) { throw (Get-Text 'sab_running') }
    if ($Context.Control.teamUseAllowed -ne $true -or [string]$Context.Control.masterState -ne 'VERIFIED') {
        throw (Get-Text 'not_active' @($Context.Control.workflowReason))
    }
    Assert-SabVersion -Context $Context
    $lock = Acquire-ProjectLock -Context $Context -Identity $Identity
    Write-Host (Get-Text 'lock_acquired') -ForegroundColor Green
    try {
        Receive-Project -Context $Context -Identity $Identity -Lock $lock
    }
    catch {
        try { Release-ProjectLock -Context $Context -Identity $Identity -ExpectedLock $lock -Event 'RECEIVE-FAILED' } catch { }
        throw
    }
    if (-not $NoLaunch) {
        Invoke-ResourcePreparation -Context $Context
        Configure-And-StartSab -Context $Context
    }
}

function Force-AdminUnlock {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Identity,[Parameter(Mandatory)][string]$UnlockReason)
    if ([string]$Identity.role -ne 'administrator') { throw (Get-Text 'admin_only') }
    if ([string]::IsNullOrWhiteSpace($UnlockReason)) { throw (Get-Text 'admin_reason') }
    $lock = Read-ProjectLock -Context $Context
    if ($null -eq $lock) { return }
    $archiveDirectory = Join-Path $Context.CentralHistory 'Locks'
    New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null
    $archive = Join-Path $archiveDirectory ('{0}-ADMIN-UNLOCK-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'),$lock.token)
    Copy-Item -LiteralPath $Context.LockPath -Destination $archive
    $record = [pscustomobject][ordered]@{utc=(Get-Date).ToUniversalTime().ToString('o');administrator=$Identity.userId;computer=$Identity.computerName;reason=$UnlockReason;previousLock=$lock}
    Write-JsonAtomic -Value $record -Path ($archive + '.reason.json')
    Remove-Item -LiteralPath $Context.LockPath -Force
    Append-History -Context $Context -Event 'ADMIN-UNLOCK' -Details "administrator=$($Identity.userId) previousOwner=$($lock.userId) reason=$UnlockReason"
}

function Select-ProjectCode {
    $projects = @(Get-CentralProjects)
    if ($projects.Count -eq 0) { throw (Get-Text 'no_projects') }
    Write-Host ''
    Write-Host (Get-Text 'choose_project') -ForegroundColor Yellow
    for ($index=0;$index -lt $projects.Count;$index++) { Write-Host ('  {0}. {1}' -f ($index+1),$projects[$index].Name) }
    $choiceText = Read-Host (Get-Text 'number_prompt')
    Write-Host "[TRACE] project => $choiceText" -ForegroundColor DarkGray
    $choice = 0
    if (-not [int]::TryParse($choiceText,[ref]$choice) -or $choice -lt 1 -or $choice -gt $projects.Count) { throw "Invalid project selection: $choiceText" }
    return $projects[$choice-1].Name
}

function Invoke-TeamMenu {
    param([Parameter(Mandatory)]$Identity)
    while ($true) {
        Write-Host ''
        $menuTitle = Get-Text 'menu_title' @((Get-TeamName))
        Write-Host $menuTitle -ForegroundColor Cyan
        Write-Host (Get-Text 'identity' @($Identity.displayName,$Identity.computerName))
        $code = Select-ProjectCode
        $context = Get-ProjectContext -Code $code
        Show-ProjectStatus -Context $context -Identity $Identity
        Write-Host ''
        Write-Host (Get-Text 'choose_action') -ForegroundColor Yellow
        Write-Host ('  1. {0}' -f (Get-Text 'start_work'))
        Write-Host ('  2. {0}' -f (Get-Text 'send_finish'))
        Write-Host ('  3. {0}' -f (Get-Text 'release_clean'))
        Write-Host ('  4. {0}' -f (Get-Text 'status'))
        Write-Host ('  5. {0}' -f (Get-Text 'need_help'))
        Write-Host ('  6. {0}' -f (Get-Text 'change_identity'))
        Write-Host ('  0. {0}' -f (Get-Text 'exit'))
        $choice = Read-Host '0 / 1 / 2 / 3 / 4 / 5 / 6'
        Write-Host "[TRACE] action => $choice" -ForegroundColor DarkGray
        switch ($choice) {
            '1' { Start-TeamWork -Context $context -Identity $Identity; return }
            '2' { Send-Project -Context $context -Identity $Identity; return }
            '3' { Release-CleanProject -Context $context -Identity $Identity; return }
            '4' { Show-ProjectStatus -Context $context -Identity $Identity; [void](Read-Host (Get-Text 'press_key')) }
            '5' { Show-Help; [void](Read-Host (Get-Text 'press_key')) }
            '6' { $language = Select-Language; Import-Messages -Language $language; $Identity = Set-TeamIdentity -SelectedUserId '' -Language $language }
            '0' { return }
            default { throw "Invalid action selection: $choice" }
        }
    }
}

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Team config not found: $configPath" }
$script:Config = Read-JsonFile -Path $configPath
$script:LocalRoot = if ([string]::IsNullOrWhiteSpace($LocalRoot)) { [string]$script:Config.localRoot } else { [System.IO.Path]::GetFullPath($LocalRoot).TrimEnd('\') }
$script:CentralRoot = if ([string]::IsNullOrWhiteSpace($CentralRoot)) { [string]$script:Config.centralRoot } else { [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\') }
$script:SabCommand = [string]$script:Config.sabCommand

if ([string]::IsNullOrWhiteSpace($UiLanguage)) {
    if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
        try { $UiLanguage = [string](Read-JsonFile -Path $identityPath).uiLanguage } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($UiLanguage)) { $UiLanguage = Select-Language }
}
Import-Messages -Language $UiLanguage

if ($Action -eq 'Identify') {
    [void](Set-TeamIdentity -SelectedUserId $UserId -Language $UiLanguage)
    return
}

if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
    [void](Set-TeamIdentity -SelectedUserId $UserId -Language $UiLanguage)
}
$identity = Get-TeamIdentity

if ($Action -eq 'Menu') { Invoke-TeamMenu -Identity $identity; return }
if ($Action -eq 'Help') { Show-Help; return }
if ([string]::IsNullOrWhiteSpace($Project)) { throw 'Specify -Project for this action.' }
$context = Get-ProjectContext -Code $Project

switch ($Action) {
    'Status' { Show-ProjectStatus -Context $context -Identity $identity }
    'StartWork' { Start-TeamWork -Context $context -Identity $identity }
    'SendFinish' { Send-Project -Context $context -Identity $identity }
    'ReleaseClean' { Release-CleanProject -Context $context -Identity $identity }
    'AdminUnlock' { Force-AdminUnlock -Context $context -Identity $identity -UnlockReason $Reason }
}
