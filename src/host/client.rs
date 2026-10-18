//! Command-line side of the pipe protocol: toggle a panel or stop the host.
use crate::{install::hex, ipc::current_user_sid, win};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::{self, BufRead, BufReader, Write},
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::{HANDLE_FLAG_INHERIT, SetHandleInformation},
    System::{
        Console::{GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE},
        Threading::{CREATE_NO_WINDOW, DETACHED_PROCESS},
    },
    UI::WindowsAndMessaging::AllowSetForegroundWindow,
};

#[derive(Deserialize)]
struct HostInfo {
    pid: u32,
    #[serde(default)]
    backend: String,
}

/// Same derivation the PowerShell module used, so a running v0.2 host is reused.
pub fn pipe_name(state: &Path) -> io::Result<String> {
    let full = std::path::absolute(state)?;
    let key = format!(
        "{}|{}",
        current_user_sid()?,
        full.to_string_lossy().to_uppercase()
    );
    Ok(format!(
        "wttools-{}",
        hex(&Sha256::digest(key))[..24].to_uppercase()
    ))
}

fn host_info(state: &Path) -> Option<HostInfo> {
    serde_json::from_slice(&fs::read(state.join("host.json")).ok()?).ok()
}

fn connect(name: &str, timeout: Duration) -> io::Result<fs::File> {
    let path = format!(r"\\.\pipe\{name}");
    let deadline = Instant::now() + timeout;
    loop {
        match OpenOptions::new().read(true).write(true).open(&path) {
            Ok(file) => return Ok(file),
            Err(e) if Instant::now() >= deadline => return Err(e),
            // Not created yet (2) or between instances / busy (231).
            Err(_) => thread::sleep(Duration::from_millis(25)),
        }
    }
}

fn exchange(mut pipe: fs::File, request: serde_json::Value) -> Result<(), String> {
    writeln!(pipe, "{request}").map_err(|e| format!("wtpocket host disconnected: {e}"))?;
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut line = String::new();
        let _ = sender.send(BufReader::new(pipe).read_line(&mut line).map(|_| line));
    });
    let line = receiver
        .recv_timeout(Duration::from_secs(15))
        .map_err(|_| "wtpocket host response timed out. Check host.log in the state directory.")?
        .map_err(|e| e.to_string())?;
    if line.trim().is_empty() {
        return Err("wtpocket host disconnected.".into());
    }
    let response: serde_json::Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
    if response["ok"].as_bool() == Some(true) {
        Ok(())
    } else {
        Err(response["error"]
            .as_str()
            .unwrap_or("Unknown host error.")
            .into())
    }
}

fn start_host(name: &str, state: &Path, pwsh: &Path) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    // Handle inheritance is all-or-nothing on CreateProcess. If the host kept
    // our stdout/stderr (a pipe when PowerShell captures the output), the
    // caller would wait for the long-lived host to close it, and hang.
    for kind in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
        unsafe {
            SetHandleInformation(GetStdHandle(kind), HANDLE_FLAG_INHERIT, 0);
        }
    }
    Command::new(exe)
        .arg("serve")
        .arg(name)
        .arg(state)
        .arg(pwsh)
        .creation_flags(CREATE_NO_WINDOW | DETACHED_PROCESS)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(drop)
        .map_err(|e| format!("Cannot start the wtpocket host: {e}"))
}

pub fn find_pwsh() -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join("pwsh.exe"))
        .find(|candidate| candidate.is_file())
}

pub struct OpenArgs {
    pub state: PathBuf,
    pub directory: PathBuf,
    pub session: String,
    pub pwsh: Option<PathBuf>,
    /// The terminal window that had focus when the command was issued.
    pub source_window: isize,
}

pub fn open(args: &OpenArgs) -> Result<(), String> {
    if std::env::var_os("WT_SESSION").is_none() {
        return Err("wtpocket open must run inside Windows Terminal.".into());
    }
    if !args.directory.is_dir() {
        return Err("wtpocket requires an existing directory.".into());
    }
    let name = pipe_name(&args.state).map_err(|e| e.to_string())?;
    // A host from the pre-Rust releases must hand over before we reuse the pipe.
    if let Some(previous) = host_info(&args.state)
        && previous.backend != "rust"
    {
        let _ = stop(&args.state);
    }
    let pipe = match connect(&name, Duration::from_millis(150)) {
        Ok(pipe) => pipe,
        Err(_) => {
            let pwsh = args
                .pwsh
                .clone()
                .or_else(find_pwsh)
                .ok_or("Cannot find pwsh.exe; pass --pwsh.")?;
            start_host(&name, &args.state, &pwsh)?;
            connect(&name, Duration::from_secs(12))
                .map_err(|e| format!("The wtpocket host did not start: {e}"))?
        }
    };
    if let Some(info) = host_info(&args.state) {
        // The host brings the panel to the front, which Windows only allows on request.
        unsafe {
            AllowSetForegroundWindow(info.pid);
        }
    }
    exchange(
        pipe,
        json!({
            "action": "toggle",
            "directory": args.directory.to_string_lossy(),
            "sourceWindow": args.source_window,
            "sessionId": args.session,
        }),
    )
}

/// Releases hidden panels that lost their host (it was killed or crashed) and
/// returns how many there were. Does nothing while any other WTPocket process
/// exists, since a live host may be keeping those panels hidden on purpose.
pub fn rescue_stranded() -> usize {
    if win::other_wtpocket_running() {
        return 0;
    }
    let stranded = win::stranded_panels();
    for &window in &stranded {
        win::reveal(window);
        win::restore_title_bar(window);
    }
    stranded.len()
}

/// Asks the running host to shut down; absence of a host is not an error.
pub fn stop(state: &Path) -> Result<bool, String> {
    let name = pipe_name(state).map_err(|e| e.to_string())?;
    let Ok(pipe) = connect(&name, Duration::from_millis(150)) else {
        return Ok(false);
    };
    let previous = host_info(state);
    exchange(pipe, json!({ "action": "shutdown" }))?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while state.join("host.json").exists() && Instant::now() < deadline {
        let current = host_info(state);
        if current.is_none() || current.map(|c| c.pid) != previous.as_ref().map(|p| p.pid) {
            break;
        }
        thread::sleep(Duration::from_millis(30));
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pipe_name_is_stable_per_state_directory_and_case_insensitive() {
        let a = pipe_name(Path::new(r"C:\Users\x\wttools")).unwrap();
        assert_eq!(a, pipe_name(Path::new(r"c:\users\X\WTTOOLS")).unwrap());
        assert_ne!(a, pipe_name(Path::new(r"C:\Users\y\wttools")).unwrap());
        assert!(a.starts_with("wttools-") && a.len() == "wttools-".len() + 24);
    }
}
