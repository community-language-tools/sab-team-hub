#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Verifies that deleting files from the central master requires explicit authorization.

.DESCRIPTION
    The path to the scripts under test is a PARAMETER, never hardcoded. The same suite must
    run green against the original deployment and against this repository's own code, and
    must pass both. A suite that can only run against one of them proves nothing about a
    transformation.

    Run it with tests/Invoke-Tests.ps1.
#>

param(
    # Folder containing the hub script, TeamConfig.json, Users.json and Languages/.
    [Parameter(Mandatory)]
    [string] $HubSource,

    # Filename of the hub script inside $HubSource. Defaults to this repository's own name;
    # pass the deployment's filename explicitly when testing against an existing install.
    [string] $HubScriptName = 'SAB-Team-Hub.ps1',

    # The word that authorizes deletion. A parameter because it is scheduled to become
    # configurable per team; pass the value the code under test actually expects.
    [string] $ConfirmationWord = 'CONFIRM'
)

BeforeAll {
    function Write-Utf8Json {
        param([Parameter(Mandatory)] $Value, [Parameter(Mandatory)][string] $Path)
        [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    }

    # Builds a throwaway world in TEMP: a fake central master and a fake local copy, in a
    # known state. Returns every path the assertions need.
    function New-TestWorld {
        param([Parameter(Mandatory)][string] $Source)

        $root        = Join-Path ([IO.Path]::GetTempPath()) ('sabhub-test-' + [guid]::NewGuid().ToString('N'))
        $localRoot   = Join-Path $root 'LOCAL'
        $centralRoot = Join-Path $root 'CENTRAL'
        $hub         = Join-Path $localRoot '_HUB'
        $projectCode = 'TEST'

        $centralProject    = Join-Path $centralRoot $projectCode
        $centralMaster     = Join-Path $centralProject 'MASTER'
        $centralControl    = Join-Path $centralProject 'CONTROL'
        $centralBackups    = Join-Path $centralProject 'BACKUPS'
        $localProject      = Join-Path $localRoot $projectCode
        $localShared       = Join-Path $localProject '_PARTAGE'
        $localCollaboration = Join-Path $localProject '_LOCALE\Collaboration'

        New-Item -ItemType Directory -Force -Path @(
            $hub, (Join-Path $hub 'Config'), (Join-Path $hub 'Languages'),
            $centralMaster, $centralControl, $centralBackups,
            (Join-Path $centralProject 'HISTORY'), $localShared, $localCollaboration
        ) | Out-Null

        foreach ($name in @($HubScriptName, 'TeamConfig.json')) {
            Copy-Item -LiteralPath (Join-Path $Source $name) -Destination (Join-Path $hub $name)
        }
        Get-ChildItem -LiteralPath (Join-Path $Source 'Languages') -File -Filter '*.json' |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $hub 'Languages') }

        # The user registry is GENERATED, never copied from the deployment. Two reasons:
        # no real names reach this repository, and the test stops depending on who happens
        # to be on the team. windowsUser and computerName are deliberately omitted -- when
        # present they pin a user to one machine, which would make this test pass only on
        # that machine and fail everywhere else, CI included.
        Write-Utf8Json -Path (Join-Path $hub 'Users.json') -Value ([pscustomobject]@{
            schemaVersion = 1
            users = @(
                [pscustomobject]@{ id = 'TESTADMIN'; displayName = 'Test administrator'; role = 'administrator'; enabled = $true }
                [pscustomobject]@{ id = 'TESTMEMBER'; displayName = 'Test member'; role = 'member'; enabled = $true }
            )
        })

        $identity = [pscustomobject][ordered]@{
            schemaVersion = 1; userId = 'TESTADMIN'; displayName = 'Test administrator'
            role = 'administrator'; windowsUser = $env:USERNAME; computerName = $env:COMPUTERNAME
            uiLanguage = 'en'; createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        Write-Utf8Json -Value $identity -Path (Join-Path $hub 'Config\Identity.json')

        # Central holds three files; locally one is changed and one is deleted.
        [IO.File]::WriteAllText((Join-Path $centralMaster 'keep.txt'), 'central-old', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $centralMaster 'remove.txt'), 'delete-me', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $centralMaster 'already-gone.txt'), 'already-gone', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $localShared 'keep.txt'), 'local-new', [Text.UTF8Encoding]::new($false))

        $manifestName = 'MASTER-MANIFEST-v0001.csv'
        $manifestPath = Join-Path $centralControl $manifestName
        $rows = foreach ($file in Get-ChildItem -LiteralPath $centralMaster -File | Sort-Object Name) {
            [pscustomobject]@{
                Path   = $file.Name
                Bytes  = $file.Length
                SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            }
        }
        $rows | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $localCollaboration 'BASELINE-MANIFEST.csv')
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash

        # In the manifest but absent centrally: must not be recreated by the send.
        Remove-Item -LiteralPath (Join-Path $centralMaster 'already-gone.txt') -Force

        $token = [guid]::NewGuid().ToString('N')

        Write-Utf8Json -Path (Join-Path $centralControl 'PROJECT.json') -Value ([pscustomobject][ordered]@{
            schemaVersion = 1; projectCode = $projectCode; language = 'TEST'
            masterState = 'RECOVERY_REQUIRED'; masterVersion = 1
            teamUseAllowed = $false; workflowState = 'BLOCKED'; workflowReason = 'controlled retry test'
            requiredSab = [pscustomobject]@{ version = '14.4'; release = '179' }
            master = [pscustomobject]@{
                relativePath = '..\MASTER'; fileCount = 3; totalBytes = 32
                manifest = $manifestName; manifestSha256 = $manifestHash
            }
        })

        Write-Utf8Json -Path (Join-Path $centralControl 'PROJECT-LOCK.json') -Value ([pscustomobject][ordered]@{
            schemaVersion = 1; projectCode = $projectCode; token = $token
            userId = 'TESTADMIN'; displayName = 'Test administrator'; role = 'administrator'
            windowsUser = $env:USERNAME; computerName = $env:COMPUTERNAME
            acquiredUtc = (Get-Date).ToUniversalTime().ToString('o'); baseMasterVersion = 1
        })

        Write-Utf8Json -Path (Join-Path $localCollaboration 'STATE.json') -Value ([pscustomobject]@{
            schemaVersion = 1; projectCode = $projectCode; receivedMasterVersion = 1
            manifest = $manifestName; manifestSha256 = $manifestHash
            userId = 'TESTADMIN'; computerName = $env:COMPUTERNAME
        })

        Write-Utf8Json -Path (Join-Path $localCollaboration 'SESSION.json') -Value ([pscustomobject]@{
            schemaVersion = 1; projectCode = $projectCode; lockToken = $token
            receivedMasterVersion = 1; userId = 'TESTADMIN'; computerName = $env:COMPUTERNAME
        })

        [pscustomobject]@{
            Root          = $root
            LocalRoot     = $localRoot
            CentralRoot   = $centralRoot
            ProjectCode   = $projectCode
            HubScript     = Join-Path $hub $HubScriptName
            CentralMaster = $centralMaster
            CentralControl = $centralControl
            CentralBackups = $centralBackups
        }
    }

    # Runs the real hub script, feeding $Answer to its confirmation prompt on stdin.
    function Invoke-SendFinish {
        param([Parameter(Mandatory)] $World, [Parameter(Mandatory)][string] $Answer)
        $Answer | powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File $World.HubScript -Action SendFinish -Project $World.ProjectCode `
            -UiLanguage en -LocalRoot $World.LocalRoot -CentralRoot $World.CentralRoot | Out-Null
        return $LASTEXITCODE
    }

    function Remove-TestWorld {
        param([Parameter(Mandatory)] $World)
        if ($World -and (Test-Path -LiteralPath $World.Root)) {
            Remove-Item -LiteralPath $World.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Authorized deletion of central files' {

    Context 'when the confirmation word is wrong' {
        BeforeAll {
            $world = New-TestWorld -Source $HubSource
            $exitCode = Invoke-SendFinish -World $world -Answer 'definitely-not-the-word'
        }
        AfterAll { Remove-TestWorld -World $world }

        It 'fails rather than completing the send' {
            $exitCode | Should -Not -Be 0
        }

        It 'leaves the central file that was deleted locally untouched' {
            Join-Path $world.CentralMaster 'remove.txt' | Should -Exist
        }

        It 'does not release the lock' {
            Join-Path $world.CentralControl 'PROJECT-LOCK.json' | Should -Exist
        }
    }

    Context 'when the confirmation word is correct' {
        BeforeAll {
            $world = New-TestWorld -Source $HubSource
            $exitCode = Invoke-SendFinish -World $world -Answer $ConfirmationWord
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
            Join-Path $world.CentralControl 'PROJECT-LOCK.json' | Should -Not -Exist
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
