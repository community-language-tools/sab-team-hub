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
    ./Invoke-Tests.ps1 -HubSource '../src'
#>

[CmdletBinding()]
param(
    # Folder holding the hub script, TeamConfig.json, Users.json and Languages/.
    [Parameter(Mandatory)]
    [string] $HubSource,

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

$resolvedSource = (Resolve-Path -LiteralPath $HubSource).Path
Write-Host ("Testing: {0}" -f $resolvedSource) -ForegroundColor Cyan

$container = New-PesterContainer -Path (Join-Path $PSScriptRoot '*.Tests.ps1') -Data @{
    HubSource        = $resolvedSource
    HubScriptName    = $HubScriptName
    ConfirmationWord = $ConfirmationWord
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

$result = Invoke-Pester -Configuration $config
exit $result.FailedCount
