#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Only the holder of the central lock may send or release it.

.DESCRIPTION
    This is the tool's core safety promise: one editor at a time. These tests cover
    OWNERSHIP -- that a user who does not hold the lock is refused, and that a clean
    release only happens when there is genuinely nothing to send.

    They do NOT cover lock ACQUISITION under contention. Acquisition runs through
    StartWork, which calls a SAB version check first, so it cannot run anywhere SAB is not
    installed at an exact version -- CI included. Making that path testable needs a seam in
    the code and is scheduled for the transformation, not for this suite.

    They also do not prove anything about shared cloud storage. Exclusive file creation is
    verified here on a local filesystem only; whether a given cloud provider honours it
    across two machines is a separate, physical test.
#>

param(
    [Parameter(Mandatory)]
    [string] $HubSource,

    [string] $HubScriptName = 'SAB-Team-Hub.ps1',

    [string] $ConfirmationWord = 'CONFIRM'
)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestWorld.psm1') -Force
}

Describe 'Lock ownership' {

    Context 'when someone who does not hold the lock tries to send' {
        BeforeAll {
            $world = New-TestWorld -Source $HubSource -HubScriptName $HubScriptName `
                -IdentityUserId 'TESTMEMBER' -LockOwnerUserId 'OTHERUSER'
            $exitCode = Invoke-HubAction -World $world -Action 'SendFinish' -Answer $ConfirmationWord
        }
        AfterAll { Remove-TestWorld -World $world }

        It 'refuses the send' {
            $exitCode | Should -Not -Be 0
        }

        It 'does not touch the central master' {
            Join-Path $world.CentralMaster 'remove.txt' | Should -Exist
            Get-Content -LiteralPath (Join-Path $world.CentralMaster 'keep.txt') -Raw | Should -Be 'central-old'
        }

        It 'leaves the lock with its rightful owner' {
            $world.LockPath | Should -Exist
            $lock = Get-Content -LiteralPath $world.LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $lock.userId | Should -Be 'OTHERUSER'
        }

        It 'does not increment the central master version' {
            $project = Get-Content -LiteralPath (Join-Path $world.CentralControl 'PROJECT.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            [int]$project.masterVersion | Should -Be 1
        }
    }

    Context 'when someone who does not hold the lock tries to release it' {
        BeforeAll {
            $world = New-TestWorld -Source $HubSource -HubScriptName $HubScriptName `
                -IdentityUserId 'TESTMEMBER' -LockOwnerUserId 'OTHERUSER' -CleanLocal
            $exitCode = Invoke-HubAction -World $world -Action 'ReleaseClean'
        }
        AfterAll { Remove-TestWorld -World $world }

        It 'refuses the release' {
            $exitCode | Should -Not -Be 0
        }

        It 'leaves the lock in place' {
            $world.LockPath | Should -Exist
        }
    }

    Context 'when the owner releases a lock with nothing left to send' {
        BeforeAll {
            $world = New-TestWorld -Source $HubSource -HubScriptName $HubScriptName `
                -IdentityUserId 'TESTADMIN' -LockOwnerUserId 'TESTADMIN' -CleanLocal
            $exitCode = Invoke-HubAction -World $world -Action 'ReleaseClean'
        }
        AfterAll { Remove-TestWorld -World $world }

        It 'succeeds' {
            $exitCode | Should -Be 0
        }

        It 'releases the lock' {
            $world.LockPath | Should -Not -Exist
        }
    }

    Context 'when the owner tries to release a lock but has unsent local changes' {
        BeforeAll {
            $world = New-TestWorld -Source $HubSource -HubScriptName $HubScriptName `
                -IdentityUserId 'TESTADMIN' -LockOwnerUserId 'TESTADMIN'
            $exitCode = Invoke-HubAction -World $world -Action 'ReleaseClean'
        }
        AfterAll { Remove-TestWorld -World $world }

        It 'refuses, rather than silently discarding the work' {
            $exitCode | Should -Not -Be 0
        }

        It 'keeps the lock, so the work is not stranded' {
            $world.LockPath | Should -Exist
        }
    }
}
