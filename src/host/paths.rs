//! Default per-user locations, matching `$PROFILE.CurrentUserAllHosts` for pwsh 7.
use crate::win::wide;
use std::{
    io,
    path::{Path, PathBuf},
    ptr, slice,
};
use windows_sys::Win32::{System::Com::CoTaskMemFree, UI::Shell::*};

fn documents() -> io::Result<PathBuf> {
    let mut raw = ptr::null_mut();
    let result = unsafe { SHGetKnownFolderPath(&FOLDERID_Documents, 0, ptr::null_mut(), &mut raw) };
    if result < 0 || raw.is_null() {
        return Err(io::Error::other("Cannot locate the Documents folder."));
    }
    let path = unsafe {
        let mut length = 0;
        while *raw.add(length) != 0 {
            length += 1;
        }
        let text = String::from_utf16_lossy(slice::from_raw_parts(raw, length));
        CoTaskMemFree(raw.cast());
        text
    };
    Ok(PathBuf::from(path))
}

pub struct Layout {
    pub destination: PathBuf,
    pub profile: PathBuf,
    pub state: PathBuf,
}

impl Layout {
    pub fn default_user() -> io::Result<Self> {
        let directory = documents()?.join("PowerShell");
        Ok(Self {
            destination: directory.join("wttools").join("app"),
            profile: directory.join("Microsoft.PowerShell_profile.ps1"),
            state: directory.join("wttools"),
        })
    }
}

/// Windows Terminal settings files that exist on this machine.
pub fn terminal_settings() -> Vec<PathBuf> {
    let Some(local) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) else {
        return Vec::new();
    };
    [
        local.join(r"Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"),
        local.join(
            r"Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        ),
        local.join(r"Microsoft\Windows Terminal\settings.json"),
    ]
    .into_iter()
    .filter(|p| p.is_file())
    .collect()
}

pub fn absolute(path: &Path) -> io::Result<PathBuf> {
    std::path::absolute(path)
}

#[allow(dead_code)]
pub fn to_wide(path: &Path) -> Vec<u16> {
    wide(&path.to_string_lossy())
}
