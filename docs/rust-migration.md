# Rust host migration

Replace the C# background process with a native Rust executable. Keep the
PowerShell startup shim, directory tracking, session IDs, native foreground
helper, newline JSON pipe protocol and immutable installer layout compatible.
The helper targets PowerShell's existing .NET runtime; no .NET runtime is shipped.

Preserve one panel per shell, exact literal directory inheritance, source-monitor
creation and physical sizing, HWND property ownership across tab changes,
Alt+F while busy, Alt+left drag, and revealing panels on orphaning or shutdown.
Keep the hook/message thread responsive while WT starts on the IPC thread.
Pipe access stays restricted to the current user, with bounded messages and timeouts.

Verification gates:

- Rust unit tests for geometry, literal bootstrap, request parsing, hook
  propagation, and disposable windows under different caller DPI contexts.
- PowerShell startup/module tests and real native host IPC smoke tests, including
  malformed clients, timeout/disconnect recovery and clean shutdown.
- Real release ZIP install/uninstall and locked-DLL upgrade regressions.
- Actual WT integration on both available monitors: initial DPI sizing, title
  changes, separate sessions, retained shell processes, and orphan recovery.
- Cargo format/clippy, x64 and ARM64 builds, GitHub CI and release workflows.

Measure executable and ZIP sizes after building; retain existing session files
while installing the new payload. Do not claim synthetic hook tests reproduce
physical mouse input.
