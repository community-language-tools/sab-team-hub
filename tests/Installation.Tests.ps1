#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Installing the Hub from this repository produces something the Hub can run from.

.DESCRIPTION
    The installer's job is to turn the repository layout -- src/, languages/, config/ --
    into the single _HUB folder the engine expects at run time. So these tests install into
    a throwaway root and then run the REAL engine out of what was installed. Checking that
    the expected files arrived is necessary but weak; running the thing is the test.

    Like provisioning, installing is NEW behaviour: the existing deployment's installer
    knows one team by name and cannot be pointed at another. There is nothing to
    characterize, so these tests state a specification, and they SKIP rather than silently
    pass when the code under test is a deployment rather than this repository.
#>

param(
    [Parameter(Mandatory)]
    [string] $HubSource,

    [Parameter()]
    [string] $HubScriptName = 'SAB-Team-Hub.ps1',

    [Parameter()]
    [string] $ConfirmationWord = 'CONFIRM',

    # The repository to install FROM. Empty when the code under test is an installed
    # deployment, which is not a repository -- these tests then skip.
    [Parameter()]
    [string] $RepoRoot
)

BeforeDiscovery {
    $script:canInstall = $false
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $script:canInstall =
            (Test-Path -LiteralPath (Join-Path $RepoRoot 'src\Install-TeamHub.ps1') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $RepoRoot 'languages') -PathType Container)
    }
}

Describe 'Installing the Hub onto a computer' -Skip:(-not $script:canInstall) {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestWorld.psm1') -Force

        $script:installer = Join-Path $RepoRoot 'src\Install-TeamHub.ps1'
        $script:provisioner = Join-Path $RepoRoot 'src\New-TeamProject.ps1'

        function New-Site {
            <#
                A throwaway stand-in for one team: an empty shared drive, an empty local
                disk, and the two configuration files an administrator fills in. Both are
                GENERATED -- never copied from a deployment, so no real team's roots or
                names reach this suite.
            #>
            $root = Join-Path ([IO.Path]::GetTempPath()) ('sabhub-install-' + [guid]::NewGuid().ToString('N'))
            $local = Join-Path $root 'LOCAL'
            $central = Join-Path $root 'CENTRAL'
            $prepared = Join-Path $root 'PREPARED'
            New-Item -ItemType Directory -Force -Path $local, $central, $prepared | Out-Null

            Write-Utf8Json -Path (Join-Path $prepared 'team.json') -Value ([pscustomobject][ordered]@{
                schemaVersion            = 1
                teamName                 = 'Test Team'
                centralRoot              = $central
                localRoot                = $local
                sabCommand               = 'C:\nowhere\sab.bat'
                requiredVersion          = '14.4'
                requiredRelease          = '179'
                deletionConfirmationWord = 'CONFIRM'
                lockConfirmationSeconds  = 2
                sabStartupTimeoutSeconds = 15
                sabWindowTimeoutSeconds  = 60
            })

            Write-Utf8Json -Path (Join-Path $prepared 'users.json') -Value ([pscustomobject][ordered]@{
                schemaVersion = 1
                users = @(
                    [pscustomobject]@{ id = 'TESTADMIN';  displayName = 'Test administrator'; role = 'administrator'; enabled = $true }
                    [pscustomobject]@{ id = 'TESTMEMBER'; displayName = 'Test member';        role = 'member';        enabled = $true }
                    [pscustomobject]@{ id = 'RETIRED';    displayName = 'Retired member';     role = 'member';        enabled = $false }
                )
            })

            [pscustomobject]@{
                Root        = $root
                LocalRoot   = $local
                CentralRoot = $central
                TeamConfig  = Join-Path $prepared 'team.json'
                UsersFile   = Join-Path $prepared 'users.json'
                Hub         = Join-Path $local '_HUB'
            }
        }

        function Install-Site {
            param(
                [Parameter(Mandatory)] $Site,
                [string] $UserId,
                [string] $UiLanguage,
                [switch] $PublishUserRegistry
            )
            $arguments = @{
                RepoRoot    = $RepoRoot
                TeamConfig  = $Site.TeamConfig
                UsersFile   = $Site.UsersFile
                LocalRoot   = $Site.LocalRoot
                CentralRoot = $Site.CentralRoot
            }
            if ($UserId) { $arguments['UserId'] = $UserId }
            if ($UiLanguage) { $arguments['UiLanguage'] = $UiLanguage }
            if ($PublishUserRegistry) { $arguments['PublishUserRegistry'] = $true }
            & $script:installer @arguments 6>$null
        }

        function Remove-Site {
            param([Parameter(Mandatory)] $Site)
            if ($Site -and (Test-Path -LiteralPath $Site.Root)) {
                Remove-Item -LiteralPath $Site.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'onto a computer that has never had it' {

        BeforeAll {
            $script:site = New-Site
            $script:result = Install-Site -Site $script:site -UserId 'TESTADMIN' -UiLanguage 'en'
        }

        AfterAll { Remove-Site -Site $script:site }

        It 'installs the engine and its companion scripts side by side' {
            Join-Path $script:site.Hub 'SAB-Team-Hub.ps1'   | Should -Exist
            Join-Path $script:site.Hub 'New-TeamProject.ps1' | Should -Exist
        }

        It 'installs every translation, not only the chosen one' {
            $installed = @(Get-ChildItem -LiteralPath (Join-Path $script:site.Hub 'Languages') -File -Filter '*.json')
            $expected = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'languages') -File -Filter '*.json')
            $installed.Count | Should -Be $expected.Count
            $installed.Count | Should -BeGreaterThan 0
        }

        It 'installs the prepared configuration under the names the engine reads' {
            # The repository calls them team.json and users.json; the engine looks for
            # TeamConfig.json and Users.json. Getting this mapping wrong is silent.
            Join-Path $script:site.Hub 'TeamConfig.json' | Should -Exist
            Join-Path $script:site.Hub 'Users.json'      | Should -Exist
        }

        It 'leaves a launcher where the member will find it' {
            Join-Path $script:site.LocalRoot 'SAB Team Hub.cmd' | Should -Exist
        }

        It 'registers the identity, so the member is not asked who they are' {
            $identity = Join-Path $script:site.Hub 'Config\Identity.json'
            $identity | Should -Exist
            $saved = Get-Content -LiteralPath $identity -Raw -Encoding UTF8 | ConvertFrom-Json
            $saved.userId     | Should -Be 'TESTADMIN'
            $saved.uiLanguage | Should -Be 'en'
        }

        It 'reports back what it installed' {
            $script:result.Hub            | Should -Be $script:site.Hub
            $script:result.RegisteredUser | Should -Be 'TESTADMIN'
        }

        It 'does not copy the repository documents into the installation' {
            Join-Path $script:site.Hub 'CONTRIBUTING.md' | Should -Not -Exist
            Join-Path $script:site.Hub 'tests'           | Should -Not -Exist
        }
    }

    Context 'when a project already exists on the shared drive' {

        BeforeAll {
            $script:site = New-Site
            & $script:provisioner -Code 'TESTPROJ' -CentralRoot $script:site.CentralRoot `
                -RequiredSabVersion '14.4' -RequiredSabRelease '179' 6>$null | Out-Null
            $script:result = Install-Site -Site $script:site -UserId 'TESTMEMBER'
        }

        AfterAll { Remove-Site -Site $script:site }

        It 'prepares the local folders for that project' {
            Join-Path $script:site.LocalRoot 'TESTPROJ\_PARTAGE' | Should -Exist
            Join-Path $script:site.LocalRoot 'TESTPROJ\_LOCALE'  | Should -Exist
        }

        It 'names the project it found' {
            $script:result.Projects | Should -Contain 'TESTPROJ'
        }

        It 'produces an installation the real engine runs from' {
            # The point of the whole suite. Provision, install, then run the engine out of
            # what was installed -- no test fixtures involved in the run at all.
            $exit = 0
            '' | powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $script:site.Hub 'SAB-Team-Hub.ps1') `
                -Action 'Status' -Project 'TESTPROJ' | Out-Null
            $exit = $LASTEXITCODE
            $exit | Should -Be 0
        }
    }

    Context 'onto a computer that already has it' {

        BeforeAll {
            $script:site = New-Site
            Install-Site -Site $script:site -UserId 'TESTMEMBER' -UiLanguage 'en' | Out-Null

            # Something the member owns, which an update must not touch.
            $work = Join-Path $script:site.LocalRoot 'MYPROJECT\_PARTAGE'
            New-Item -ItemType Directory -Force -Path $work | Out-Null
            [IO.File]::WriteAllText((Join-Path $work 'my-work.txt'), 'mine', [Text.UTF8Encoding]::new($false))

            $script:reinstall = Install-Site -Site $script:site
        }

        AfterAll { Remove-Site -Site $script:site }

        It 'keeps the identity already registered' {
            $saved = Get-Content -LiteralPath (Join-Path $script:site.Hub 'Config\Identity.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $saved.userId | Should -Be 'TESTMEMBER'
        }

        It 'leaves the member work alone' {
            Join-Path $script:site.LocalRoot 'MYPROJECT\_PARTAGE\my-work.txt' | Should -Exist
        }
    }

    Context 'when asked to publish the team list centrally' {

        BeforeAll {
            $script:site = New-Site
            Install-Site -Site $script:site -PublishUserRegistry | Out-Null
        }

        AfterAll { Remove-Site -Site $script:site }

        It 'puts it where the engine prefers to read it' {
            Join-Path $script:site.CentralRoot '_DISTRIBUTION\Users.json' | Should -Exist
        }
    }

    Context 'when asked to do something unsafe or impossible' {

        BeforeAll { $script:site = New-Site }
        AfterAll { Remove-Site -Site $script:site }

        It 'refuses a user id that is not in the team list' {
            { Install-Site -Site $script:site -UserId 'NOBODY' } | Should -Throw '*Not an enabled user id*'
        }

        It 'refuses a user id that is in the list but disabled' {
            { Install-Site -Site $script:site -UserId 'RETIRED' } | Should -Throw '*Not an enabled user id*'
        }

        It 'refuses a language nothing is translated into, and says what is available' {
            { Install-Site -Site $script:site -UiLanguage 'xx' } | Should -Throw '*Not a translated language*'
        }

        It 'refuses when the shared drive is not reachable' {
            {
                & $script:installer -RepoRoot $RepoRoot -TeamConfig $script:site.TeamConfig `
                    -UsersFile $script:site.UsersFile -LocalRoot $script:site.LocalRoot `
                    -CentralRoot (Join-Path $script:site.Root 'NO-SUCH-SHARE') 6>$null
            } | Should -Throw '*unavailable*'
        }

        It 'refuses to install into a drive root' {
            {
                & $script:installer -RepoRoot $RepoRoot -TeamConfig $script:site.TeamConfig `
                    -UsersFile $script:site.UsersFile -LocalRoot 'Z:\' `
                    -CentralRoot $script:site.CentralRoot 6>$null
            } | Should -Throw '*drive root*'
        }

        It 'points at the example file when the prepared configuration is missing' {
            {
                & $script:installer -RepoRoot $RepoRoot -TeamConfig (Join-Path $script:site.Root 'absent.json') `
                    -UsersFile $script:site.UsersFile -LocalRoot $script:site.LocalRoot `
                    -CentralRoot $script:site.CentralRoot 6>$null
            } | Should -Throw '*team.example.json*'
        }
    }
}
