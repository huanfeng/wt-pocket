#Requires -Version 7.4
# Invoke the real Rust hook tests; no keyboard or mouse input is injected.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& cargo test --manifest-path (Join-Path $root 'Cargo.toml') --locked drag_moves_pass_through
if ($LASTEXITCODE -ne 0) { throw 'Rust drag hook regression failed.' }
