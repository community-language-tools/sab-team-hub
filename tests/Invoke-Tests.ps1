<#
.SYNOPSIS
    Runs the test suite against a given copy of the scripts.

.DESCRIPTION
    The suite deliberately does not know where the code lives. Point it at whichever copy
    you want to verify -- the original deployment, or this repository's own src/ -- and the
    same tests must pass against both.

.EXAMPLE
    # Against an existing deployment, whose script has a different filename:
    ./Invoke-Tests.ps1 -HubSource 'C:\path\to\deployment' -HubScriptName 'Existing-Script.ps1'

.EXAMPLE
    # Against this repository's own code:
    ./Invoke-Tests.ps1 -RepoRoot '..'
#>

[CmdletBinding(DefaultParameterSetName = 'Deployment')]
param(
    # Folder holding the hub script, TeamConfig.json, Users.json and Languages/ side by
    # side, the way an installed Hub has them.
    [Parameter(Mandatory, ParameterSetName = 'Deployment')]
    [string] $HubSource,

    # This repository's root. The repository is not laid out like an installed Hub -- code,
    # user-facing text and example configuration live in separate folders on purpose -- so
    # a Hub is assembled from them in TEMP and the same tests run against that. The
    # assembly is exactly what an installer has to do, which is why it is worth testing.
    [Parameter(Mandatory, ParameterSetName = 'Repository')]
    [string] $RepoRoot,

    # Defaults to this repository's own script name. Pass the deployment's filename
    # explicitly when testing against an existing install.
    [string] $HubScriptName = 'SAB-Team-Hub.ps1',

    # Pass the confirmation word the code under test actually expects.
    [string] $ConfirmationWord = 'CONFIRM',

    # Write an NUnit XML report here, for CI to pick up.
    [string] $ResultsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module Pester -MinimumVersion 5.0.0 -Force
Write-Host ("Pester {0}" -f (Get-Module Pester).Version) -ForegroundColor Cyan

$assembled = $null
$resolvedRepoRoot = ''
if ($PSCmdlet.ParameterSetName -eq 'Repository') {
    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $resolvedRepoRoot = $repo
    $assembled = Join-Path ([IO.Path]::GetTempPath()) ('sabhub-src-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $assembled, (Join-Path $assembled 'Languages') | Out-Null

    # Every script in src/, not just the one under test: an installer installs the whole
    # set, and the provisioning script has to sit beside the Hub the way it really will.
    $srcRoot = Join-Path $repo 'src'
    if (-not (Test-Path -LiteralPath (Join-Path $srcRoot $HubScriptName) -PathType Leaf)) {
        throw ("Not found in src/: {0}" -f $HubScriptName)
    }
    Get-ChildItem -LiteralPath $srcRoot -File -Filter '*.ps1' |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $assembled $_.Name) }
    Copy-Item -LiteralPath (Join-Path $repo (Join-Path 'config' 'team.example.json')) -Destination (Join-Path $assembled 'TeamConfig.json')
    Get-ChildItem -LiteralPath (Join-Path $repo 'languages') -File -Filter '*.json' |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $assembled 'Languages') }

    $HubSource = $assembled
    Write-Host ("Assembled a Hub from {0}" -f $repo) -ForegroundColor Cyan
}

$resolvedSource = (Resolve-Path -LiteralPath $HubSource).Path
Write-Host ("Testing: {0}" -f $resolvedSource) -ForegroundColor Cyan

$container = New-PesterContainer -Path (Join-Path $PSScriptRoot '*.Tests.ps1') -Data @{
    HubSource        = $resolvedSource
    HubScriptName    = $HubScriptName
    ConfirmationWord = $ConfirmationWord
    # Empty when testing an installed deployment: the installer needs a repository to
    # install FROM, which a deployment is not. Tests that need it skip when it is empty.
    RepoRoot         = $resolvedRepoRoot
}

$config = New-PesterConfiguration
$config.Run.Container = $container
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'

if ($ResultsPath) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = $ResultsPath
    $config.TestResult.OutputFormat = 'NUnitXml'
}

try { $result = Invoke-Pester -Configuration $config }
finally {
    if ($assembled -and (Test-Path -LiteralPath $assembled)) {
        Remove-Item -LiteralPath $assembled -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit $result.FailedCount
