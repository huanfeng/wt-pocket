#Requires -Version 7.4
[CmdletBinding()]
param([string] $ArchivePath, [string] $ChecksumPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wtpocket-release-' + [guid]::NewGuid().ToString('N'))
$checks = 0
# Hosted Windows CI has no interactive Terminal; this test never launches it.
# Stub only prerequisite discovery while exercising the real installer below.
$stubTerminal = -not [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)
if ($stubTerminal) { function wt.exe { throw 'Release installer tests must never launch Windows Terminal.' } }
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Write-Checksum([string] $Archive, [string] $Path) {
    [IO.File]::WriteAllText($Path, ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() +
        '  ' + [IO.Path]::GetFileName($Archive) + "`n"))
}
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    if (-not $ArchivePath) {
        $stage = Join-Path $testRoot 'package'
        foreach ($relative in @('powershell', 'scripts', 'src', 'artifacts/host')) {
            [IO.Directory]::CreateDirectory((Join-Path $stage $relative)) | Out-Null
        }
        foreach ($relative in @('LICENSE', 'README.md', 'powershell/WtTools.psm1', 'powershell/Startup.ps1',
                'scripts/Install-WtTools.ps1', 'scripts/Uninstall-WtTools.ps1', 'scripts/Start-WtToolsHost.ps1',
                'artifacts/host/wttools-host.exe', 'artifacts/host/WtTools.ShellNative.dll')) {
            Copy-Item -LiteralPath (Join-Path $root $relative) -Destination (Join-Path $stage $relative)
        }
        $ArchivePath = Join-Path $testRoot 'wtpocket-v0.1.0-win-x64.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $ArchivePath)
    }
    $ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
    if (-not $ChecksumPath) {
        $ChecksumPath = Join-Path $testRoot 'SHA256SUMS'
        Write-Checksum $ArchivePath $ChecksumPath
    }
    $testProfilePath = Join-Path $testRoot "user a'b/profile.ps1"
    $destination = Join-Path $testRoot "app a'b"
    $state = Join-Path $testRoot 'state'
    [IO.Directory]::CreateDirectory((Split-Path $testProfilePath -Parent)) | Out-Null
    $originalProfile = '# Preserve this existing profile: $literal' + "`r`n"
    [IO.File]::WriteAllText($testProfilePath, $originalProfile)
    $arguments = @{ ArchivePath=$ArchivePath; Destination=$destination; ProfilePath=$testProfilePath; StateRoot=$state }
    $badChecksum = Join-Path $testRoot 'bad-checksums.txt'
    [IO.File]::WriteAllText($badChecksum, ('0' * 64 + '  ' + [IO.Path]::GetFileName($ArchivePath) + "`n"))
    $rejected = $false
    try { & (Join-Path $root 'install.ps1') @arguments -ChecksumPath $badChecksum | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'SHA256|checksum|hash' }
    Assert-True $rejected 'Installer rejects an invalid checksum'
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $originalProfile) 'Checksum failure leaves the profile untouched'
    Assert-True (-not (Test-Path -LiteralPath $destination)) 'Checksum failure does not install files'

    # Migrate a legacy flat installation while a shell holds a DIFFERENT helper
    # open. The old installer failed here even from a fresh PowerShell process.
    $legacyHelper = Join-Path $destination 'host/WtTools.ShellNative.dll'
    [IO.Directory]::CreateDirectory((Split-Path $legacyHelper -Parent)) | Out-Null
    [IO.File]::WriteAllText($legacyHelper, 'Locked old native helper with different bytes')
    $legacyHash = (Get-FileHash -LiteralPath $legacyHelper).Hash
    $heldLegacy = [IO.File]::Open($legacyHelper, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { & (Join-Path $root 'install.ps1') @arguments -ChecksumPath $ChecksumPath | Out-Null }
    finally { $heldLegacy.Dispose() }
    Assert-True ((Get-FileHash -LiteralPath $legacyHelper).Hash -eq $legacyHash) 'Legacy upgrade leaves a locked, different DLL untouched'
    $installedRoot = (Get-Content -LiteralPath (Join-Path $destination 'current.json') -Raw | ConvertFrom-Json).path
    $firstProfile = [IO.File]::ReadAllText($testProfilePath)
    Assert-True ($firstProfile.StartsWith($originalProfile)) 'Release installation preserves the existing profile'
    Assert-True ([regex]::Matches($firstProfile, '(?m)^# >>> wttools >>>').Count -eq 1) 'Release installation adds one managed profile block'
    Assert-True ([IO.File]::Exists((Join-Path $installedRoot 'powershell/Startup.ps1'))) 'Release installs the lazy startup script'
    Assert-True ([IO.File]::Exists((Join-Path $installedRoot 'host/wttools-host.exe'))) 'Release installs the compiled host'
    Assert-True ([IO.File]::Exists((Join-Path $installedRoot 'LICENSE'))) 'Installed application retains its MIT license'
    Assert-True (-not [IO.File]::Exists((Join-Path $installedRoot 'host/coreclr.dll'))) 'Rust installation contains no bundled .NET runtime'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $installedRoot 'host') -File).Count -eq 2) 'Host payload contains only the native executable and PowerShell helper'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $testProfilePath -Parent) -Filter '*.bak').Count -gt 0) 'Existing profile is backed up'

    if ([IO.File]::Exists((Join-Path $installedRoot 'host/wttools-host.exe'))) {
        # Native releases run from the installed directory without a runtime
        # bundle. This never creates a Terminal or panel window.
        $pipeName = 'wtpocket-release-test-' + [guid]::NewGuid().ToString('N')
        $healthState = Join-Path $testRoot 'host-health'
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $installedRoot 'host/wttools-host.exe'))
        $start.UseShellExecute = $false
        foreach ($argument in @($pipeName, $healthState, (Join-Path $installedRoot 'powershell/WtTools.psm1'),
                (Join-Path $PSHOME 'pwsh.exe'))) { $start.ArgumentList.Add($argument) }
        $runningHost = [Diagnostics.Process]::Start($start)
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
        try {
            $pipe.Connect(10000)
            Assert-True (-not $runningHost.HasExited) 'Installed native Rust release host starts'
            Assert-True ((Get-Content -LiteralPath (Join-Path $healthState 'host.json') -Raw | ConvertFrom-Json).backend -eq 'rust') 'Installed release runs the Rust backend'
            $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
            $writer.AutoFlush = $true
            $reader = [IO.StreamReader]::new($pipe)
            $writer.WriteLine('{"action":"shutdown"}')
            $reply = $reader.ReadLineAsync()
            Assert-True ($reply.Wait(5000) -and ($reply.Result | ConvertFrom-Json).ok) 'Release host serves IPC requests'
            Assert-True ($runningHost.WaitForExit(5000)) 'Release host stops cleanly'
        } finally {
            $pipe.Dispose()
            if (-not $runningHost.HasExited) { $runningHost.Kill(); $runningHost.WaitForExit() }
            $runningHost.Dispose()
        }
    }

    # Reinstall while the native helper is held open, just as an existing shell
    # holds it. Identical helper bytes must not require closing users' shells.
    $helper = Join-Path $installedRoot 'host/WtTools.ShellNative.dll'
    $held = [IO.File]::Open($helper, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { & (Join-Path $root 'install.ps1') @arguments -ChecksumPath $ChecksumPath | Out-Null }
    finally { $held.Dispose() }
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $firstProfile) 'Release reinstall is idempotent even with the helper in use'
    Assert-True ((Get-Content -LiteralPath (Join-Path $destination 'current.json') -Raw | ConvertFrom-Json).path -ceq $installedRoot) 'Identical reinstall reuses the immutable payload'

    # Upgrade between versioned payloads, with the previous helper held open.
    $upgradeStage = Join-Path $testRoot 'upgrade-package'
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $upgradeStage)
    $changedHelper = Join-Path $upgradeStage 'artifacts/host/WtTools.ShellNative.dll'
    [IO.File]::WriteAllText($changedHelper, 'Different helper bytes for upgrade regression; never executed')
    $oldHelperHash = (Get-FileHash -LiteralPath $helper).Hash
    $held = [IO.File]::Open($helper, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        & (Join-Path $upgradeStage 'scripts/Install-WtTools.ps1') -Destination $destination -ProfilePath $testProfilePath -StateRoot $state | Out-Null
    } finally { $held.Dispose() }
    $upgradedRoot = (Get-Content -LiteralPath (Join-Path $destination 'current.json') -Raw | ConvertFrom-Json).path
    Assert-True ($upgradedRoot -cne $installedRoot) 'Changed payload activates a new directory'
    Assert-True ((Get-FileHash -LiteralPath $helper).Hash -eq $oldHelperHash) 'Versioned upgrade preserves the locked old helper'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $upgradedRoot 'host/WtTools.ShellNative.dll')).Hash -eq (Get-FileHash -LiteralPath $changedHelper).Hash) 'New version contains the changed helper'
    Assert-True ([IO.File]::ReadAllText($testProfilePath).Contains($upgradedRoot.Replace("'", "''"))) 'Profile switches to the verified new payload'

    $profileBeforeFailure = [IO.File]::ReadAllText($testProfilePath)
    $currentBeforeFailure = [IO.File]::ReadAllText((Join-Path $destination 'current.json'))
    [IO.File]::Delete((Join-Path $upgradeStage 'powershell/Startup.ps1'))
    $rejected = $false
    try {
        & (Join-Path $upgradeStage 'scripts/Install-WtTools.ps1') -Destination $destination -ProfilePath $testProfilePath -StateRoot $state | Out-Null
    } catch { $rejected = $true }
    Assert-True $rejected 'Incomplete upgrade is rejected'
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $profileBeforeFailure) 'Failed upgrade preserves the active profile'
    Assert-True ([IO.File]::ReadAllText((Join-Path $destination 'current.json')) -ceq $currentBeforeFailure) 'Failed upgrade preserves active version metadata'

    # Return to the real payload before testing uninstall (the changed DLL is
    # intentionally not a valid assembly and must never be imported).
    & (Join-Path $root 'install.ps1') @arguments -ChecksumPath $ChecksumPath | Out-Null

    # A failure at activation must also roll back current.json, not leave
    # uninstall targeting a version the profile never activated.
    Copy-Item -LiteralPath (Join-Path $installedRoot 'powershell/Startup.ps1') -Destination (Join-Path $upgradeStage 'powershell/Startup.ps1')
    $currentBeforeFailure = [IO.File]::ReadAllText((Join-Path $destination 'current.json'))
    $heldProfile = [IO.File]::Open($testProfilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $rejected = $false
    try {
        try {
            & (Join-Path $upgradeStage 'scripts/Install-WtTools.ps1') -Destination $destination -ProfilePath $testProfilePath -StateRoot $state | Out-Null
        } catch { $rejected = $true }
    } finally { $heldProfile.Dispose() }
    Assert-True $rejected 'Profile activation failure is reported'
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $firstProfile) 'Profile activation failure leaves the old profile intact'
    Assert-True ([IO.File]::ReadAllText((Join-Path $destination 'current.json')) -ceq $currentBeforeFailure) 'Profile activation failure rolls back current.json'

    $uninstaller = Join-Path $root 'scripts/Uninstall-WtTools.ps1'
    & $uninstaller -Destination $destination -ProfilePath $testProfilePath -StateRoot $state | Out-Null
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $originalProfile) 'Release uninstall restores the existing profile exactly'
    Assert-True ([IO.File]::Exists($helper)) 'Uninstall retains installed files'

    # Test exactly the README's pipeline-to-iex execution mode, in a child
    # process with a synthetic host profile and mocked network downloads.
    $pipelineFixture = Join-Path $testRoot 'PipelineInstall.ps1'
    $pipelineCode = @'
param($FixtureInstallerPath, $FixtureZipPath, $FixtureChecksumPath, $FixtureRoot)
$ErrorActionPreference = 'Stop'
$PROFILE = Join-Path $FixtureRoot 'Microsoft.PowerShell_profile.ps1'
$PROFILE = $PROFILE | Add-Member NoteProperty CurrentUserAllHosts (Join-Path $FixtureRoot 'profile.ps1') -PassThru
$PROFILE = $PROFILE | Add-Member NoteProperty CurrentUserCurrentHost ([string]$PROFILE) -PassThru
function wt.exe { throw 'This fixture must not start a terminal.' }
function Invoke-RestMethod {
    param($Uri, $Headers)
    $name = [IO.Path]::GetFileName($FixtureZipPath)
    if ($name -notmatch '^wtpocket-(v.+)-win-(?:x64|arm64)\.zip$') { throw 'Unexpected fixture ZIP name' }
    @{ tag_name = $Matches[1] }
}
function Invoke-WebRequest {
    param($Uri, $OutFile, $Headers)
    $source = if ($Uri.EndsWith('/SHA256SUMS')) { $FixtureChecksumPath } else { $FixtureZipPath }
    Copy-Item -LiteralPath $source -Destination $OutFile
}
Get-Content -LiteralPath $FixtureInstallerPath -Raw | Invoke-Expression
$active = (Get-Content -LiteralPath (Join-Path $FixtureRoot 'wttools/app/current.json') -Raw | ConvertFrom-Json).path
if (-not [IO.File]::Exists((Join-Path $active 'LICENSE'))) { throw 'Pipeline installer did not complete' }
if (-not [IO.File]::ReadAllText($PROFILE).Contains('# >>> wttools >>>')) { throw 'Pipeline installer did not configure the fixture profile' }
'PASS: README pipeline installer execution mode.'
'@
    [IO.File]::WriteAllText($pipelineFixture, $pipelineCode)
    $pipelineRoot = Join-Path $testRoot 'pipeline-host'
    [IO.Directory]::CreateDirectory($pipelineRoot) | Out-Null
    & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File $pipelineFixture `
        -FixtureInstallerPath (Join-Path $root 'install.ps1') -FixtureZipPath $ArchivePath `
        -FixtureChecksumPath $ChecksumPath -FixtureRoot $pipelineRoot | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'README pipeline-to-iex installation works with default parameters'

    $malicious = Join-Path $testRoot 'traversal.zip'
    $zip = [IO.Compression.ZipFile]::Open($malicious, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry('../escaped.txt')
        $writer = [IO.StreamWriter]::new($entry.Open())
        try { $writer.Write('Must not be extracted') } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    $maliciousSums = Join-Path $testRoot 'traversal-sums.txt'
    Write-Checksum $malicious $maliciousSums
    $rejected = $false
    try {
        & (Join-Path $root 'install.ps1') -ArchivePath $malicious -ChecksumPath $maliciousSums `
            -Destination $destination -ProfilePath $testProfilePath -StateRoot $state | Out-Null
    } catch { $rejected = $true }
    Assert-True $rejected 'Even a checksummed archive cannot escape its extraction directory'
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $originalProfile) 'Rejected archive leaves the profile untouched'
    Write-Output "PASS: $checks release installation checks (isolated profile, no network required)."
} finally {
    Remove-Module WtTools -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside temp directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
