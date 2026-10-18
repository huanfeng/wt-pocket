//! Installs the running executable and its PowerShell shim into immutable,
//! content-addressed version directories, then activates them through a managed
//! profile block. Files that another process has loaded are never overwritten.
use crate::{
    paths, profile,
    win::{Handle, wide},
    wtsettings,
};
use sha2::{Digest, Sha256};
use std::{
    fs, io,
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use windows_sys::Win32::{
    Foundation::{WAIT_ABANDONED, WAIT_OBJECT_0},
    System::Threading::*,
};

const REQUIRED: [&str; 2] = ["wtpocket.exe", "Startup.ps1"];
const OPTIONAL: [&str; 2] = ["LICENSE", "THIRD-PARTY-NOTICES.txt"];

pub enum TerminalSettings {
    /// Every Windows Terminal settings file found on this machine.
    Detect,
    Skip,
    Files(Vec<PathBuf>),
}

pub struct Options {
    pub destination: PathBuf,
    pub profile: PathBuf,
    pub state: PathBuf,
    pub terminal_settings: TerminalSettings,
}

pub fn sha256_file(path: &Path) -> io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex(&hasher.finalize()))
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `YYYYMMDDHHMMSSmmm` in UTC, used only to name backup files.
pub fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let (days, rest) = ((now.as_secs() / 86400) as i64, now.as_secs() % 86400);
    // Civil-from-days (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}{month:02}{day:02}{:02}{:02}{:02}{:03}",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60,
        now.subsec_millis()
    )
}

fn unique() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("{:x}{:x}", std::process::id(), nanos)
}

struct InstallLock(Handle);
impl InstallLock {
    fn acquire(destination: &Path) -> Result<Self, String> {
        let key = hex(&Sha256::digest(
            destination
                .to_string_lossy()
                .trim_end_matches('\\')
                .to_uppercase(),
        ));
        let name = wide(&format!("Local\\wtpocket-install-{key}"));
        let handle = Handle(unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) });
        if handle.0.is_null() {
            return Err(io::Error::last_os_error().to_string());
        }
        match unsafe { WaitForSingleObject(handle.0, 30_000) } {
            WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(Self(handle)),
            _ => Err(t!(
                "Another WTPocket installation is still running. Please retry shortly.",
                "另一个 WTPocket 安装仍在进行，请稍后重试。"
            )),
        }
    }
}
impl Drop for InstallLock {
    fn drop(&mut self) {
        unsafe {
            ReleaseMutex(self.0.0);
        }
    }
}

fn write_atomic(path: &Path, content: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temporary = PathBuf::from(format!("{}.{}.tmp", path.display(), unique()));
    let result = fs::write(&temporary, content).and_then(|()| fs::rename(&temporary, path));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn read_text(path: &Path) -> Result<String, String> {
    match fs::read(path) {
        Ok(bytes) => String::from_utf8(bytes).map_err(|_| {
            t!(
                "{} is not UTF-8 text; it was left unchanged.",
                "{} 不是 UTF-8 文本，已保持原样。",
                path.display()
            )
        }),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(t!(
            "Cannot read {}: {e}",
            "无法读取 {}：{e}",
            path.display()
        )),
    }
}

/// Writes `updated` over `path` after saving a timestamped backup; returns whether it changed.
fn update_file(
    path: &Path,
    original: &str,
    updated: &str,
    tag: &str,
    out: &mut dyn Write,
) -> Result<bool, String> {
    if original == updated {
        return Ok(false);
    }
    if path.exists() {
        let backup = PathBuf::from(format!("{}.{tag}-{}.bak", path.display(), timestamp()));
        fs::copy(path, &backup)
            .map_err(|e| t!("Cannot back up {}: {e}", "无法备份 {}：{e}", path.display()))?;
        let _ = writeln!(out, "{}", t!("Backup: {}", "备份：{}", backup.display()));
    }
    write_atomic(path, updated)
        .map_err(|e| t!("Cannot write {}: {e}", "无法写入 {}：{e}", path.display()))?;
    Ok(true)
}

fn terminal_files(setting: &TerminalSettings) -> Vec<PathBuf> {
    match setting {
        TerminalSettings::Detect => paths::terminal_settings(),
        TerminalSettings::Skip => Vec::new(),
        TerminalSettings::Files(files) => files.clone(),
    }
}

/// Copies the payload next to this executable into its version directory and
/// returns that directory.
fn stage_payload(source: &Path, versions: &Path) -> Result<PathBuf, String> {
    let mut files: Vec<(String, PathBuf, String)> = Vec::new();
    for name in REQUIRED.iter().chain(OPTIONAL.iter()) {
        let path = if *name == "wtpocket.exe" {
            std::env::current_exe().map_err(|e| e.to_string())?
        } else {
            source.join(name)
        };
        if path.is_file() {
            let hash = sha256_file(&path)
                .map_err(|e| t!("Cannot read {}: {e}", "无法读取 {}：{e}", path.display()))?;
            files.push(((*name).to_string(), path, hash));
        } else if REQUIRED.contains(name) {
            return Err(t!(
                "The WTPocket package is incomplete: missing '{name}'.",
                "WTPocket 安装包不完整：缺少 '{name}'。"
            ));
        }
    }
    files.sort();
    let manifest: Vec<String> = files.iter().map(|(n, _, h)| format!("{n} {h}")).collect();
    let identity = hex(&Sha256::digest(manifest.join("\n")));
    let intact = |dir: &Path| {
        files
            .iter()
            .all(|(name, _, hash)| sha256_file(&dir.join(name)).is_ok_and(|actual| &actual == hash))
    };
    let mut installed = versions.join(&identity);
    if installed.is_dir() {
        // An earlier repair may already have produced an intact copy.
        let repaired = fs::read_dir(versions)
            .into_iter()
            .flatten()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n == identity || n.starts_with(&format!("{identity}-")))
            })
            .find(|path| path.is_dir() && intact(path));
        if let Some(dir) = repaired {
            return Ok(dir);
        }
        // Repair without overwriting files another process may have loaded.
        installed = versions.join(format!("{identity}-{}", unique()));
    }
    let staging = versions.join(format!(".staging-{}", unique()));
    let result = (|| -> Result<(), String> {
        fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
        for (name, path, hash) in &files {
            let target = staging.join(name);
            fs::copy(path, &target)
                .map_err(|e| t!("Cannot copy {name}: {e}", "无法复制 {name}：{e}"))?;
            if &sha256_file(&target).map_err(|e| e.to_string())? != hash {
                return Err(t!(
                    "Installation verification failed: {name}",
                    "安装校验失败：{name}"
                ));
            }
        }
        fs::rename(&staging, &installed).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&staging);
    }
    result.map(|()| installed)
}

/// Key reference shared by `help` and the end of `install`.
fn hotkey_lines() -> String {
    t!(
        "  Alt+F                Show or hide this tab's panel (also hides it from inside the panel)
  Alt + left-drag      Move the panel by dragging its content area
  Ctrl+Shift+Alt+F24   Reserved: restores the title bar of released panels; do not remap",
        "  Alt+F                显示或隐藏当前标签页的 Panel（在 Panel 内按也会隐藏）
  Alt + 鼠标左键拖动   拖动 Panel 内容区以移动窗口
  Ctrl+Shift+Alt+F24   保留键：用于恢复已解除关联的 Panel 的标题栏，请勿改作他用"
    )
}

/// Shown at the end of `install`.
pub fn hotkeys() -> String {
    let head = t!(
        "Next: open a new PowerShell 7 tab in Windows Terminal, then use:",
        "下一步：在 Windows Terminal 中新开一个 PowerShell 7 标签页，然后使用："
    );
    format!("{head}\n{}", hotkey_lines())
}

/// Shown by `help`.
pub fn hotkey_help() -> String {
    let head = t!(
        "Hotkeys (in a PowerShell 7 tab of Windows Terminal, after install):",
        "快捷键（安装后，在 Windows Terminal 的 PowerShell 7 标签页中）："
    );
    format!("{head}\n{}", hotkey_lines())
}
pub fn install(options: &Options, out: &mut dyn Write) -> Result<PathBuf, String> {
    let destination = paths::absolute(&options.destination).map_err(|e| e.to_string())?;
    let profile_path = paths::absolute(&options.profile).map_err(|e| e.to_string())?;
    let state = paths::absolute(&options.state).map_err(|e| e.to_string())?;
    let source = std::env::current_exe()
        .map_err(|e| e.to_string())?
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| {
            t!(
                "Cannot locate the package directory.",
                "找不到安装包所在目录。"
            )
        })?;
    let _lock = InstallLock::acquire(&destination)?;
    let versions = destination.join("versions");
    fs::create_dir_all(&versions).map_err(|e| {
        t!(
            "Cannot create {}: {e}",
            "无法创建 {}：{e}",
            versions.display()
        )
    })?;
    let installed = stage_payload(&source, &versions)?;

    let startup = installed.join("Startup.ps1");
    let original = read_text(&profile_path)?;
    let updated = profile::upsert(
        &original,
        &startup.to_string_lossy(),
        &state.to_string_lossy(),
    );
    // The profile is the activation point; it only references verified files.
    update_file(&profile_path, &original, &updated, "wttools", out)?;

    for file in terminal_files(&options.terminal_settings) {
        let text = read_text(&file)?;
        match wtsettings::add(&text) {
            Ok(changed) => {
                if update_file(&file, &text, &changed, "wtpocket", out)? {
                    let _ = writeln!(
                        out,
                        "{}",
                        t!(
                            "Added the focus-mode exit key to {}",
                            "已在 {} 中添加退出焦点模式的按键绑定",
                            file.display()
                        )
                    );
                }
            }
            Err(e) => {
                let _ = writeln!(
                    out,
                    "{}",
                    t!("Skipped {}: {e}", "已跳过 {}：{e}", file.display())
                );
            }
        }
    }
    let _ = writeln!(
        out,
        "{}",
        t!(
            "Installed WTPocket to {}",
            "WTPocket 已安装到 {}",
            installed.display()
        )
    );
    let _ = writeln!(
        out,
        "{}",
        t!(
            "Existing shells and panels keep using their current version; no loaded files are overwritten.",
            "已打开的 Shell 和 Panel 继续使用当前版本，不会覆盖任何已加载的文件。"
        )
    );
    let _ = writeln!(out, "{}", hotkeys());
    Ok(installed)
}

pub fn uninstall(options: &Options, out: &mut dyn Write) -> Result<(), String> {
    let profile_path = paths::absolute(&options.profile).map_err(|e| e.to_string())?;
    let original = read_text(&profile_path)?;
    let updated = profile::remove(&original);
    update_file(&profile_path, &original, &updated, "wttools-uninstall", out)?;
    for file in terminal_files(&options.terminal_settings) {
        let text = read_text(&file)?;
        let cleaned = wtsettings::remove(&text);
        update_file(&file, &text, &cleaned, "wtpocket", out)?;
    }
    let _ = writeln!(
        out,
        "{}",
        t!(
            "WTPocket disabled for new shells. Running panels are revealed, not terminated. Installed files and directory history are retained.",
            "已为新的 Shell 停用 WTPocket。运行中的 Panel 会被显示出来而不是被终止；安装文件和目录历史会保留。"
        )
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamp_has_the_expected_shape() {
        let stamp = timestamp();
        assert_eq!(stamp.len(), 17);
        assert!(stamp.starts_with("20") && stamp.bytes().all(|b| b.is_ascii_digit()));
    }

    #[test]
    fn hex_and_hash_match_known_vectors() {
        assert_eq!(hex(&[0, 15, 255]), "000fff");
        assert_eq!(
            hex(&Sha256::digest("abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
