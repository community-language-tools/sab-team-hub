#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Help is available in every supported language and resource preparation stays local.

.DESCRIPTION
    This is new repository behaviour, so an existing deployment has nothing equivalent to
    characterize. These tests therefore run only for the repository build.

    The safety boundary matters more than the wording: START WORK must receive and verify
    the central master before resource preparation begins, and preparation may point only
    at the member's local _PARTAGE copy. The normal send remains the only path back into
    MASTER and the only place that writes the next manifest.
#>

param(
    [Parameter(Mandatory)][string] $HubSource,
    [Parameter(Mandatory)][string] $HubScriptName,
    [Parameter()][string] $ConfirmationWord = 'CONFIRM',
    [Parameter()][string] $RepoRoot
)

BeforeDiscovery {
    $script:featureAvailable = -not [string]::IsNullOrWhiteSpace($RepoRoot)
}

Describe 'Help and safe resource preparation' -Skip:(-not $script:featureAvailable) {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestWorld.psm1') -Force
        $script:enginePath = Join-Path $RepoRoot 'src\SAB-Team-Hub.ps1'
        $script:engine = Get-Content -LiteralPath $script:enginePath -Raw -Encoding UTF8
        $script:languageFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'languages') -File -Filter '*.json' | Sort-Object Name)
        $script:requiredKeys = @(
            'need_help', 'prepare_resources', 'prepare_none', 'prepare_pictures',
            'prepare_audio', 'prepare_both', 'resource_folder_opened',
            'resource_copy_instructions', 'resource_done_prompt', 'resource_summary',
            'resource_new_heading', 'resource_changed_heading', 'resource_missing_heading',
            'resource_no_changes', 'resource_missing_warning', 'resource_replacement_warning',
            'resource_replacement_choice', 'resource_reopen', 'help_lines'
        )
    }

    Context 'the translated help content' {

        It 'has the same keys in English, French and Dutch' {
            $keySets = foreach ($file in $script:languageFiles) {
                $language = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                [pscustomobject]@{
                    Name = $file.Name
                    Keys = @($language.PSObject.Properties.Name | Sort-Object)
                }
            }
            $keySets.Count | Should -Be 3
            foreach ($set in $keySets) {
                $set.Keys | Should -Be $keySets[0].Keys
                foreach ($key in $script:requiredKeys) { $set.Keys | Should -Contain $key }
            }
        }

        It 'contains a substantial help page in every language' {
            foreach ($file in $script:languageFiles) {
                $language = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                @($language.help_lines).Count | Should -BeGreaterThan 35 -Because $file.Name
                (@($language.help_lines) -join "`n") | Should -Match 'MASTER'
                (@($language.help_lines) -join "`n") | Should -Match 'Resources\\Audio'
                (@($language.help_lines) -join "`n") | Should -Match '_PARTAGE'
            }
        }

        It 'does not carry the draft reviewer note into the application' {
            foreach ($file in $script:languageFiles) {
                Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 |
                    Should -Not -Match 'Reviewer note'
            }
        }

        It 'renders the real English help action without requiring a project' {
            $world = New-TestWorld -Source $HubSource -HubScriptName $HubScriptName -CleanLocal
            try {
                $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
                    -File $world.HubScript -Action Help -UiLanguage en `
                    -LocalRoot $world.LocalRoot -CentralRoot $world.CentralRoot 2>&1 | Out-String
                $LASTEXITCODE | Should -Be 0
                $output | Should -Match 'Need help\?'
                $output | Should -Match 'Do not copy them directly into MASTER'
                $output | Should -Match 'Resources\\Audio'
            }
            finally { Remove-TestWorld -World $world }
        }

        It 'renders the translated French and Dutch help actions' {
            $expectations = @(
                @{ Language = 'fr'; Title = "Besoin d'aide"; Safety = 'Ne les copiez pas directement dans MASTER' }
                @{ Language = 'nl'; Title = 'Hulp nodig'; Safety = 'Kopieer ze niet rechtstreeks naar MASTER' }
            )
            foreach ($expected in $expectations) {
                $world = New-TestWorld -Source $HubSource -HubScriptName $HubScriptName -CleanLocal
                try {
                    $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
                        -File $world.HubScript -Action Help -UiLanguage $expected.Language `
                        -LocalRoot $world.LocalRoot -CentralRoot $world.CentralRoot 2>&1 | Out-String
                    $LASTEXITCODE | Should -Be 0
                    $output | Should -Match ([regex]::Escape($expected.Title))
                    $output | Should -Match ([regex]::Escape($expected.Safety))
                }
                finally { Remove-TestWorld -World $world }
            }
        }
    }

    Context 'the resource preparation boundary' {

        It 'uses only the received local copy as its resource destination' {
            $preparation = [regex]::Match(
                $script:engine,
                'function Invoke-ResourcePreparation[\s\S]+?(?=function Start-TeamWork)'
            ).Value
            $preparation | Should -Not -BeNullOrEmpty
            $preparation | Should -Match '\$Context\.LocalShared'
            $preparation | Should -Not -Match 'CentralMaster'
        }

        It 'receives the verified master before offering resource preparation' {
            $startWork = [regex]::Match(
                $script:engine,
                'function Start-TeamWork[\s\S]+?(?=function Force-AdminUnlock)'
            ).Value
            $receiveAt = $startWork.IndexOf('Receive-Project')
            $prepareAt = $startWork.IndexOf('Invoke-ResourcePreparation')
            $receiveAt | Should -BeGreaterThan -1
            $prepareAt | Should -BeGreaterThan $receiveAt
        }

        It 'keeps help in the menu before identity settings' {
            $menu = [regex]::Match(
                $script:engine,
                'function Invoke-TeamMenu[\s\S]+?(?=if \(-not \(Test-Path)'
            ).Value
            $menu | Should -Match "'  5\. \{0\}'.+need_help"
            $menu | Should -Match "'5' \{ Show-Help"
            $menu | Should -Match "'  6\. \{0\}'.+change_identity"
        }
    }

    Context 'publishing a newly prepared resource' {

        BeforeAll {
            $script:world = New-TestWorld -Source $HubSource -HubScriptName $HubScriptName -CleanLocal
            $script:localShared = Join-Path $script:world.LocalRoot (Join-Path $script:world.ProjectCode '_PARTAGE')
            $script:relativeResource = 'Resources\Pictures\new-picture.jpg'
            $script:localResource = Join-Path $script:localShared $script:relativeResource
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:localResource) | Out-Null
            [IO.File]::WriteAllBytes($script:localResource, [byte[]](1, 2, 3, 4, 5))
            $script:exitCode = Invoke-HubAction -World $script:world -Action 'SendFinish'
        }

        AfterAll { Remove-TestWorld -World $script:world }

        It 'publishes the resource through the normal send' {
            $script:exitCode | Should -Be 0
            $centralResource = Join-Path $script:world.CentralMaster $script:relativeResource
            $centralResource | Should -Exist
            [IO.File]::ReadAllBytes($centralResource) | Should -Be ([byte[]](1, 2, 3, 4, 5))
        }

        It 'records the resource in the new master manifest' {
            $control = Get-Content -LiteralPath (Join-Path $script:world.CentralControl 'PROJECT.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            [int]$control.masterVersion | Should -Be 2
            $manifestPath = Join-Path $script:world.CentralControl $control.master.manifest
            (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash | Should -Be $control.master.manifestSha256
            $resourceRow = @(Import-Csv -LiteralPath $manifestPath | Where-Object { $_.Path -eq $script:relativeResource })
            $resourceRow.Count | Should -Be 1
            [int64]$resourceRow[0].Bytes | Should -Be 5
        }

        It 'releases the project for the next team member' {
            $script:world.LockPath | Should -Not -Exist
        }
    }
}
