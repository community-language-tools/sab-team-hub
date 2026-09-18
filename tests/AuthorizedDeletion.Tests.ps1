#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Deleting files from the central master requires explicit authorization.

.DESCRIPTION
    The path to the scripts under test is a PARAMETER, never hardcoded. The same suite must
    run green against an existing deployment and against this repository's own code. A
    suite that can only run against one of them proves nothing about a transformation.

    Run it with tests/Invoke-Tests.ps1.
#>

param(
    # Folder containing the hub script, TeamConfig.json and Languages/.
    [Parameter(Mandatory)]
    [string] $HubSource,

    # Defaults to this repository's own script name; pass the deployment's filename
    # explicitly when testing against an existing install.
    [string] $HubScriptName = 'SAB-Team-Hub.ps1',

    # The word that authorizes deletion. A parameter because it is scheduled to become
    # configurable per team; pass the value the code under test actually expects.
    [string] $ConfirmationWord = 'CONFIRM'
,
    # Passed by the runner. Empty when the code under test is an installed deployment
    # rather than this repository.
    [Parameter()]
    [string] $RepoRoot
)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestWorld.psm1') -Force
}

Describe 'Authorized deletion of central files' {

    Context 'when the confirmation word is wrong' {
        BeforeAll {
            $world = New-TestWorld -Source $HubSource -HubScriptName $HubScriptName
            $exitCode = Invoke-HubAction -World $world -Action 'SendFinish' -Answer 'definitely-not-the-word'
        }
        AfterAll { Remove-TestWorld -World $world }

        It 'fails rather than completing the send' {
            $exitCode | Should -Not -Be 0
        }

        It 'leaves the central file that was deleted locally untouched' {
            Join-Path $world.CentralMaster 'remove.txt' | Should -Exist
        }

        It 'does not release the lock' {
            $world.LockPath | Should -Exist
        }
    }

    Context 'when the confirmation word is correct' {
        BeforeAll {
            $world = New-TestWorld -Source $HubSource -HubScriptName $HubScriptName
            $exitCode = Invoke-HubAction -World $world -Action 'SendFinish' -Answer $ConfirmationWord
        }
        AfterAll { Remove-TestWorld -World $world }

        It 'completes the send' {
            $exitCode | Should -Be 0
        }

        It 'deletes the authorized file from the central master' {
            Join-Path $world.CentralMaster 'remove.txt' | Should -Not -Exist
        }

        It 'does not recreate a file that was already absent centrally' {
            Join-Path $world.CentralMaster 'already-gone.txt' | Should -Not -Exist
        }

        It 'copies the locally changed file to the central master' {
            Get-Content -LiteralPath (Join-Path $world.CentralMaster 'keep.txt') -Raw | Should -Be 'local-new'
        }

        It 'releases the lock' {
            $world.LockPath | Should -Not -Exist
        }

        It 'increments the central master version' {
            $project = Get-Content -LiteralPath (Join-Path $world.CentralControl 'PROJECT.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            [int]$project.masterVersion | Should -Be 2
        }

        It 'backs up the file it is about to delete' {
            $backup = Get-ChildItem -LiteralPath $world.CentralBackups -Directory | Select-Object -First 1
            $backup | Should -Not -BeNullOrEmpty
            Join-Path $backup.FullName 'remove.txt' | Should -Exist
        }

        It 'backs up the file it is about to overwrite' {
            $backup = Get-ChildItem -LiteralPath $world.CentralBackups -Directory | Select-Object -First 1
            Join-Path $backup.FullName 'keep.txt' | Should -Exist
        }
    }
}
