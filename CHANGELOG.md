# Changelog

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
