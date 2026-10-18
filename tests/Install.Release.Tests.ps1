#Requires -Version 7.4
# Installs a release ZIP through install.ps1 (offline: -ArchivePath/-ChecksumPath)
# into an isolated profile, state and destination, then verifies the result.
# Windows Terminal settings are redirected to a fixture via LOCALAPPDATA, so the
# user's real settings.json, profile and state are never touched.
[CmdletBinding()]
param([string] $ArchivePath, [string] $ChecksumPath)
$ErrorActionPreference = 'Stop'
# Messages are asserted in English regardless of the machine's display language.
$env:WTPOCKET_LANG = 'en'
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wtpocket-release-' + [guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
$originalSession = $env:WT_SESSION
$originalProfileId = $env:WT_PROFILE_ID
$originalPanel = $env:WTTOOLS_PANEL
$utf8 = [Text.UTF8Encoding]::new($false)
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
# Creates a ZIP from name -> bytes entries (names are written verbatim).
function New-Zip([string] $Path, [System.Collections.Specialized.OrderedDictionary] $Entries, [hashtable] $Attributes = @{}) {
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($key in $Entries.Keys) {
            $entry = $zip.CreateEntry($key)
            if ($Attributes.ContainsKey($key)) { $entry.ExternalAttributes = $Attributes[$key] }
            $stream = $entry.Open()
            try { $bytes = [byte[]] $Entries[$key]; $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
}
function Get-VersionDirs([string] $Destination) {
    $versions = Join-Path $Destination 'versions'
    if (-not [IO.Directory]::Exists($versions)) { return @() }
    @(Get-ChildItem -LiteralPath $versions -Directory)
}
function Get-ActiveStartup([string] $ProfilePath) {
    [regex]::Match([IO.File]::ReadAllText($ProfilePath), "(?m)\. '([^\r\n]*?Startup\.ps1)'").Groups[1].Value.Replace("''", "'")
}
function Invoke-Wtp([string] $Exe, [string[]] $Arguments) {
    $output = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}
function Invoke-ReleaseInstaller([hashtable] $Arguments) {
    # Returns the error message, or $null when the installer succeeded.
    try { & (Join-Path $root 'install.ps1') @Arguments | Out-Null; $null }
    catch { $_.Exception.Message }
}
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    # An empty LOCALAPPDATA keeps `wtpocket.exe install` away from the real Windows Terminal settings.
    $localAppData = Join-Path $testRoot 'localappdata'
    $terminalSettings = Join-Path $localAppData 'Microsoft/Windows Terminal/settings.json'
    [IO.Directory]::CreateDirectory((Split-Path $terminalSettings -Parent)) | Out-Null
    $terminalOriginal = "{`n    // fixture`n    `"defaultProfile`": `"x`"`n}`n"
    [IO.File]::WriteAllText($terminalSettings, $terminalOriginal, $utf8)
    $env:LOCALAPPDATA = $localAppData

    $hostDir = Join-Path $root 'artifacts/host'
    if (-not $ArchivePath) {
        if (-not [IO.File]::Exists((Join-Path $hostDir 'wtpocket.exe'))) { & (Join-Path $root 'scripts/Build.ps1') | Out-Null }
        $entries = [ordered]@{}
        foreach ($name in 'wtpocket.exe', 'Startup.ps1', 'LICENSE') { $entries[$name] = [IO.File]::ReadAllBytes((Join-Path $hostDir $name)) }
        $entries['release.json'] = $utf8.GetBytes('{"product":"WTPocket","version":"0.3.2","backend":"rust"}')
        $ArchivePath = Join-Path $testRoot 'wtpocket-v0.1.0-win-x64.zip'
        New-Zip $ArchivePath $entries
    }
    $ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
    if (-not $ChecksumPath) {
        $ChecksumPath = Join-Path $testRoot 'SHA256SUMS'
        Write-Checksum $ArchivePath $ChecksumPath
    }
    $ChecksumPath = [IO.Path]::GetFullPath($ChecksumPath)
    $archiveName = [IO.Path]::GetFileName($ArchivePath)
    $package = Join-Path $testRoot 'reference-package'
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $package)

    $testProfilePath = Join-Path $testRoot "user a'b/profile.ps1"
    $destination = Join-Path $testRoot "app a'b"
    $state = Join-Path $testRoot 'state'
    [IO.Directory]::CreateDirectory((Split-Path $testProfilePath -Parent)) | Out-Null
    $originalProfile = '# Preserve this existing profile: $literal' + "`r`n"
    [IO.File]::WriteAllText($testProfilePath, $originalProfile, $utf8)
    $arguments = @{ ArchivePath = $ArchivePath; Destination = $destination; ProfilePath = $testProfilePath; StateRoot = $state }
    function Assert-NothingChanged([string] $What) {
        Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $originalProfile) "$What leaves the profile untouched"
        Assert-True (-not (Test-Path -LiteralPath $destination)) "$What installs no files"
        Assert-True ([IO.File]::ReadAllText($terminalSettings) -ceq $terminalOriginal) "$What leaves Terminal settings untouched"
    }

    # --- rejections happen before any change --------------------------------
    $badChecksum = Join-Path $testRoot 'bad-checksums.txt'
    [IO.File]::WriteAllText($badChecksum, ('0' * 64 + '  ' + $archiveName + "`n"))
    $message = Invoke-ReleaseInstaller ($arguments + @{ ChecksumPath = $badChecksum })
    Assert-True ($message -match 'SHA256|checksum|hash') 'Installer rejects an invalid checksum'
    Assert-NothingChanged 'A checksum mismatch'

    $otherSums = Join-Path $testRoot 'other-checksums.txt'
    [IO.File]::WriteAllText($otherSums, ((Get-FileHash $ArchivePath).Hash.ToLowerInvariant() + "  some-other-file.zip`n"))
    $message = Invoke-ReleaseInstaller ($arguments + @{ ChecksumPath = $otherSums })
    Assert-True ($message -match 'exactly one checksum') 'Installer rejects a SHA256SUMS without an entry for the archive'
    Assert-NothingChanged 'A missing checksum entry'

    $dupSums = Join-Path $testRoot 'dup-checksums.txt'
    $line = (Get-FileHash $ArchivePath).Hash.ToLowerInvariant() + '  ' + $archiveName
    [IO.File]::WriteAllText($dupSums, "$line`n$line`n")
    $message = Invoke-ReleaseInstaller ($arguments + @{ ChecksumPath = $dupSums })
    Assert-True ($message -match 'exactly one checksum') 'Installer rejects ambiguous duplicate checksum entries'

    $message = Invoke-ReleaseInstaller @{ ChecksumPath = $ChecksumPath; Destination = $destination; ProfilePath = $testProfilePath; StateRoot = $state }
    Assert-True ($message -match 'requires -ArchivePath') '-ChecksumPath without -ArchivePath is rejected'
    $message = Invoke-ReleaseInstaller ($arguments + @{ Version = 'v1.2.3' })
    Assert-True ($message -match 'either -ArchivePath') '-ArchivePath together with -Version is rejected'
    $message = Invoke-ReleaseInstaller @{ Version = '1.2.3; calc'; Destination = $destination; ProfilePath = $testProfilePath; StateRoot = $state }
    Assert-True ($message -match 'Invalid WTPocket version') 'A malformed -Version is rejected'
    $emptyDestination = $arguments.Clone(); $emptyDestination['ChecksumPath'] = $ChecksumPath; $emptyDestination['Destination'] = ' '
    $message = Invoke-ReleaseInstaller $emptyDestination
    Assert-True ($message -match 'must not be empty') 'An empty -Destination is rejected'
    Assert-NothingChanged 'Rejected parameters'

    # Unsafe ZIPs are rejected even when their checksum is correct.
    $unsafeCases = [ordered]@{
        'traversal' = @{ Entries = [ordered]@{ '../escaped.txt' = $utf8.GetBytes('x') }; Pattern = 'Unsafe ZIP entry' }
        'backslash-traversal' = @{ Entries = [ordered]@{ '..\escaped2.txt' = $utf8.GetBytes('x') }; Pattern = 'Unsafe ZIP entry' }
        'drive-letter' = @{ Entries = [ordered]@{ 'C:/wtpocket-evil.txt' = $utf8.GetBytes('x') }; Pattern = 'Unsafe ZIP entry' }
        'rooted' = @{ Entries = [ordered]@{ '/wtpocket-evil.txt' = $utf8.GetBytes('x') }; Pattern = 'Unsafe ZIP entry' }
        'symlink' = @{ Entries = [ordered]@{ 'link' = $utf8.GetBytes('target') }; Attributes = @{ link = [int] 0xA1FF0000 }; Pattern = 'symbolic links' }
        'duplicate' = @{ Entries = $null; Pattern = 'Duplicate ZIP entry' }
    }
    foreach ($name in $unsafeCases.Keys) {
        $case = $unsafeCases[$name]
        $malicious = Join-Path $testRoot "unsafe-$name.zip"
        if ($name -eq 'duplicate') {
            # Same path differing only in case: Windows extraction would collide.
            $zip = [IO.Compression.ZipFile]::Open($malicious, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($entryName in 'Startup.ps1', 'startup.PS1') {
                    $stream = $zip.CreateEntry($entryName).Open()
                    try { $stream.Write($utf8.GetBytes($entryName), 0, $entryName.Length) } finally { $stream.Dispose() }
                }
            } finally { $zip.Dispose() }
        } else {
            New-Zip $malicious $case.Entries ($case.Attributes ?? @{})
        }
        $sums = Join-Path $testRoot "unsafe-$name-sums.txt"
        Write-Checksum $malicious $sums
        $message = Invoke-ReleaseInstaller @{ ArchivePath = $malicious; ChecksumPath = $sums; Destination = $destination; ProfilePath = $testProfilePath; StateRoot = $state }
        Assert-True ([bool]$message -and $message -match $case.Pattern) "A checksummed '$name' archive is rejected ($message)"
        Assert-NothingChanged "The rejected '$name' archive"
    }
    Assert-True (-not [IO.File]::Exists((Join-Path $testRoot 'escaped.txt'))) 'No traversal entry escaped the extraction directory'

    # Incomplete packages are rejected with a clear message before any change.
    foreach ($missing in 'wtpocket.exe', 'Startup.ps1', 'LICENSE') {
        $entries = [ordered]@{}
        foreach ($file in Get-ChildItem -LiteralPath $package -File | Where-Object Name -cne $missing) { $entries[$file.Name] = [IO.File]::ReadAllBytes($file.FullName) }
        $incomplete = Join-Path $testRoot "incomplete-$missing.zip"
        New-Zip $incomplete $entries
        $sums = Join-Path $testRoot "incomplete-$missing-sums.txt"
        Write-Checksum $incomplete $sums
        $message = Invoke-ReleaseInstaller @{ ArchivePath = $incomplete; ChecksumPath = $sums; Destination = $destination; ProfilePath = $testProfilePath; StateRoot = $state }
        Assert-True ($message -match "package is incomplete: missing '$([regex]::Escape($missing))'") "A package without $missing is rejected as incomplete"
        Assert-NothingChanged "The package without $missing"
    }

    # --- real installation --------------------------------------------------
    $message = Invoke-ReleaseInstaller ($arguments + @{ ChecksumPath = $ChecksumPath })
    Assert-True ($null -eq $message) "Release installation succeeds ($message)"
    $dirs = Get-VersionDirs $destination
    Assert-True ($dirs.Count -eq 1 -and $dirs[0].Name -match '^[0-9a-f]{64}$') 'Release installation creates one content-addressed version directory'
    $installedRoot = $dirs[0].FullName
    $firstProfile = [IO.File]::ReadAllText($testProfilePath)
    Assert-True ($firstProfile.StartsWith($originalProfile)) 'Release installation preserves the existing profile'
    Assert-True ([regex]::Matches($firstProfile, '(?m)^# >>> wttools >>>').Count -eq 1) 'Release installation adds one managed profile block'
    Assert-True ((Get-ActiveStartup $testProfilePath) -ceq (Join-Path $installedRoot 'Startup.ps1')) 'The profile block activates the installed Startup.ps1'
    $installedNames = @(Get-ChildItem -LiteralPath $installedRoot -File | ForEach-Object Name)
    foreach ($required in 'wtpocket.exe', 'Startup.ps1', 'LICENSE') {
        Assert-True ($installedNames -ccontains $required) "Release installs $required"
        Assert-True ((Get-FileHash (Join-Path $installedRoot $required)).Hash -eq (Get-FileHash (Join-Path $package $required)).Hash) "Installed $required matches the package"
    }
    Assert-True (@($installedNames | Where-Object { $_ -cnotin @('wtpocket.exe', 'Startup.ps1', 'LICENSE', 'THIRD-PARTY-NOTICES.txt') }).Count -eq 0) 'The installed payload is only the flat executable, shim and notices'
    Assert-True (@(Get-ChildItem -LiteralPath $installedRoot -Directory).Count -eq 0) 'The installed payload has no subdirectories (and no bundled runtime)'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $testProfilePath -Parent) -Filter '*.bak').Count -gt 0) 'The existing profile is backed up'
    $terminalInstalled = [IO.File]::ReadAllText($terminalSettings)
    Assert-True ($terminalInstalled.Contains('User.WTPocket.ExitFocus') -and $terminalInstalled.Contains('ctrl+shift+alt+f24')) 'Installation adds the focus-mode exit key to the (fixture) Terminal settings'

    $installedExe = Join-Path $installedRoot 'wtpocket.exe'
    $versionResult = Invoke-Wtp $installedExe @('version')
    Assert-True ($versionResult.ExitCode -eq 0 -and $versionResult.Output -match '^wtpocket \d+\.\d+\.\d+') 'The installed wtpocket.exe runs and reports its version'
    $releaseJson = Join-Path $package 'release.json'
    if ([IO.File]::Exists($releaseJson)) {
        $expectedVersion = (Get-Content -LiteralPath $releaseJson -Raw | ConvertFrom-Json).version
        Assert-True ($versionResult.Output -ceq "wtpocket $expectedVersion") 'The installed executable version matches release.json'
    }
    $stopResult = Invoke-Wtp $installedExe @('stop', '--state', $state)
    Assert-True ($stopResult.ExitCode -eq 0 -and $stopResult.Output -match 'not running') 'The installed executable can query its (not running) host'

    # The installed Startup.ps1 loads in a Windows Terminal session.
    $loadScript = Join-Path $testRoot 'load-profile.ps1'
    [IO.File]::WriteAllText($loadScript, @'
param($ProfilePath)
$messages = @(. $ProfilePath 3>&1 2>&1 | ForEach-Object { "$_" })
[pscustomobject]@{
    HasFunction = [bool](Get-Command wtpocket -CommandType Function -ErrorAction SilentlyContinue)
    StateRoot   = if ($global:WtPocketState) { $global:WtPocketState.StateRoot } else { $null }
    Messages    = $messages
} | ConvertTo-Json -Compress
'@)
    $env:WT_SESSION = 'release-test'; $env:WT_PROFILE_ID = [guid]::NewGuid().ToString(); $env:WTTOOLS_PANEL = $null
    try { $loadOutput = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File $loadScript -ProfilePath $testProfilePath 2>&1 | Out-String }
    finally { $env:WT_SESSION = $originalSession; $env:WT_PROFILE_ID = $originalProfileId; $env:WTTOOLS_PANEL = $originalPanel }
    $loaded = $loadOutput.Trim().Split("`n")[-1] | ConvertFrom-Json
    Assert-True ($loaded.HasFunction -and @($loaded.Messages).Count -eq 0) "The installed profile block and Startup.ps1 load cleanly ($loadOutput)"
    Assert-True ($loaded.StateRoot -ceq $state) 'The installed shim uses the isolated state directory'

    # --- reinstall with the old executable in use ---------------------------
    $held = [IO.File]::Open($installedExe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $message = Invoke-ReleaseInstaller ($arguments + @{ ChecksumPath = $ChecksumPath }) }
    finally { $held.Dispose() }
    Assert-True ($null -eq $message) "Reinstall succeeds while wtpocket.exe is in use ($message)"
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $firstProfile) 'Release reinstall is idempotent even with the executable in use'
    Assert-True ((Get-VersionDirs $destination).Count -eq 1) 'Identical reinstall reuses the immutable payload'
    Assert-True ([IO.File]::ReadAllText($terminalSettings) -ceq $terminalInstalled) 'Reinstall leaves the Terminal settings unchanged'

    # --- upgrade between two different payloads, old exe locked -------------
    $upgradeStage = Join-Path $testRoot 'upgrade-package'
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $upgradeStage)
    [IO.File]::AppendAllText((Join-Path $upgradeStage 'Startup.ps1'), "`n# upgrade regression variant`n")
    $oldHashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $installedRoot -File) { $oldHashes[$file.Name] = (Get-FileHash $file.FullName).Hash }
    $held = [IO.File]::Open($installedExe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $upgrade = Invoke-Wtp (Join-Path $upgradeStage 'wtpocket.exe') @('install', '--destination', $destination, '--profile', $testProfilePath, '--state', $state)
    } finally { $held.Dispose() }
    Assert-True ($upgrade.ExitCode -eq 0) "Upgrade succeeds while the previous wtpocket.exe is locked ($($upgrade.Output))"
    $dirs = Get-VersionDirs $destination
    Assert-True ($dirs.Count -eq 2) 'A changed payload activates a new directory'
    $upgradedRoot = ($dirs | Where-Object FullName -cne $installedRoot).FullName
    $oldIntact = $true
    foreach ($name in $oldHashes.Keys) { if ((Get-FileHash (Join-Path $installedRoot $name)).Hash -ne $oldHashes[$name]) { $oldIntact = $false } }
    Assert-True ($oldIntact -and @(Get-ChildItem -LiteralPath $installedRoot -File).Count -eq $oldHashes.Count) 'The older version directory is left intact'
    Assert-True ((Get-FileHash (Join-Path $upgradedRoot 'Startup.ps1')).Hash -eq (Get-FileHash (Join-Path $upgradeStage 'Startup.ps1')).Hash) 'The new version contains the changed Startup.ps1'
    Assert-True ((Get-ActiveStartup $testProfilePath) -ceq (Join-Path $upgradedRoot 'Startup.ps1')) 'The profile switches to the new payload'
    Assert-True ([regex]::Matches([IO.File]::ReadAllText($testProfilePath), '(?m)^# >>> wttools >>>').Count -eq 1) 'The upgrade keeps a single managed profile block'
    Assert-True ([IO.File]::ReadAllText($testProfilePath).StartsWith($originalProfile)) 'The upgrade keeps the user profile content'

    # A failed upgrade changes nothing.
    $profileBeforeFailure = [IO.File]::ReadAllText($testProfilePath)
    [IO.File]::Delete((Join-Path $upgradeStage 'Startup.ps1'))
    $failed = Invoke-Wtp (Join-Path $upgradeStage 'wtpocket.exe') @('install', '--destination', $destination, '--profile', $testProfilePath, '--state', $state, '--no-terminal-settings')
    Assert-True ($failed.ExitCode -ne 0 -and $failed.Output -match 'incomplete') 'An incomplete upgrade package is rejected'
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $profileBeforeFailure) 'A failed upgrade preserves the active profile'
    Assert-True ((Get-VersionDirs $destination).Count -eq 2) 'A failed upgrade adds no version directory'

    # Return to the real payload, then uninstall.
    $message = Invoke-ReleaseInstaller ($arguments + @{ ChecksumPath = $ChecksumPath })
    Assert-True ($null -eq $message) 'Re-running the release installer returns to the real payload'
    Assert-True ((Get-ActiveStartup $testProfilePath) -ceq (Join-Path $installedRoot 'Startup.ps1')) 'The profile points at the release payload again'
    $uninstall = Invoke-Wtp $installedExe @('uninstall', '--destination', $destination, '--profile', $testProfilePath, '--state', $state)
    Assert-True ($uninstall.ExitCode -eq 0) 'Release uninstall succeeds'
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $originalProfile) 'Release uninstall restores the existing profile exactly'
    Assert-True ([IO.File]::ReadAllText($terminalSettings) -ceq $terminalOriginal) 'Release uninstall restores the Terminal settings exactly'
    Assert-True ([IO.File]::Exists($installedExe)) 'Uninstall retains installed files'

    # --- README pipeline-to-iex execution mode ------------------------------
    # A child process mocks the network and runs install.ps1 through
    # Invoke-Expression, exactly as `irm ... | iex`. Without bound parameters the
    # real installer would target the user's real Documents\PowerShell, so the
    # extracted wtpocket.exe is swapped for a harmless system executable: the test
    # proves download, checksum, ZIP validation and extraction work in this mode
    # and that the script then reaches (and reports a failure of) the install step.
    $realProfile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Microsoft.PowerShell_profile.ps1'
    $realProfileBefore = if ([IO.File]::Exists($realProfile)) { (Get-FileHash -LiteralPath $realProfile).Hash } else { '' }
    $pipelineFixture = Join-Path $testRoot 'PipelineInstall.ps1'
    $pipelineCode = @'
param($FixtureInstallerPath, $FixtureZipPath, $FixtureChecksumPath, $FixtureStub, $FixtureLog)
$ErrorActionPreference = 'Stop'
function wt.exe { throw 'This fixture must not start a terminal.' }
function Invoke-RestMethod {
    param($Uri, $Headers)
    $name = [IO.Path]::GetFileName($FixtureZipPath)
    if ($name -notmatch '^wtpocket-(v.+)-win-(?:x64|arm64)\.zip$') { throw 'Unexpected fixture ZIP name' }
    @{ tag_name = $Matches[1] }
}
function Invoke-WebRequest {
    param($Uri, $OutFile, $Headers)
    Add-Content -LiteralPath $FixtureLog -Value $Uri
    $source = if ($Uri.EndsWith('/SHA256SUMS')) { $FixtureChecksumPath } else { $FixtureZipPath }
    Copy-Item -LiteralPath $source -Destination $OutFile
}
function Expand-Archive {
    param($LiteralPath, $DestinationPath)
    [IO.Compression.ZipFile]::ExtractToDirectory($LiteralPath, $DestinationPath)
    Copy-Item -LiteralPath $FixtureStub -Destination (Join-Path $DestinationPath 'wtpocket.exe') -Force
}
$caught = $null
try { Get-Content -LiteralPath $FixtureInstallerPath -Raw | Invoke-Expression } catch { $caught = $_.Exception.Message }
if ($caught -notmatch 'WTPocket installation failed \(exit code') { throw "Pipeline installer did not reach the install step: $caught" }
'PASS: README pipeline installer execution mode.'
'@
    [IO.File]::WriteAllText($pipelineFixture, $pipelineCode)
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $pipelineDir = Join-Path $testRoot 'pipeline'
    [IO.Directory]::CreateDirectory($pipelineDir) | Out-Null
    $pipelineZip = Join-Path $pipelineDir "wtpocket-v0.1.0-win-$architecture.zip"
    Copy-Item -LiteralPath $ArchivePath -Destination $pipelineZip
    $pipelineSums = Join-Path $pipelineDir 'SHA256SUMS'
    Write-Checksum $pipelineZip $pipelineSums
    $pipelineLog = Join-Path $pipelineDir 'downloads.log'
    $pipelineOutput = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File $pipelineFixture `
        -FixtureInstallerPath (Join-Path $root 'install.ps1') -FixtureZipPath $pipelineZip -FixtureChecksumPath $pipelineSums `
        -FixtureStub (Join-Path $env:SystemRoot 'System32/whoami.exe') -FixtureLog $pipelineLog 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and $pipelineOutput -match 'PASS: README pipeline') "README pipeline-to-iex mode downloads, verifies and extracts with mocked downloads ($pipelineOutput)"
    $downloads = @(Get-Content -LiteralPath $pipelineLog)
    Assert-True ($downloads.Count -eq 2 -and $downloads[0] -like "https://github.com/huanfeng/wt-pocket/releases/download/v0.1.0/wtpocket-v0.1.0-win-$architecture.zip" -and $downloads[1] -like '*/v0.1.0/SHA256SUMS') 'Pipeline mode resolves the latest tag and downloads the archive and SHA256SUMS from the GitHub release'
    $realProfileAfter = if ([IO.File]::Exists($realProfile)) { (Get-FileHash -LiteralPath $realProfile).Hash } else { '' }
    Assert-True ($realProfileBefore -ceq $realProfileAfter) 'The pipeline test never touched the real PowerShell profile'

    Write-Output "PASS: $checks release installation checks (isolated profile and Terminal settings, no network required)."
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:WT_SESSION = $originalSession
    $env:WT_PROFILE_ID = $originalProfileId
    $env:WTTOOLS_PANEL = $originalPanel
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside temp directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
