# Changelog

## v0.5.0

- New `wtpocket run <program> [args...]`: runs a program such as claude, vim or ssh in a private pseudo console so Alt+F still toggles the tab's panel while it runs (the same panel the prompt's Alt+F opens, starting in the current directory). Everything else is relayed unchanged and the exit code is passed through. It is only used when you type it; nothing is wrapped automatically.
- New `wtp` command, a short form of `wtpocket` (`wtp r`, `wtp run claude`).

## v0.4.0

- New `wtpocket restore` (short form `r`): lists recently closed tabs by directory and reopens the ones you pick in the current Windows Terminal window. Navigate with the arrow keys, select with Space, confirm with Enter, cancel with Esc. Only directories are recorded, one small file per terminal session under `sessions\`; no commands.

## v0.3.2

- Command-line output is now Chinese or English according to the Windows display language (override with `WTPOCKET_LANG=zh|en`), and `help` and `install` print a short hotkey reference.

## v0.3.1

- Fix the managed Windows Terminal `settings.json` block: it no longer writes a trailing comma before `]` when `actions` or `keybindings` is empty, which made Terminal refuse to reload its settings. Affected files can be repaired by re-running `wtpocket install`.

## v0.3.0

- Merge all management into one native `wtpocket` command: `open`, `stop`, `update`, `install`, `uninstall`, `version`. `wtpocket update` fetches, verifies and installs the latest release and hands the background host over.
- **Breaking:** `Open-WtPanel`, `Enable-WtTools` and `Stop-WtTools` are removed. Use `wtpocket open` / `wtpocket stop`. Re-run the install command to migrate; old versions stay on disk for running shells.
- Remove the PowerShell module, the .NET helper DLL and the PowerShell installer scripts. The package is now `wtpocket.exe` plus one small `Startup.ps1`, and building no longer needs the .NET SDK.
- When a panel's terminal window closes (or the host stops), the panel becomes a normal window again with its title bar and tab row restored. The installer adds a marked `ctrl+shift+alt+f24` -> `setFocusMode: false` binding to Windows Terminal's `settings.json` (backed up, removed by `uninstall`, skipped with `--no-terminal-settings`).
- `wtpocket stop` releases hidden panels left behind by a killed or crashed host.
- Escape all curly single quotes in the paths written to the PowerShell profile block.
- Rotate `host.log` at 1 MiB; reuse an already repaired payload directory instead of creating a new one on every reinstall.
- Fix `wtpocket open` hanging callers that capture its output: the background host no longer inherits the caller's pipes.

## v0.2.1

- Fix a command-injection path in the panel startup script: a directory name containing curly single quotes (U+2018/2019/201A/201B) could break out of the quoted literal. Paths are now passed as Base64, so no quoting rules apply.
- Rotate `host.log` at 1 MiB, keeping one previous generation.
- Require a successful CI run on the tagged commit before the release workflow publishes.
- Test panel creation from a directory containing curly quotes and shell metacharacters in real Windows Terminal.

## v0.2.0

- Replace the .NET panel controller with a native Rust executable; keep the lightweight PowerShell integration and existing pipe protocol.
- Remove the bundled .NET runtime and statically link the native CRT. Local x64 ZIP size is approximately 0.4 MB, down from 35 MB.
- Preserve per-session panels, literal paths, tab-independent ownership, physical per-monitor sizing, Alt+F, borderless dragging and orphan recovery.
- Keep low-level hooks responsive while Windows Terminal starts on the pipe thread.
- Restrict pipes to the current user, reject remote clients, and test malformed, oversized, disconnected and idle clients.
- Build and test releases natively on Windows x64 and ARM64; include locked Rust dependency license notices.
- Port drag and DPI regressions to the actual Rust callbacks. Real WT integration passes on both local monitors; physical input remains a manual validation step.

## v0.1.2

- Install each distinct payload in a separate content-addressed directory, avoiding locked DLL overwrites during upgrades.
- Migrate existing flat installations without closing PowerShell sessions or stopping running panels.
- Verify staged files before switching the profile; reuse identical payloads on reinstall and retain old versions for live sessions.
- Add regression coverage for locked legacy DLLs with different contents and upgrades between versioned payloads.

## v0.1.1

- Fix version validation when running the one-line `irm | iex` installer.
- Test the documented pipeline installation mode in an isolated host profile.

## v0.1.0

- Toggle a separate Windows Terminal panel with Alt+F, starting in the calling PowerShell session's directory.
- Keep one panel per source PowerShell session, including separate tabs and split panes.
- Keep running commands alive while a panel is hidden.
- Move panels without a title bar using Alt+left drag, with per-monitor DPI handling.
- Retain panel association when its active tab or title changes.
- Remember the last directory per Windows Terminal profile and restore it on home-directory startup.
- Load the full PowerShell module and native helper only when first opening a panel.
- Install and uninstall through managed, backed-up PowerShell profile blocks.
- Provide self-contained Windows x64 and ARM64 release packages with SHA-256 checksums.
