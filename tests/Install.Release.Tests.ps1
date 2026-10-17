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
                'src/PanelHost.cs', 'artifacts/host/wttools-host.exe', 'artifacts/host/WtTools.ShellNative.dll')) {
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

    & (Join-Path $root 'install.ps1') @arguments -ChecksumPath $ChecksumPath | Out-Null
    $firstProfile = [IO.File]::ReadAllText($testProfilePath)
    Assert-True ($firstProfile.StartsWith($originalProfile)) 'Release installation preserves the existing profile'
    Assert-True ([regex]::Matches($firstProfile, '(?m)^# >>> wttools >>>').Count -eq 1) 'Release installation adds one managed profile block'
    Assert-True ([IO.File]::Exists((Join-Path $destination 'powershell/Startup.ps1'))) 'Release installs the lazy startup script'
    Assert-True ([IO.File]::Exists((Join-Path $destination 'host/wttools-host.exe'))) 'Release installs the compiled host'
    Assert-True ([IO.File]::Exists((Join-Path $destination 'LICENSE'))) 'Installed application retains its MIT license'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $testProfilePath -Parent) -Filter '*.bak').Count -gt 0) 'Existing profile is backed up'

    if ([IO.File]::Exists((Join-Path $destination 'host/coreclr.dll'))) {
        # Real release packages must run from the installed directory with
        # their own runtime. This never creates a Terminal or panel window.
        $pipeName = 'wtpocket-release-test-' + [guid]::NewGuid().ToString('N')
        $healthState = Join-Path $testRoot 'host-health'
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $destination 'host/wttools-host.exe'))
        $start.UseShellExecute = $false
        foreach ($argument in @($pipeName, $healthState, (Join-Path $destination 'powershell/WtTools.psm1'),
                (Join-Path $PSHOME 'pwsh.exe'))) { $start.ArgumentList.Add($argument) }
        $runningHost = [Diagnostics.Process]::Start($start)
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
        try {
            $pipe.Connect(10000)
            Assert-True (-not $runningHost.HasExited) 'Installed self-contained release host starts'
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
    $helper = Join-Path $destination 'host/WtTools.ShellNative.dll'
    $held = [IO.File]::Open($helper, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { & (Join-Path $root 'install.ps1') @arguments -ChecksumPath $ChecksumPath | Out-Null }
    finally { $held.Dispose() }
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $firstProfile) 'Release reinstall is idempotent even with the helper in use'

    $uninstaller = Join-Path $root 'scripts/Uninstall-WtTools.ps1'
    & $uninstaller -Destination $destination -ProfilePath $testProfilePath -StateRoot $state | Out-Null
    Assert-True ([IO.File]::ReadAllText($testProfilePath) -ceq $originalProfile) 'Release uninstall restores the existing profile exactly'
    Assert-True ([IO.File]::Exists($helper)) 'Uninstall retains installed files'

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
