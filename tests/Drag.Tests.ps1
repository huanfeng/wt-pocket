#Requires -Version 7.4
# Exercise the actual hook callback without injecting input or moving user windows.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $root 'src/PanelHost.cs')
$flags = [Reflection.BindingFlags]'NonPublic,Static'
$hostType = [WtTools.PanelHost]
$panelType = $hostType.GetNestedType('Panel', [Reflection.BindingFlags]::NonPublic)
$dragField = $hostType.GetField('dragPanel', $flags)
$callback = $hostType.GetMethod('Mouse', $flags)
$panel = [Activator]::CreateInstance($panelType, $true)
# A null HWND makes SetWindowPos a harmless failed call. Hook propagation and
# drag lifetime must still work; no global hook is installed in this process.
$buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
$checks = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
try {
    for ($offset = 0; $offset -lt 32; $offset += 4) {
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer, $offset, 0)
    }
    $dragField.SetValue($null, $panel)
    foreach ($point in @(@(200, 300), @(400, 500), @(-100, 500))) {
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer, 0, $point[0])
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer, 4, $point[1])
        $result = $callback.Invoke($null, @([int]0, [IntPtr]::new(0x0200), $buffer))
        Assert-True ($result -eq [IntPtr]::Zero) 'Drag movement passes through so Windows can move the cursor'
        Assert-True ($dragField.GetValue($null) -eq $panel) 'Movement keeps the drag active'
    }
    $result = $callback.Invoke($null, @([int]0, [IntPtr]::new(0x0202), $buffer))
    Assert-True ($result -eq [IntPtr]::new(1)) 'Drag release is consumed to avoid an unmatched click in WT'
    Assert-True ($null -eq $dragField.GetValue($null)) 'Left button release ends the drag'
    $result = $callback.Invoke($null, @([int]0, [IntPtr]::new(0x0200), $buffer))
    Assert-True ($result -eq [IntPtr]::Zero) 'Ordinary mouse movement passes through'
    $result = $callback.Invoke($null, @([int]-1, [IntPtr]::new(0x0200), [IntPtr]::Zero))
    Assert-True ($result -eq [IntPtr]::Zero) 'Negative hook codes pass through without reading event data'
    Write-Output "PASS: $checks drag hook checks (no input injected)."
} finally {
    $dragField.SetValue($null, $null)
    [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
}
