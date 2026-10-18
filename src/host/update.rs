//! `wtpocket update`: fetch a GitHub release, verify its SHA-256, and run the
//! new package's own installer. Uses the curl.exe and tar.exe that ship with
//! Windows, so the 0.4 MB executable needs no HTTP or ZIP libraries.
use crate::{
    client,
    install::{self, sha256_file},
};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::Command,
};

const REPOSITORY: &str = "huanfeng/wt-pocket";

fn system_tool(name: &str) -> PathBuf {
    let root = std::env::var_os("SystemRoot").unwrap_or_else(|| r"C:\Windows".into());
    PathBuf::from(root).join("System32").join(name)
}

fn curl(args: &[&str]) -> Result<std::process::Output, String> {
    let output = Command::new(system_tool("curl.exe"))
        .args(["--fail", "--silent", "--show-error", "--location"])
        .args(["--header", "User-Agent: WTPocket-Updater"])
        .args(args)
        .output()
        .map_err(|e| t!("Cannot run curl.exe: {e}", "无法运行 curl.exe：{e}"))?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(t!(
            "Download failed: {}",
            "下载失败：{}",
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    }
}

pub fn architecture() -> Result<&'static str, String> {
    if cfg!(target_arch = "x86_64") {
        Ok("x64")
    } else if cfg!(target_arch = "aarch64") {
        Ok("arm64")
    } else {
        Err(t!(
            "Unsupported Windows architecture. WTPocket releases support x64 and ARM64.",
            "不支持的 Windows 架构。WTPocket 发行版支持 x64 和 ARM64。"
        ))
    }
}

fn latest_tag() -> Result<String, String> {
    let url = format!("https://api.github.com/repos/{REPOSITORY}/releases/latest");
    let output = curl(&["--header", "Accept: application/vnd.github+json", &url]).map_err(|e| {
        t!(
            "Could not resolve the latest WTPocket release: {e}",
            "无法获取 WTPocket 最新版本：{e}"
        )
    })?;
    let release: serde_json::Value =
        serde_json::from_slice(&output.stdout).map_err(|e| e.to_string())?;
    let tag = release["tag_name"].as_str().unwrap_or_default().to_string();
    if is_tag(&tag) {
        Ok(tag)
    } else {
        Err(t!(
            "Unexpected WTPocket release tag '{tag}'.",
            "意外的 WTPocket 版本标签 '{tag}'。"
        ))
    }
}

fn is_tag(tag: &str) -> bool {
    let Some(rest) = tag.strip_prefix('v') else {
        return false;
    };
    let (core, suffix) = match rest.split_once('-') {
        Some((core, suffix)) => (core, Some(suffix)),
        None => (rest, None),
    };
    let numbers: Vec<_> = core.split('.').collect();
    numbers.len() == 3
        && numbers
            .iter()
            .all(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        && suffix.is_none_or(|s| {
            !s.is_empty()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
        })
}

/// Exactly one checksum for `name` must be present.
pub fn expected_hash(sums: &str, name: &str) -> Result<String, String> {
    let hashes: Vec<&str> = sums
        .lines()
        .filter_map(|line| {
            let (hash, file) = line.split_once(char::is_whitespace)?;
            let file = file.trim_start().trim_start_matches('*');
            (hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()) && file == name)
                .then_some(hash)
        })
        .collect();
    match hashes.as_slice() {
        [hash] => Ok(hash.to_ascii_lowercase()),
        _ => Err(t!(
            "SHA256SUMS must contain exactly one checksum for '{name}'.",
            "SHA256SUMS 中必须恰好包含一条 '{name}' 的校验和。"
        )),
    }
}

/// Entries must stay inside the extraction directory and not be absolute.
pub fn safe_entry(name: &str) -> bool {
    let name = name.trim();
    !name.is_empty()
        && !name.starts_with(['/', '\\'])
        && !name.contains(':')
        && !name.split(['/', '\\']).any(|part| part == "..")
}

pub struct Update<'a> {
    pub version: Option<String>,
    pub force: bool,
    pub no_stop: bool,
    pub state: &'a Path,
    /// Arguments forwarded to the new package's `install`.
    pub install_args: Vec<String>,
}

pub fn run(update: &Update, current: &str, out: &mut dyn Write) -> Result<(), String> {
    let tag = match &update.version {
        Some(v) if v.starts_with('v') => v.clone(),
        Some(v) => format!("v{v}"),
        None => latest_tag()?,
    };
    if !is_tag(&tag) {
        return Err(t!(
            "Invalid WTPocket version '{tag}'. Use a version such as v0.2.1.",
            "无效的 WTPocket 版本 '{tag}'。请使用类似 v0.2.1 的版本号。"
        ));
    }
    if tag.trim_start_matches('v') == current && !update.force {
        let _ = writeln!(
            out,
            "{}",
            t!(
                "WTPocket {tag} is already installed. Use --force to reinstall.",
                "WTPocket {tag} 已安装。如需重新安装请加 --force。"
            )
        );
        return Ok(());
    }
    let archive_name = format!("wtpocket-{tag}-win-{}.zip", architecture()?);
    let base = format!("https://github.com/{REPOSITORY}/releases/download/{tag}");
    let work = std::env::temp_dir().join(format!(
        "wtpocket-update-{}",
        install::hex(&std::process::id().to_le_bytes())
    ));
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&work).map_err(|e| e.to_string())?;
    let result = (|| {
        let _ = writeln!(
            out,
            "{}",
            t!(
                "Downloading WTPocket {tag} for Windows {}...",
                "正在下载适用于 Windows {} 的 WTPocket {tag}……",
                architecture()?
            )
        );
        let archive = work.join(&archive_name);
        let sums = work.join("SHA256SUMS");
        curl(&[
            "--output",
            &archive.to_string_lossy(),
            &format!("{base}/{archive_name}"),
        ])?;
        curl(&[
            "--output",
            &sums.to_string_lossy(),
            &format!("{base}/SHA256SUMS"),
        ])?;
        let expected = expected_hash(
            &fs::read_to_string(&sums).map_err(|e| e.to_string())?,
            &archive_name,
        )?;
        let actual = sha256_file(&archive).map_err(|e| e.to_string())?;
        if actual != expected {
            return Err(t!(
                "SHA256 checksum verification failed for '{archive_name}'. No installation files were changed.",
                "'{archive_name}' 的 SHA256 校验失败，未改动任何安装文件。"
            ));
        }
        let tar = system_tool("tar.exe");
        let listing = Command::new(&tar)
            .arg("-tf")
            .arg(&archive)
            .output()
            .map_err(|e| t!("Cannot run tar.exe: {e}", "无法运行 tar.exe：{e}"))?;
        let names = String::from_utf8_lossy(&listing.stdout);
        if !listing.status.success() || names.lines().any(|n| !safe_entry(n)) {
            return Err(t!(
                "The WTPocket package contains unsafe or unreadable entries.",
                "WTPocket 安装包包含不安全或无法读取的条目。"
            ));
        }
        let package = work.join("package");
        fs::create_dir_all(&package).map_err(|e| e.to_string())?;
        let status = Command::new(&tar)
            .arg("-xf")
            .arg(&archive)
            .arg("-C")
            .arg(&package)
            .status()
            .map_err(|e| e.to_string())?;
        if !status.success() {
            return Err(t!(
                "Cannot extract the WTPocket package.",
                "无法解压 WTPocket 安装包。"
            ));
        }
        let installer = package.join("wtpocket.exe");
        if !installer.is_file() {
            return Err(t!(
                "The WTPocket package is incomplete: missing 'wtpocket.exe'.",
                "WTPocket 安装包不完整：缺少 'wtpocket.exe'。"
            ));
        }
        let _ = out.flush();
        let status = Command::new(&installer)
            .arg("install")
            .args(&update.install_args)
            .status()
            .map_err(|e| e.to_string())?;
        if status.success() {
            Ok(())
        } else {
            Err(t!(
                "The new package failed to install; the current installation is unchanged.",
                "新安装包安装失败，当前安装保持不变。"
            ))
        }
    })();
    let _ = fs::remove_dir_all(&work);
    result?;
    if !update.no_stop {
        match client::stop(update.state) {
            Ok(true) => {
                let _ = writeln!(
                    out,
                    "{}",
                    t!(
                        "Stopped the running host; panels were revealed. The new version starts with your next Alt+F.",
                        "已停止运行中的后台程序，Panel 已显示。新版本会在你下次按 Alt+F 时启动。"
                    )
                );
            }
            Ok(false) => {}
            Err(e) => {
                let _ = writeln!(
                    out,
                    "{}",
                    t!(
                        "Could not stop the running host: {e}",
                        "无法停止运行中的后台程序：{e}"
                    )
                );
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_follow_semver() {
        assert!(is_tag("v0.2.1") && is_tag("v1.0.0-rc.1"));
        assert!(!is_tag("0.2.1") && !is_tag("v1.2") && !is_tag("v1.a.0") && !is_tag("v1.0.0-"));
    }

    #[test]
    fn checksum_must_match_exactly_once() {
        let h = "a".repeat(64);
        let sums = format!(
            "{h}  wtpocket-v1-win-x64.zip\n{}  other.zip\n",
            "b".repeat(64)
        );
        assert_eq!(expected_hash(&sums, "wtpocket-v1-win-x64.zip").unwrap(), h);
        assert!(expected_hash(&sums, "missing.zip").is_err());
        assert!(
            expected_hash(
                &format!("{sums}{h}  wtpocket-v1-win-x64.zip\n"),
                "wtpocket-v1-win-x64.zip"
            )
            .is_err()
        );
    }

    #[test]
    fn archive_entries_cannot_escape() {
        assert!(safe_entry("wtpocket.exe") && safe_entry("sub/dir/file.txt"));
        for bad in [
            "../x",
            "a/../../x",
            "/abs",
            "\\abs",
            "C:\\x",
            "a\\..\\x",
            "",
        ] {
            assert!(!safe_entry(bad), "{bad}");
        }
    }
}
