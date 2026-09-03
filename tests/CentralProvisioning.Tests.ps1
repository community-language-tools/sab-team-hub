<#
    Creating a central project is NEW behaviour. There is nothing in an existing
    deployment to characterize -- every deployment so far had its central project built
    by hand, once. So unlike the other suites, these tests describe a specification
    rather than an observation, and they are skipped when the script under test is a
    deployment that has no provisioning script.

    What they prove: that a project this script creates is one the real Hub accepts.
    That is the only claim worth making, and it is checked by running the real Hub
    against the provisioned project, not by re-reading the files we just wrote.
#>

param(
    [Parameter(Mandatory)][string] $HubSource,
    [Parameter(Mandatory)][string] $HubScriptName,
    [Parameter()][string] $ConfirmationWord = 'CONFIRM'
,
    # Passed by the runner. Empty when the code under test is an installed deployment
    # rather than this repository.
    [Parameter()]
    [string] $RepoRoot
)

BeforeDiscovery {
    $script:provisioningAvailable = Test-Path -LiteralPath (Join-Path $HubSource 'New-TeamProject.ps1') -PathType Leaf
}

Describe 'Creating a central project from nothing' -Skip:(-not $script:provisioningAvailable) {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestWorld.psm1') -Force

        $script:code = 'TESTPROJ'

        function New-World {
            param([switch] $WithSeed)

            $world = New-HubOnlyWorld -Source $HubSource -HubScriptName $HubScriptName -ProjectCode $script:code
            if ($WithSeed) {
                $seed = Join-Path $world.Root 'SEED'
                New-Item -ItemType Directory -Force -Path (Join-Path $seed 'Contents') | Out-Null
                [IO.File]::WriteAllText((Join-Path $seed 'book.txt'), 'genesis', [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText((Join-Path $seed 'Contents\notes.txt'), 'notes', [Text.UTF8Encoding]::new($false))
                $world | Add-Member -NotePropertyName Seed -NotePropertyValue $seed -PassThru
            }
            else { $world }
        }

        function Invoke-Provision {
            param(
                [Parameter(Mandatory)] $World,
                [string] $Code = $script:code,
                [string] $SeedFrom,
                [switch] $Force
            )
            $arguments = @{
                Code               = $Code
                CentralRoot        = $World.CentralRoot
                RequiredSabVersion = '14.4'
                RequiredSabRelease = '179'
                AdministratorId    = 'TESTADMIN'
            }
            if ($SeedFrom) { $arguments['SeedFrom'] = $SeedFrom }
            if ($Force) { $arguments['Force'] = $true }
            & $World.ProvisionScript @arguments 6>$null
        }

        # Mirrors the two checks the Hub's own Assert-CentralManifest makes, implemented
        # independently here on purpose: a test that reuses the code under test to decide
        # whether that code is right proves nothing.
        function Test-MasterMatchesManifest {
            param([Parameter(Mandatory)][string] $CentralProject)

            $control = Get-Content -LiteralPath (Join-Path $CentralProject 'CONTROL\PROJECT.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifestPath = Join-Path $CentralProject (Join-Path 'CONTROL' $control.master.manifest)
            $master = Join-Path $CentralProject 'MASTER'

            $hashMatches = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $control.master.manifestSha256

            $rows = @(Import-Csv -LiteralPath $manifestPath)
            $listed = @{}
            $problems = [System.Collections.Generic.List[string]]::new()
            foreach ($row in $rows) {
                $listed[$row.Path] = $true
                $file = Join-Path $master $row.Path
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $problems.Add("missing:$($row.Path)"); continue }
                $item = Get-Item -LiteralPath $file
                if ($item.Length -ne [int64]$row.Bytes) { $problems.Add("size:$($row.Path)") }
                elseif ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $row.SHA256) { $problems.Add("hash:$($row.Path)") }
            }
            foreach ($file in @(Get-ChildItem -LiteralPath $master -Recurse -File -Force)) {
                $relative = $file.FullName.Substring($master.Length).TrimStart('\')
                if (-not $listed.ContainsKey($relative)) { $problems.Add("extra:$relative") }
            }

            [pscustomobject]@{
                HashMatches = $hashMatches
                Problems    = @($problems)
                RowCount    = $rows.Count
            }
        }
    }

    Context 'when the central root holds no project yet' {

        BeforeAll {
            $script:world = New-World -WithSeed
            $script:result = Invoke-Provision -World $script:world -SeedFrom $script:world.Seed
            $script:project = $script:world.CentralProject
        }

        AfterAll { Remove-TestWorld -World $script:world }

        It 'creates the four folders the Hub expects' {
            foreach ($folder in @('CONTROL', 'MASTER', 'BACKUPS', 'HISTORY')) {
                Join-Path $script:project $folder | Should -Exist
            }
        }

        It 'seeds the master copy, preserving subfolders' {
            Join-Path $script:project 'MASTER\book.txt' | Should -Exist
            Join-Path $script:project 'MASTER\Contents\notes.txt' | Should -Exist
        }

        It 'opens the project for team use, at master version 1' {
            $control = Get-Content -LiteralPath (Join-Path $script:project 'CONTROL\PROJECT.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $control.masterVersion  | Should -Be 1
            $control.masterState    | Should -Be 'VERIFIED'
            $control.teamUseAllowed | Should -BeTrue
            $control.workflowState  | Should -Be 'ACTIVE'
        }

        It 'records the required Scripture App Builder version' {
            $control = Get-Content -LiteralPath (Join-Path $script:project 'CONTROL\PROJECT.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $control.requiredSab.version | Should -Be '14.4'
            $control.requiredSab.release | Should -Be '179'
        }

        It 'writes a manifest that matches the master copy exactly' {
            $check = Test-MasterMatchesManifest -CentralProject $script:project
            $check.HashMatches | Should -BeTrue
            $check.Problems    | Should -BeNullOrEmpty
            $check.RowCount    | Should -Be 2
        }

        It 'leaves the project unlocked, so the first member can take it' {
            Join-Path $script:project 'CONTROL\PROJECT-LOCK.json' | Should -Not -Exist
        }

        It 'logs the provisioning in the central history' {
            $log = Join-Path $script:project 'HISTORY\HISTORY.log'
            $log | Should -Exist
            (Get-Content -LiteralPath $log -Raw) | Should -Match 'PROVISION'
        }

        It 'reports back what it created' {
            $script:result.Code          | Should -Be $script:code
            $script:result.MasterVersion | Should -Be 1
            $script:result.FileCount     | Should -Be 2
        }

        It 'produces a project the real Hub accepts' {
            # The whole point. Status is the deepest action reachable without Scripture
            # App Builder installed: it resolves the project context, reads the control
            # file and reads the lock. A hand-built project with any field wrong fails here.
            Invoke-HubAction -World $script:world -Action 'Status' | Should -Be 0
        }

        It 'makes the project discoverable to the Hub as a central project' {
            $found = @(Get-ChildItem -LiteralPath $script:world.CentralRoot -Directory |
                Where-Object {
                    -not $_.Name.StartsWith('_') -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'CONTROL\PROJECT.json') -PathType Leaf) -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'MASTER') -PathType Container)
                })
            $found.Count  | Should -Be 1
            $found[0].Name | Should -Be $script:code
        }
    }

    Context 'when no seed folder is given' {

        BeforeAll {
            $script:world = New-World
            $script:result = Invoke-Provision -World $script:world
            $script:project = $script:world.CentralProject
        }

        AfterAll { Remove-TestWorld -World $script:world }

        It 'creates an empty master rather than refusing' {
            Join-Path $script:project 'MASTER' | Should -Exist
            @(Get-ChildItem -LiteralPath (Join-Path $script:project 'MASTER') -Recurse -File).Count | Should -Be 0
        }

        It 'still writes a readable manifest, with no rows' {
            $check = Test-MasterMatchesManifest -CentralProject $script:project
            $check.HashMatches | Should -BeTrue
            $check.Problems    | Should -BeNullOrEmpty
            $check.RowCount    | Should -Be 0
        }

        It 'still produces a project the real Hub accepts' {
            Invoke-HubAction -World $script:world -Action 'Status' | Should -Be 0
        }
    }

    Context 'when asked to do something unsafe' {

        BeforeAll { $script:world = New-World }
        AfterAll { Remove-TestWorld -World $script:world }

        It 'refuses a project code the Hub would later reject' {
            { Invoke-Provision -World $script:world -Code 'bad code!' } | Should -Throw '*Invalid project code*'
        }

        It 'refuses to overwrite an existing project without -Force' {
            Invoke-Provision -World $script:world | Out-Null
            { Invoke-Provision -World $script:world } | Should -Throw '*already exists*'
        }

        It 'rewrites the control files when -Force is given, leaving the master alone' {
            $master = Join-Path $script:world.CentralProject 'MASTER'
            [IO.File]::WriteAllText((Join-Path $master 'sent-by-a-member.txt'), 'work', [Text.UTF8Encoding]::new($false))

            Invoke-Provision -World $script:world -Force | Out-Null

            Join-Path $master 'sent-by-a-member.txt' | Should -Exist
            $check = Test-MasterMatchesManifest -CentralProject $script:world.CentralProject
            $check.HashMatches | Should -BeTrue
            $check.Problems    | Should -BeNullOrEmpty
        }

        It 'refuses to touch a project while a member holds the lock' {
            $lock = Join-Path $script:world.CentralProject 'CONTROL\PROJECT-LOCK.json'
            Write-Utf8Json -Path $lock -Value ([pscustomobject]@{ userId = 'TESTMEMBER'; token = 'x' })
            try {
                { Invoke-Provision -World $script:world -Force } | Should -Throw '*locked*'
            }
            finally { Remove-Item -LiteralPath $lock -Force }
        }

        It 'refuses when the central root does not exist' {
            $missing = Join-Path $script:world.Root 'NO-SUCH-SHARE'
            {
                & $script:world.ProvisionScript -Code $script:code -CentralRoot $missing `
                    -RequiredSabVersion '14.4' -RequiredSabRelease '179' 6>$null
            } | Should -Throw '*unavailable*'
        }
    }
}
