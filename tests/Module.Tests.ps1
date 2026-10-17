#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wttools-module-' + [guid]::NewGuid().ToString('N'))
$originalLocation = Get-Location
$originalSession = $env:WT_SESSION
$originalProfileId = $env:WT_PROFILE_ID
$originalPanel = $env:WTTOOLS_PANEL
$originalHook = $ExecutionContext.InvokeCommand.LocationChangedAction
$script:checks = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
try {
    $env:WT_SESSION = 'test'
    $env:WT_PROFILE_ID = [guid]::NewGuid().ToString()
    $env:WTTOOLS_PANEL = $null
    $special = Join-Path $testRoot "中文 a'b; [x] ``literal"
    [IO.Directory]::CreateDirectory($special) | Out-Null
    $state = Join-Path $testRoot 'state'
    $global:WtToolsTestHookCalls = 0
    $ExecutionContext.InvokeCommand.LocationChangedAction = { $global:WtToolsTestHookCalls++ }
    Import-Module (Join-Path $root 'powershell/WtTools.psm1')
    $sessionBeforeReload = & (Get-Module WtTools) { $script:SessionId }
    Import-Module (Join-Path $root 'powershell/WtTools.psm1') -Force
    $sessionAfterReload = & (Get-Module WtTools) { $script:SessionId }
    Assert-True ($sessionBeforeReload -ceq $sessionAfterReload) 'Session identity survives module reload in the same shell'
    $promptBefore = (Get-Command prompt).ScriptBlock.ToString()
    Enable-WtTools -RememberDirectory -StateRoot $state
    Enable-WtTools -RememberDirectory -StateRoot $state
    Assert-True (-not ('WtTools.ShellNative' -as [type])) 'Profile initialization defers native compilation until panel use'
    Set-Location -LiteralPath $special
    $cache = @(Get-ChildItem -LiteralPath $state -Filter 'last-directory-*')[0].FullName
    Assert-True ([IO.File]::ReadAllText($cache) -ceq $special) 'Directory changes are stored literally'
    Assert-True ($global:WtToolsTestHookCalls -eq 1) 'Existing location callback runs once despite repeated Enable'
    Assert-True ((Get-Command prompt).ScriptBlock.ToString() -ceq $promptBefore) 'User prompt remains untouched'
    Remove-Module WtTools
    Set-Location -LiteralPath $HOME
    Assert-True ($global:WtToolsTestHookCalls -eq 2) 'Removing module restores previous callback'
    Import-Module (Join-Path $root 'powershell/WtTools.psm1')
    Enable-WtTools -RememberDirectory -RestoreDirectory -StateRoot $state
    Assert-True ((Get-Location).ProviderPath -ceq $special) 'Home startup restores the saved directory'
    Remove-Module WtTools
    Set-Location -LiteralPath $testRoot
    Import-Module (Join-Path $root 'powershell/WtTools.psm1')
    Enable-WtTools -RestoreDirectory -StateRoot $state
    Assert-True ((Get-Location).ProviderPath -ceq $testRoot) 'An explicit non-home startup directory wins'
    Remove-Module WtTools
    Set-Location -LiteralPath $HOME
    Import-Module (Join-Path $root 'powershell/WtTools.psm1')
    Enable-WtTools -Panel -RememberDirectory -RestoreDirectory -StateRoot $state
    Set-Location -LiteralPath $testRoot
    Assert-True ([IO.File]::ReadAllText($cache) -ceq $special) 'Panel neither restores nor overwrites directory history'
    Set-Location HKCU:\
    $rejected = $false
    try { Open-WtPanel } catch { $rejected = $_ -match 'filesystem' }
    Assert-True $rejected 'Non-filesystem providers are rejected before starting the host'
    Remove-Module WtTools
    Set-Location -LiteralPath $originalLocation.ProviderPath
    $env:WT_SESSION = $null
    $fixtureProfile = Join-Path $testRoot 'profile.ps1'
    $destination = Join-Path $testRoot "install a'b"
    $originalText = '# existing $literal profile content' + "`r`n"
    [IO.File]::WriteAllText($fixtureProfile, $originalText)
    & (Join-Path $root 'scripts/Install-WtTools.ps1') -Destination $destination -ProfilePath $fixtureProfile -StateRoot $state | Out-Null
    $firstInstall = [IO.File]::ReadAllText($fixtureProfile)
    & (Join-Path $root 'scripts/Install-WtTools.ps1') -Destination $destination -ProfilePath $fixtureProfile -StateRoot $state | Out-Null
    Assert-True ([IO.File]::ReadAllText($fixtureProfile) -ceq $firstInstall) 'Installation is idempotent'
    Assert-True ($firstInstall.StartsWith($originalText)) 'Installation preserves existing profile content'
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($fixtureProfile, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) 'Installed profile handles apostrophes in paths'
    $installedRoot = (Get-Content -LiteralPath (Join-Path $destination 'current.json') -Raw | ConvertFrom-Json).path
    $installedModule = Join-Path $installedRoot 'powershell/WtTools.psm1'
    $temporarilyMissing = $installedModule + '.missing'
    Move-Item -LiteralPath $installedModule -Destination $temporarilyMissing
    $env:WT_SESSION = 'missing-module-test'
    try {
        $errorCount = $Error.Count
        $warnings = @(& $fixtureProfile 3>&1)
        Assert-True ($Error.Count -eq $errorCount) 'Missing module does not cause startup or missing-command errors'
        Assert-True ([bool]($warnings | Where-Object { $_ -is [Management.Automation.WarningRecord] -and $_.Message -match 'module is missing' })) 'Missing module gives an actionable warning'
    } finally {
        $env:WT_SESSION = $null
        Move-Item -LiteralPath $temporarilyMissing -Destination $installedModule
    }
    & (Join-Path $root 'scripts/Uninstall-WtTools.ps1') -Destination $destination -ProfilePath $fixtureProfile -StateRoot $state | Out-Null
    Assert-True ([IO.File]::ReadAllText($fixtureProfile) -ceq $originalText) 'Uninstall restores profile content exactly'
    Write-Output "PASS: $script:checks module and installation checks."
} finally {
    Remove-Module WtTools -ErrorAction SilentlyContinue
    $ExecutionContext.InvokeCommand.LocationChangedAction = $originalHook
    Set-Location -LiteralPath $originalLocation.ProviderPath
    $env:WT_SESSION = $originalSession
    $env:WT_PROFILE_ID = $originalProfileId
    $env:WTTOOLS_PANEL = $originalPanel
    Remove-Variable WtToolsTestHookCalls -Scope Global -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
