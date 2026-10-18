#Requires -Version 7.4
# Exercises `wtpocket.exe install` / `uninstall` against isolated temp profiles,
# state/destination directories and Windows Terminal settings fixtures. Nothing
# here touches the real profile, state or Windows Terminal settings.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wtpocket-cli-' + [guid]::NewGuid().ToString('N'))
$originalSession = $env:WT_SESSION
$originalProfileId = $env:WT_PROFILE_ID
$originalPanel = $env:WTTOOLS_PANEL
$script:checks = 0
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Read-Bytes([string] $Path) { , [IO.File]::ReadAllBytes($Path) }
function Test-SameBytes([byte[]] $A, [byte[]] $B) {
    $lengthA = if ($null -eq $A) { 0 } else { $A.Length }
    $lengthB = if ($null -eq $B) { 0 } else { $B.Length }
    if ($lengthA -ne $lengthB) { return $false }
    for ($i = 0; $i -lt $lengthA; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    $true
}
function New-Case([string] $Name) {
    $dir = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $dir
}
function Invoke-Wtp([string] $Exe, [string[]] $Arguments) {
    $output = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}
function Invoke-Install([string] $Exe, [string] $Destination, [string] $ProfilePath, [string] $State, [string[]] $Extra = @('--no-terminal-settings')) {
    Invoke-Wtp $Exe (@('install', '--destination', $Destination, '--profile', $ProfilePath, '--state', $State) + $Extra)
}
function Invoke-Uninstall([string] $Exe, [string] $Destination, [string] $ProfilePath, [string] $State, [string[]] $Extra = @('--no-terminal-settings')) {
    Invoke-Wtp $Exe (@('uninstall', '--destination', $Destination, '--profile', $ProfilePath, '--state', $State) + $Extra)
}
# A package is a flat directory holding wtpocket.exe + Startup.ps1 + LICENSE.
# A different $Marker changes Startup.ps1 and therefore the payload identity.
function New-Package([string] $Name, [string] $Marker = '') {
    $dir = Join-Path $testRoot "pkg-$Name"
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    foreach ($file in 'wtpocket.exe', 'Startup.ps1', 'LICENSE') {
        Copy-Item -LiteralPath (Join-Path $script:hostDir $file) -Destination (Join-Path $dir $file)
    }
    if ($Marker) { [IO.File]::AppendAllText((Join-Path $dir 'Startup.ps1'), "`n# variant $Marker`n") }
    $dir
}
function Get-VersionDirs([string] $Destination) {
    $versions = Join-Path $Destination 'versions'
    if (-not [IO.Directory]::Exists($versions)) { return @() }
    @(Get-ChildItem -LiteralPath $versions -Directory)
}
function Get-Backups([string] $Directory, [string] $Filter) {
    @(Get-ChildItem -LiteralPath $Directory -Filter $Filter -File)
}
function Get-ProfileBlockCount([string] $Text) { [regex]::Matches($Text, '(?m)^# >>> wttools >>>').Count }
function ConvertFrom-Jsonc([string] $Text) {
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $true
    $options.CommentHandling = [Text.Json.JsonCommentHandling]::Skip
    $document = [Text.Json.JsonDocument]::Parse($Text.TrimStart([char] 0xFEFF), $options)
    try { $document.RootElement.GetRawText() | ConvertFrom-Json -AsHashtable -NoEnumerate } finally { $document.Dispose() }
}
function Get-ManagedEntries($Settings) {
    $actions = @($Settings['actions'] | Where-Object { $_.id -ceq 'User.WTPocket.ExitFocus' })
    $bindings = @($Settings['keybindings'] | Where-Object { $_.id -ceq 'User.WTPocket.ExitFocus' })
    [pscustomobject]@{ Actions = $actions; Bindings = $bindings }
}
# Dot-sources the profile the way a new Windows Terminal tab would and reports
# whether Startup.ps1 really loaded (the `wtpocket` function exists, no warning).
function Test-ProfileLoads([string] $ProfilePath, [string] $ExpectedState) {
    $script = Join-Path $testRoot 'load-profile.ps1'
    [IO.File]::WriteAllText($script, @'
param($ProfilePath)
$ErrorActionPreference = 'Continue'
$messages = @(. $ProfilePath 3>&1 2>&1 | ForEach-Object { "$_" })
[pscustomobject]@{
    HasFunction = [bool](Get-Command wtpocket -CommandType Function -ErrorAction SilentlyContinue)
    StateRoot   = if ($global:WtPocketState) { $global:WtPocketState.StateRoot } else { $null }
    Messages    = $messages
} | ConvertTo-Json -Compress
'@)
    $env:WT_SESSION = 'cli-test'
    $env:WT_PROFILE_ID = [guid]::NewGuid().ToString()
    $env:WTTOOLS_PANEL = $null
    try { $json = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File $script -ProfilePath $ProfilePath 2>&1 | Out-String }
    finally { $env:WT_SESSION = $originalSession; $env:WT_PROFILE_ID = $originalProfileId; $env:WTTOOLS_PANEL = $originalPanel }
    $result = $json.Trim().Split("`n")[-1] | ConvertFrom-Json
    [pscustomobject]@{ Result = $result; Raw = $json }
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $script:hostDir = Join-Path $root 'artifacts/host'
    if (-not [IO.File]::Exists((Join-Path $script:hostDir 'wtpocket.exe'))) {
        & (Join-Path $root 'scripts/Build.ps1') | Out-Null
    }
    $packageA = New-Package 'a'
    $exeA = Join-Path $packageA 'wtpocket.exe'

    # --- version / argument handling ---------------------------------------
    $version = Invoke-Wtp $exeA @('version')
    Assert-True ($version.ExitCode -eq 0 -and $version.Output -match '^wtpocket \d+\.\d+\.\d+') 'version prints the product version'
    $unknown = Invoke-Wtp $exeA @('install', '--bogus')
    Assert-True ($unknown.ExitCode -ne 0 -and $unknown.Output -match 'Unknown option') 'Unknown options are rejected'

    # --- first install ------------------------------------------------------
    $case = New-Case 'first'
    $profilePath = Join-Path $case 'profile.ps1'
    $destination = Join-Path $case 'app'
    $state = Join-Path $case 'state'
    $originalText = '# existing $literal profile content' + "`r`n"
    [IO.File]::WriteAllText($profilePath, $originalText, $utf8)
    $first = Invoke-Install $exeA $destination $profilePath $state
    Assert-True ($first.ExitCode -eq 0) "First install succeeds ($($first.Output))"
    $dirs = Get-VersionDirs $destination
    Assert-True ($dirs.Count -eq 1) 'First install creates exactly one version directory'
    Assert-True ($dirs[0].Name -match '^[0-9a-f]{64}$') 'Version directory is named by the SHA-256 payload identity'
    Assert-True (@(Get-ChildItem -LiteralPath $dirs[0].FullName -File | ForEach-Object Name | Sort-Object) -join ',' -ceq 'LICENSE,Startup.ps1,wtpocket.exe') 'Installed payload is the flat file set'
    Assert-True (-not (Get-ChildItem -LiteralPath (Join-Path $destination 'versions') -Force | Where-Object Name -like '.staging-*')) 'No staging directory is left behind'
    $firstProfile = [IO.File]::ReadAllText($profilePath)
    Assert-True ($firstProfile.StartsWith($originalText)) 'Install preserves existing profile content'
    Assert-True ((Get-ProfileBlockCount $firstProfile) -eq 1) 'Install adds one managed profile block'
    Assert-True ($firstProfile.Contains((Join-Path $dirs[0].FullName 'Startup.ps1'))) 'Profile block points at the installed Startup.ps1'
    $backups = Get-Backups $case 'profile.ps1.wttools-*.bak'
    Assert-True ($backups.Count -eq 1 -and [IO.File]::ReadAllText($backups[0].FullName) -ceq $originalText) 'Changed profile is backed up with its original content'
    foreach ($name in 'wtpocket.exe', 'Startup.ps1', 'LICENSE') {
        Assert-True ((Get-FileHash (Join-Path $packageA $name)).Hash -eq (Get-FileHash (Join-Path $dirs[0].FullName $name)).Hash) "Installed $name matches the package byte for byte"
    }
    $installedVersion = Invoke-Wtp (Join-Path $dirs[0].FullName 'wtpocket.exe') @('version')
    Assert-True ($installedVersion.ExitCode -eq 0 -and $installedVersion.Output -ceq $version.Output) 'The installed executable runs'

    # --- reinstall is idempotent -------------------------------------------
    $again = Invoke-Install $exeA $destination $profilePath $state
    Assert-True ($again.ExitCode -eq 0) 'Reinstall succeeds'
    Assert-True ([IO.File]::ReadAllText($profilePath) -ceq $firstProfile) 'Reinstall leaves the profile unchanged'
    Assert-True ((Get-Backups $case 'profile.ps1.wttools-*.bak').Count -eq 1) 'Reinstall creates no new backup'
    $dirsAgain = Get-VersionDirs $destination
    Assert-True ($dirsAgain.Count -eq 1 -and $dirsAgain[0].Name -ceq $dirs[0].Name) 'Reinstall reuses the same version directory'

    # --- uninstall ----------------------------------------------------------
    $uninstall = Invoke-Uninstall $exeA $destination $profilePath $state
    Assert-True ($uninstall.ExitCode -eq 0) 'Uninstall succeeds'
    Assert-True ([IO.File]::ReadAllText($profilePath) -ceq $originalText) 'Uninstall restores the profile content exactly'
    Assert-True ([IO.File]::Exists((Join-Path $dirs[0].FullName 'wtpocket.exe'))) 'Uninstall keeps installed files'
    $backupCount = (Get-ChildItem -LiteralPath $case -Filter '*.bak' -File).Count
    $uninstallAgain = Invoke-Uninstall $exeA $destination $profilePath $state
    Assert-True ($uninstallAgain.ExitCode -eq 0 -and (Get-ChildItem -LiteralPath $case -Filter '*.bak' -File).Count -eq $backupCount) 'A second uninstall changes nothing and makes no backup'
    Assert-True ([IO.File]::ReadAllText($profilePath) -ceq $originalText) 'A second uninstall leaves the profile untouched'

    # --- user content is preserved byte for byte ---------------------------
    $profileCases = [ordered]@{
        'crlf'          = $utf8.GetBytes("Set-Alias x y`r`n# Last line`r`n")
        'lf'            = $utf8.GetBytes("Set-Alias x y`n# Last line`n")
        'empty'         = [byte[]]@()
        'utf8-unicode'  = $utf8.GetBytes("# 中文 `$profile `u{2019}quoted`u{2019}`r`nfunction f { 1 }`r`n")
        'user-markers'  = $utf8.GetBytes("# >>> other >>>`r`nkeep`r`n# <<< other <<<`r`n")
    }
    foreach ($name in $profileCases.Keys) {
        $case = New-Case "profile-$name"
        $profilePath = Join-Path $case 'profile.ps1'
        $destination = Join-Path $case 'app'
        $state = Join-Path $case 'state'
        $bytes = [byte[]] $profileCases[$name]
        [IO.File]::WriteAllBytes($profilePath, $bytes)
        $result = Invoke-Install $exeA $destination $profilePath $state
        Assert-True ($result.ExitCode -eq 0) "Install works for a $name profile"
        $installed = Read-Bytes $profilePath
        $prefixBytes = if ($bytes.Length -eq 0) { [byte[]]@() } else { [byte[]] $installed[0..($bytes.Length - 1)] }
        Assert-True ($installed.Length -gt $bytes.Length -and (Test-SameBytes $prefixBytes $bytes)) "Install keeps a $name profile as an exact prefix"
        if ($name -eq 'lf') { Assert-True (-not [IO.File]::ReadAllText($profilePath).Contains("`r")) 'An LF profile stays LF only' }
        $result = Invoke-Uninstall $exeA $destination $profilePath $state
        Assert-True ($result.ExitCode -eq 0 -and (Test-SameBytes (Read-Bytes $profilePath) $bytes)) "Uninstall restores a $name profile byte for byte"
    }

    $case = New-Case 'profile-missing'
    $profilePath = Join-Path $case 'nested/dir/profile.ps1'
    $destination = Join-Path $case 'app'
    $state = Join-Path $case 'state'
    $result = Invoke-Install $exeA $destination $profilePath $state
    Assert-True ($result.ExitCode -eq 0 -and [IO.File]::Exists($profilePath)) 'Install creates a missing profile (and its directory)'
    Assert-True ((Get-ProfileBlockCount ([IO.File]::ReadAllText($profilePath))) -eq 1) 'A created profile holds exactly the managed block'
    Assert-True ((Get-Backups (Split-Path $profilePath -Parent) '*.bak').Count -eq 0) 'Creating a profile makes no backup'
    $result = Invoke-Uninstall $exeA $destination $profilePath $state
    Assert-True ($result.ExitCode -eq 0 -and [IO.File]::ReadAllText($profilePath).Trim() -ceq '') 'Uninstall leaves an empty profile behind a created one'

    $case = New-Case 'profile-no-newline'
    $profilePath = Join-Path $case 'profile.ps1'
    $destination = Join-Path $case 'app'
    $state = Join-Path $case 'state'
    [IO.File]::WriteAllText($profilePath, 'Set-Alias x y', $utf8)
    $result = Invoke-Install $exeA $destination $profilePath $state
    $text = [IO.File]::ReadAllText($profilePath)
    Assert-True ($result.ExitCode -eq 0 -and $text.StartsWith("Set-Alias x y`r`n# >>> wttools >>>")) 'A profile without a trailing newline gets the block on its own line'
    $result = Invoke-Uninstall $exeA $destination $profilePath $state
    Assert-True ($result.ExitCode -eq 0 -and [IO.File]::ReadAllText($profilePath).TrimEnd() -ceq 'Set-Alias x y') 'Uninstall keeps the text of a profile that had no trailing newline'

    # --- old PowerShell-installer block is replaced -------------------------
    $case = New-Case 'old-block'
    $profilePath = Join-Path $case 'profile.ps1'
    $destination = Join-Path $case 'app'
    $state = Join-Path $case 'state'
    $oldBlock = @(
        '# >>> wttools >>>', 'if ($env:WT_SESSION) {',
        "    if ([IO.File]::Exists('C:\old\powershell\WtTools.psm1') -and [IO.File]::Exists('C:\old\powershell\Startup.ps1')) {",
        '        try {', "            . 'C:\old\powershell\Startup.ps1' -StateRoot 'C:\old\state'",
        '        } catch {', '            Write-Warning "wttools failed to initialize: $_"', '        }', '    } else {',
        "        Write-Warning 'wttools module is missing. Run Install-WtTools.ps1 again to repair the installation.'",
        '    }', '}', '# <<< wttools <<<') -join "`r`n"
    $before = "# before`r`nSet-Alias x y`r`n"
    $after = "# after`r`nfunction g { 2 }`r`n"
    [IO.File]::WriteAllText($profilePath, $before + $oldBlock + "`r`n" + $after, $utf8)
    $result = Invoke-Install $exeA $destination $profilePath $state
    $text = [IO.File]::ReadAllText($profilePath)
    Assert-True ($result.ExitCode -eq 0 -and (Get-ProfileBlockCount $text) -eq 1) 'An old-format block is replaced, not duplicated'
    Assert-True (-not $text.Contains('C:\old') -and -not $text.Contains('WtTools.psm1')) 'Nothing of the old block remains'
    Assert-True ($text.StartsWith($before) -and $text.EndsWith($after)) 'Text around the old block is untouched and keeps its order'
    $result = Invoke-Uninstall $exeA $destination $profilePath $state
    Assert-True ([IO.File]::ReadAllText($profilePath) -ceq ($before + $after)) 'Uninstall removes the replaced block cleanly'

    # --- special characters in paths produce a profile that really loads ----
    $case = New-Case 'special'
    $profilePath = Join-Path $case "pro file ‘x’.ps1"
    $specialRoot = Join-Path $case "my app a'b ‘c’ ’d’; [x] `$v 中文"
    $destination = Join-Path $specialRoot 'dest'
    $state = Join-Path $specialRoot "state ‘s’ it's"
    $package = New-Package 'special'
    $result = Invoke-Install (Join-Path $package 'wtpocket.exe') $destination $profilePath $state
    Assert-True ($result.ExitCode -eq 0) "Install handles quotes and spaces in paths ($($result.Output))"
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($profilePath, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) 'The generated profile block parses'
    $load = Test-ProfileLoads $profilePath $state
    Assert-True ($load.Result.HasFunction) "Startup.ps1 loads from the special path: the wtpocket function exists ($($load.Raw))"
    Assert-True (@($load.Result.Messages).Count -eq 0) "Loading the profile emits no warning or error ($(@($load.Result.Messages) -join '; '))"
    Assert-True ($load.Result.StateRoot -ceq $state) 'The state path reaches Startup.ps1 literally'
    Assert-True ([IO.Directory]::Exists($state) -and @(Get-ChildItem -LiteralPath $state -Filter 'last-directory-*').Count -eq 1) 'The loaded shim writes directory history under the special state path'
    $result = Invoke-Uninstall (Join-Path $package 'wtpocket.exe') $destination $profilePath $state
    Assert-True ($result.ExitCode -eq 0 -and (Get-ProfileBlockCount ([IO.File]::ReadAllText($profilePath))) -eq 0) 'Uninstall works with special paths'

    # An ordinary install loads too, and a missing Startup.ps1 gives an actionable warning.
    $case = New-Case 'loads'
    $profilePath = Join-Path $case 'profile.ps1'
    $destination = Join-Path $case 'app'
    $state = Join-Path $case 'state'
    Invoke-Install $exeA $destination $profilePath $state | Out-Null
    $load = Test-ProfileLoads $profilePath $state
    Assert-True ($load.Result.HasFunction -and @($load.Result.Messages).Count -eq 0) 'A plain install loads cleanly in a Windows Terminal session'
    $startup = Join-Path (Get-VersionDirs $destination)[0].FullName 'Startup.ps1'
    $startupBytes = Read-Bytes $startup
    Rename-Item -LiteralPath $startup -NewName 'Startup.ps1.missing'
    try {
        $load = Test-ProfileLoads $profilePath $state
        Assert-True (-not $load.Result.HasFunction -and (@($load.Result.Messages) -join ' ') -match 'wtpocket is missing') 'A missing Startup.ps1 gives an actionable warning without errors'
    } finally { Rename-Item -LiteralPath ($startup + '.missing') -NewName 'Startup.ps1' }
    Assert-True (Test-SameBytes (Read-Bytes $startup) $startupBytes) 'Startup.ps1 is restored'

    # --- repair of a damaged installation ----------------------------------
    $case = New-Case 'damaged'
    $profilePath = Join-Path $case 'profile.ps1'
    $destination = Join-Path $case 'app'
    $state = Join-Path $case 'state'
    Invoke-Install $exeA $destination $profilePath $state | Out-Null
    $good = (Get-VersionDirs $destination)[0]
    $damagedFile = Join-Path $good.FullName 'Startup.ps1'
    [IO.File]::AppendAllText($damagedFile, "`n# tampered`n")
    $damagedHash = (Get-FileHash $damagedFile).Hash
    $result = Invoke-Install $exeA $destination $profilePath $state
    Assert-True ($result.ExitCode -eq 0) 'Installing over a damaged payload succeeds'
    $dirs = Get-VersionDirs $destination
    Assert-True ($dirs.Count -eq 2) 'A damaged payload is repaired into a new directory'
    $repaired = $dirs | Where-Object Name -cne $good.Name
    Assert-True ($repaired.Name.StartsWith($good.Name + '-')) 'The repair directory name extends the payload identity'
    Assert-True ((Get-FileHash $damagedFile).Hash -eq $damagedHash) 'The damaged file is never overwritten'
    Assert-True ((Get-FileHash (Join-Path $repaired.FullName 'Startup.ps1')).Hash -eq (Get-FileHash (Join-Path $packageA 'Startup.ps1')).Hash) 'The repaired directory holds the pristine files'
    Assert-True ([IO.File]::ReadAllText($profilePath).Contains($repaired.FullName)) 'The profile points at the repaired directory'
    $result = Invoke-Install $exeA $destination $profilePath $state
    # Known product limitation: the damaged identity directory is never fixed, so
    # every reinstall repairs into yet another directory (see the test report).
    Assert-True ($result.ExitCode -eq 0 -and (Get-FileHash $damagedFile).Hash -eq $damagedHash) 'A further reinstall still succeeds and never touches the damaged file'
    $activeStartup = [regex]::Match([IO.File]::ReadAllText($profilePath), "(?m)\. '([^\r\n]*?Startup\.ps1)'").Groups[1].Value.Replace("''", "'")
    Assert-True ((Get-FileHash $activeStartup).Hash -eq (Get-FileHash (Join-Path $packageA 'Startup.ps1')).Hash) 'The profile always activates an intact copy'

    # --- locked files in an older version do not block an install ----------
    $case = New-Case 'locked'
    $profilePath = Join-Path $case 'profile.ps1'
    $destination = Join-Path $case 'app'
    $state = Join-Path $case 'state'
    Invoke-Install $exeA $destination $profilePath $state | Out-Null
    $oldDir = (Get-VersionDirs $destination)[0]
    $oldExe = Join-Path $oldDir.FullName 'wtpocket.exe'
    $oldHashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $oldDir.FullName -File) { $oldHashes[$file.Name] = (Get-FileHash $file.FullName).Hash }
    $packageB = New-Package 'b' 'upgrade'
    $held = [IO.File]::Open($oldExe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { $result = Invoke-Install (Join-Path $packageB 'wtpocket.exe') $destination $profilePath $state }
    finally { $held.Dispose() }
    Assert-True ($result.ExitCode -eq 0) "Installing a different build succeeds while the old wtpocket.exe is locked ($($result.Output))"
    $dirs = Get-VersionDirs $destination
    Assert-True ($dirs.Count -eq 2) 'The different build gets its own version directory'
    $newDir = $dirs | Where-Object Name -cne $oldDir.Name
    $untouched = $true
    foreach ($name in $oldHashes.Keys) { if ((Get-FileHash (Join-Path $oldDir.FullName $name)).Hash -ne $oldHashes[$name]) { $untouched = $false } }
    Assert-True $untouched 'The old version directory is untouched'
    Assert-True ([IO.File]::ReadAllText($profilePath).Contains($newDir.FullName) -and -not [IO.File]::ReadAllText($profilePath).Contains($oldDir.FullName)) 'The profile switches to the new version'
    $load = Test-ProfileLoads $profilePath $state
    Assert-True ($load.Result.HasFunction -and @($load.Result.Messages).Count -eq 0) 'The upgraded profile loads cleanly'
    $heldRead = [IO.File]::Open($oldExe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $result = Invoke-Install $exeA $destination $profilePath $state }
    finally { $heldRead.Dispose() }
    Assert-True ($result.ExitCode -eq 0 -and (Get-VersionDirs $destination).Count -eq 2) 'Reinstalling the older build with its exe in use reuses its directory'

    # --- incomplete package -------------------------------------------------
    $case = New-Case 'incomplete'
    $profilePath = Join-Path $case 'profile.ps1'
    $destination = Join-Path $case 'app'
    $state = Join-Path $case 'state'
    [IO.File]::WriteAllText($profilePath, $originalText, $utf8)
    $incomplete = New-Package 'incomplete'
    Remove-Item -LiteralPath (Join-Path $incomplete 'Startup.ps1')
    $result = Invoke-Install (Join-Path $incomplete 'wtpocket.exe') $destination $profilePath $state
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match "missing 'Startup.ps1'") 'A package without Startup.ps1 is rejected with a clear error'
    Assert-True ([IO.File]::ReadAllText($profilePath) -ceq $originalText) 'A rejected package leaves the profile untouched'
    Assert-True (@(Get-VersionDirs $destination | Where-Object Name -notlike '.staging-*').Count -eq 0) 'A rejected package installs no version directory'

    # --- non-UTF-8 profile --------------------------------------------------
    $case = New-Case 'non-utf8'
    $profilePath = Join-Path $case 'profile.ps1'
    $destination = Join-Path $case 'app'
    $state = Join-Path $case 'state'
    $badBytes = [byte[]](0x23, 0x20, 0xFF, 0xFE, 0x80, 0x0D, 0x0A)
    [IO.File]::WriteAllBytes($profilePath, $badBytes)
    $result = Invoke-Install $exeA $destination $profilePath $state
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'not UTF-8') 'A non-UTF-8 profile makes install fail with an explanation'
    Assert-True (Test-SameBytes (Read-Bytes $profilePath) $badBytes) 'A non-UTF-8 profile is left byte for byte unchanged'
    Assert-True ((Get-Backups $case '*.bak').Count -eq 0) 'No backup is made for a profile that was not changed'
    $result = Invoke-Uninstall $exeA $destination $profilePath $state
    Assert-True ($result.ExitCode -ne 0 -and (Test-SameBytes (Read-Bytes $profilePath) $badBytes)) 'Uninstall also leaves a non-UTF-8 profile unchanged'

    # --- Windows Terminal settings -----------------------------------------
    $jsoncBoth = "// Windows Terminal settings`n{`n    // keep this comment: `"actions`": [ not real`n    `"defaultProfile`": `"{61c54bbd-c2c6-5271-96e7-009a87ff44bf}`",`n    `"actions`": [`n        { `"command`": `"paste`", `"keys`": `"ctrl+v`" },`n    ],`n    `"keybindings`": [`n        { `"id`": `"Terminal.CopyToClipboard`", `"keys`": `"ctrl+c`" }, // trailing comment`n    ],`n    /* block comment */`n    `"profiles`": { `"defaults`": {}, `"list`": [], `"actions`": [ 1 ] },`n}`n"
    $fixtures = [ordered]@{
        'both'             = $jsoncBoth
        'both-crlf'        = $jsoncBoth.Replace("`n", "`r`n")
        'only-keybindings' = "{`n    // only keybindings`n    `"keybindings`": [ { `"id`": `"X`", `"keys`": `"ctrl+x`" } ],`n    `"profiles`": { `"list`": [] }`n}`n"
        'only-actions'     = "{`n    `"actions`": [],`n    `"theme`": `"dark`"`n}`n"
        'neither'          = "{`n    // nothing here yet`n    `"theme`": `"dark`",`n    `"profiles`": { `"list`": [] }`n}`n"
        'empty-object'     = "{}"
        'bom'              = ([string][char]0xFEFF) + "{`n    `"actions`": []`n}`n"
    }
    $case = New-Case 'terminal'
    $profilePath = Join-Path $case 'profile.ps1'
    $destination = Join-Path $case 'app'
    $state = Join-Path $case 'state'
    foreach ($name in $fixtures.Keys) {
        $settings = Join-Path $case "settings-$name.json"
        $text = [string] $fixtures[$name]
        [IO.File]::WriteAllText($settings, $text, $utf8)
        $before = ConvertFrom-Jsonc $text
        $extra = @('--terminal-settings', $settings)
        $result = Invoke-Install $exeA $destination $profilePath $state $extra
        Assert-True ($result.ExitCode -eq 0) "Install with a '$name' settings fixture succeeds ($($result.Output))"
        $installedText = [IO.File]::ReadAllText($settings)
        $parsed = $null
        try { $parsed = ConvertFrom-Jsonc $installedText } catch { }
        Assert-True ($null -ne $parsed) "The '$name' settings still parse as JSONC after install ($installedText)"
        $entries = Get-ManagedEntries $parsed
        Assert-True ($entries.Actions.Count -eq 1 -and $entries.Actions[0].command.action -ceq 'setFocusMode' -and $entries.Actions[0].command.isFocusMode -eq $false) "The '$name' settings get the setFocusMode(false) action"
        Assert-True ($entries.Bindings.Count -eq 1 -and $entries.Bindings[0].keys -ceq 'ctrl+shift+alt+f24') "The '$name' settings get the ctrl+shift+alt+f24 key binding"
        foreach ($key in $before.Keys) {
            if ($key -in 'actions', 'keybindings') {
                Assert-True (@($parsed[$key]).Count -eq @($before[$key]).Count + 1) "The '$name' settings keep every existing $key entry"
            } else {
                Assert-True (($parsed[$key] | ConvertTo-Json -Compress -Depth 10) -ceq ($before[$key] | ConvertTo-Json -Compress -Depth 10)) "The '$name' settings keep '$key' as it was"
            }
        }
        Assert-True ($installedText.Contains('/* >>> wtpocket >>> */') -and $installedText.Contains('/* <<< wtpocket <<< */')) "The '$name' entries sit between the wtpocket markers"
        if ($name -ne 'both-crlf') { Assert-True (-not $installedText.Contains("`r")) "The '$name' settings gain no stray CR characters" }
        $settingsBackups = Get-Backups $case "settings-$name.json.wtpocket-*.bak"
        Assert-True ($settingsBackups.Count -eq 1 -and [IO.File]::ReadAllText($settingsBackups[0].FullName) -ceq $text) "The '$name' settings are backed up with their original text"

        $result = Invoke-Install $exeA $destination $profilePath $state $extra
        Assert-True ($result.ExitCode -eq 0 -and [IO.File]::ReadAllText($settings) -ceq $installedText) "Reinstall leaves the '$name' settings unchanged"
        Assert-True ((Get-Backups $case "settings-$name.json.wtpocket-*.bak").Count -eq 1) "Reinstall makes no new backup of the '$name' settings"

        $result = Invoke-Uninstall $exeA $destination $profilePath $state $extra
        Assert-True ($result.ExitCode -eq 0 -and [IO.File]::ReadAllText($settings) -ceq $text) "Uninstall restores the '$name' settings exactly"
        Assert-True ((Get-ProfileBlockCount ([IO.File]::ReadAllText($profilePath))) -eq 0) 'Uninstall also removes the profile block'
    }

    # --no-terminal-settings leaves fixtures alone; the flag also wins over nothing being detected.
    $settings = Join-Path $case 'settings-untouched.json'
    [IO.File]::WriteAllText($settings, $jsoncBoth, $utf8)
    $stamp = (Get-Item -LiteralPath $settings).LastWriteTimeUtc
    $result = Invoke-Install $exeA $destination $profilePath $state @('--no-terminal-settings')
    Assert-True ($result.ExitCode -eq 0 -and [IO.File]::ReadAllText($settings) -ceq $jsoncBoth -and (Get-Item -LiteralPath $settings).LastWriteTimeUtc -eq $stamp) '--no-terminal-settings leaves a settings fixture untouched'
    Assert-True ((Get-Backups $case 'settings-untouched.json*.bak').Count -eq 0) '--no-terminal-settings makes no settings backup'
    $result = Invoke-Uninstall $exeA $destination $profilePath $state @('--no-terminal-settings')
    Assert-True ($result.ExitCode -eq 0 -and [IO.File]::ReadAllText($settings) -ceq $jsoncBoth) 'Uninstall with --no-terminal-settings leaves the fixture untouched'

    # Several files in one run, plus managed entries removed from user-edited files.
    $one = Join-Path $case 'multi-1.json'; $two = Join-Path $case 'multi-2.json'
    [IO.File]::WriteAllText($one, $fixtures['both'], $utf8)
    [IO.File]::WriteAllText($two, $fixtures['neither'], $utf8)
    $extra = @('--terminal-settings', $one, '--terminal-settings', $two)
    $result = Invoke-Install $exeA $destination $profilePath $state $extra
    Assert-True ($result.ExitCode -eq 0 -and (Get-ManagedEntries (ConvertFrom-Jsonc ([IO.File]::ReadAllText($one)))).Actions.Count -eq 1 -and (Get-ManagedEntries (ConvertFrom-Jsonc ([IO.File]::ReadAllText($two)))).Bindings.Count -eq 1) 'Repeated --terminal-settings edits every given file'
    $result = Invoke-Uninstall $exeA $destination $profilePath $state $extra
    Assert-True ([IO.File]::ReadAllText($one) -ceq $fixtures['both'] -and [IO.File]::ReadAllText($two) -ceq $fixtures['neither']) 'Uninstall restores every given settings file'

    # A settings file that is not an object is skipped; the install itself still succeeds.
    $array = Join-Path $case 'settings-array.json'
    [IO.File]::WriteAllText($array, '[1, 2]', $utf8)
    $result = Invoke-Install $exeA $destination $profilePath $state @('--terminal-settings', $array)
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'Skipped' -and [IO.File]::ReadAllText($array) -ceq '[1, 2]') 'A settings file that is not an object is skipped and left unchanged'
    Assert-True ((Get-ProfileBlockCount ([IO.File]::ReadAllText($profilePath))) -eq 1) 'Skipping settings does not prevent the profile block'

    # A missing settings file is not created by install.
    $missing = Join-Path $case 'does-not-exist.json'
    $result = Invoke-Install $exeA $destination $profilePath $state @('--terminal-settings', $missing)
    Assert-True ($result.ExitCode -eq 0 -and -not [IO.File]::Exists($missing)) 'A missing settings file is skipped and not created'

    Write-Output "PASS: $script:checks CLI installation checks (isolated profile, state and Terminal settings)."
} finally {
    $env:WT_SESSION = $originalSession
    $env:WT_PROFILE_ID = $originalProfileId
    $env:WTTOOLS_PANEL = $originalPanel
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside temp directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
