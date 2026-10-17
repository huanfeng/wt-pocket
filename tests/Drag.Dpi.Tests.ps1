#Requires -Version 7.4
# Disposable native windows on each local monitor; no input is injected.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& cargo test --manifest-path (Join-Path $root 'Cargo.toml') --locked dpi_drag_ -- --ignored --nocapture --test-threads=1
if ($LASTEXITCODE -ne 0) { throw 'Rust monitor DPI regression failed.' }
