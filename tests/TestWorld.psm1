<#
.SYNOPSIS
    Builds throwaway worlds for the test suite.

.DESCRIPTION
    Every world is created fresh in TEMP and removed afterwards. Nothing is read from a
    real deployment except the scripts under test themselves: the user registry and all
    project data are GENERATED here.

    That is deliberate. Copying a deployment's own configuration into a test couples the
    test to whoever happens to be on that team, drags real names into this repository, and
    -- as happened with the original hand-written test -- can pin the whole suite to one
    physical machine.
#>

Set-StrictMode -Version Latest

function Write-Utf8Json {
    param([Parameter(Mandatory)] $Value, [Parameter(Mandatory)][string] $Path)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function New-TestWorld {
    <#
    .PARAMETER IdentityUserId
        The user the hub script will run as.

    .PARAMETER LockOwnerUserId
        The user recorded as holding the central lock. Set it to something other than
        IdentityUserId to exercise the not-the-owner paths.

    .PARAMETER CleanLocal
        Build the local copy so it matches the baseline exactly -- no changes, no
        deletions. Without it the world contains one changed file and one deleted file.
    #>
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $HubScriptName,
        [string] $IdentityUserId   = 'TESTADMIN',
        [string] $LockOwnerUserId  = 'TESTADMIN',
        [switch] $CleanLocal
    )

    $root        = Join-Path ([IO.Path]::GetTempPath()) ('sabhub-test-' + [guid]::NewGuid().ToString('N'))
    $localRoot   = Join-Path $root 'LOCAL'
    $centralRoot = Join-Path $root 'CENTRAL'
    $hub         = Join-Path $localRoot '_HUB'
    $projectCode = 'TEST'

    $centralProject     = Join-Path $centralRoot $projectCode
    $centralMaster      = Join-Path $centralProject 'MASTER'
    $centralControl     = Join-Path $centralProject 'CONTROL'
    $centralBackups     = Join-Path $centralProject 'BACKUPS'
    $localProject       = Join-Path $localRoot $projectCode
    $localShared        = Join-Path $localProject '_PARTAGE'
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

    # Generated, never copied. windowsUser and computerName are omitted on purpose: when
    # present they pin a user to one machine, which would make the suite pass only there.
    Write-Utf8Json -Path (Join-Path $hub 'Users.json') -Value ([pscustomobject]@{
        schemaVersion = 1
        users = @(
            [pscustomobject]@{ id = 'TESTADMIN';  displayName = 'Test administrator'; role = 'administrator'; enabled = $true }
            [pscustomobject]@{ id = 'TESTMEMBER'; displayName = 'Test member';        role = 'member';        enabled = $true }
            [pscustomobject]@{ id = 'OTHERUSER';  displayName = 'Other user';         role = 'member';        enabled = $true }
        )
    })

    $identityNames = @{ TESTADMIN = 'Test administrator'; TESTMEMBER = 'Test member'; OTHERUSER = 'Other user' }
    Write-Utf8Json -Path (Join-Path $hub 'Config\Identity.json') -Value ([pscustomobject][ordered]@{
        schemaVersion = 1
        userId        = $IdentityUserId
        displayName   = $identityNames[$IdentityUserId]
        role          = if ($IdentityUserId -eq 'TESTADMIN') { 'administrator' } else { 'member' }
        windowsUser   = $env:USERNAME
        computerName  = $env:COMPUTERNAME
        uiLanguage    = 'en'
        createdUtc    = (Get-Date).ToUniversalTime().ToString('o')
    })

    [IO.File]::WriteAllText((Join-Path $centralMaster 'keep.txt'), 'central-old', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $centralMaster 'remove.txt'), 'delete-me', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $centralMaster 'already-gone.txt'), 'already-gone', [Text.UTF8Encoding]::new($false))

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

    if ($CleanLocal) {
        # Local matches the baseline exactly: nothing changed, nothing missing.
        Get-ChildItem -LiteralPath $centralMaster -File |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $localShared }
    }
    else {
        # Local holds only keep.txt, changed. Against the three-file baseline that makes
        # remove.txt and already-gone.txt both local deletions -- and already-gone.txt is
        # additionally removed centrally, so the send has to cope with deleting something
        # that is already absent.
        [IO.File]::WriteAllText((Join-Path $localShared 'keep.txt'), 'local-new', [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath (Join-Path $centralMaster 'already-gone.txt') -Force
    }

    $token = [guid]::NewGuid().ToString('N')

    Write-Utf8Json -Path (Join-Path $centralControl 'PROJECT.json') -Value ([pscustomobject][ordered]@{
        schemaVersion = 1; projectCode = $projectCode; language = 'TEST'
        masterState = 'RECOVERY_REQUIRED'; masterVersion = 1
        teamUseAllowed = $false; workflowState = 'BLOCKED'; workflowReason = 'controlled test'
        requiredSab = [pscustomobject]@{ version = '14.4'; release = '179' }
        master = [pscustomobject]@{
            relativePath = '..\MASTER'; fileCount = 3; totalBytes = 32
            manifest = $manifestName; manifestSha256 = $manifestHash
        }
    })

    Write-Utf8Json -Path (Join-Path $centralControl 'PROJECT-LOCK.json') -Value ([pscustomobject][ordered]@{
        schemaVersion = 1; projectCode = $projectCode; token = $token
        userId = $LockOwnerUserId; displayName = $identityNames[$LockOwnerUserId]
        role = if ($LockOwnerUserId -eq 'TESTADMIN') { 'administrator' } else { 'member' }
        windowsUser = $env:USERNAME; computerName = $env:COMPUTERNAME
        acquiredUtc = (Get-Date).ToUniversalTime().ToString('o'); baseMasterVersion = 1
    })

    Write-Utf8Json -Path (Join-Path $localCollaboration 'STATE.json') -Value ([pscustomobject]@{
        schemaVersion = 1; projectCode = $projectCode; receivedMasterVersion = 1
        manifest = $manifestName; manifestSha256 = $manifestHash
        userId = $IdentityUserId; computerName = $env:COMPUTERNAME
    })

    Write-Utf8Json -Path (Join-Path $localCollaboration 'SESSION.json') -Value ([pscustomobject]@{
        schemaVersion = 1; projectCode = $projectCode; lockToken = $token
        receivedMasterVersion = 1; userId = $IdentityUserId; computerName = $env:COMPUTERNAME
    })

    [pscustomobject]@{
        Root           = $root
        LocalRoot      = $localRoot
        CentralRoot    = $centralRoot
        ProjectCode    = $projectCode
        HubScript      = Join-Path $hub $HubScriptName
        CentralMaster  = $centralMaster
        CentralControl = $centralControl
        CentralBackups = $centralBackups
        LockPath       = Join-Path $centralControl 'PROJECT-LOCK.json'
    }
}

function New-HubOnlyWorld {
    <#
    .SYNOPSIS
        Builds a world with an installed Hub but NO central project.

    .DESCRIPTION
        New-TestWorld hand-builds a central project, because the tests that use it are
        about what the Hub does to a project that already exists. Provisioning is the
        opposite case: the central root is empty and the project has to be created. This
        builds that starting point and nothing more.

        Deliberately not folded into New-TestWorld: those tests are green against two
        different copies of the engine, and reshaping their world to serve a third
        purpose is how a passing suite quietly stops testing what it claims to.
    #>
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $HubScriptName,
        [Parameter(Mandatory)][string] $ProjectCode,
        [string] $IdentityUserId = 'TESTADMIN'
    )

    $root        = Join-Path ([IO.Path]::GetTempPath()) ('sabhub-prov-' + [guid]::NewGuid().ToString('N'))
    $localRoot   = Join-Path $root 'LOCAL'
    $centralRoot = Join-Path $root 'CENTRAL'
    $hub         = Join-Path $localRoot '_HUB'

    New-Item -ItemType Directory -Force -Path @(
        $hub, (Join-Path $hub 'Config'), (Join-Path $hub 'Languages'), $centralRoot, $localRoot
    ) | Out-Null

    Copy-Item -LiteralPath (Join-Path $Source 'TeamConfig.json') -Destination (Join-Path $hub 'TeamConfig.json')
    Get-ChildItem -LiteralPath $Source -File -Filter '*.ps1' |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $hub $_.Name) }
    Get-ChildItem -LiteralPath (Join-Path $Source 'Languages') -File -Filter '*.json' |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $hub 'Languages') }

    $identityNames = @{ TESTADMIN = 'Test administrator'; TESTMEMBER = 'Test member' }
    Write-Utf8Json -Path (Join-Path $hub 'Users.json') -Value ([pscustomobject]@{
        schemaVersion = 1
        users = @(
            [pscustomobject]@{ id = 'TESTADMIN';  displayName = 'Test administrator'; role = 'administrator'; enabled = $true }
            [pscustomobject]@{ id = 'TESTMEMBER'; displayName = 'Test member';        role = 'member';        enabled = $true }
        )
    })

    Write-Utf8Json -Path (Join-Path $hub 'Config\Identity.json') -Value ([pscustomobject][ordered]@{
        schemaVersion = 1
        userId        = $IdentityUserId
        displayName   = $identityNames[$IdentityUserId]
        role          = if ($IdentityUserId -eq 'TESTADMIN') { 'administrator' } else { 'member' }
        windowsUser   = $env:USERNAME
        computerName  = $env:COMPUTERNAME
        uiLanguage    = 'en'
        createdUtc    = (Get-Date).ToUniversalTime().ToString('o')
    })

    [pscustomobject]@{
        Root            = $root
        LocalRoot       = $localRoot
        CentralRoot     = $centralRoot
        ProjectCode     = $ProjectCode
        HubScript       = Join-Path $hub $HubScriptName
        ProvisionScript = Join-Path $hub 'New-TeamProject.ps1'
        CentralProject  = Join-Path $centralRoot $ProjectCode
    }
}

function Invoke-HubAction {
    <#
    .SYNOPSIS
        Runs the real hub script and returns its exit code.

    .PARAMETER Answer
        Fed to the script's confirmation prompt on stdin, when it asks for one.
    #>
    param(
        [Parameter(Mandatory)] $World,
        [Parameter(Mandatory)][string] $Action,
        [string] $Answer = ''
    )
    $Answer | powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $World.HubScript -Action $Action -Project $World.ProjectCode `
        -UiLanguage en -LocalRoot $World.LocalRoot -CentralRoot $World.CentralRoot | Out-Null
    return $LASTEXITCODE
}

function Remove-TestWorld {
    param([Parameter(Mandatory)] $World)
    if ($World -and (Test-Path -LiteralPath $World.Root)) {
        Remove-Item -LiteralPath $World.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function New-TestWorld, New-HubOnlyWorld, Invoke-HubAction, Remove-TestWorld, Write-Utf8Json
