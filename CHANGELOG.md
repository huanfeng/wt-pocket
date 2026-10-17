# Changelog

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
