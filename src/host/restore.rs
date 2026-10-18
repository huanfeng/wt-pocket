//! `wtpocket restore`: lists the directories of recently closed Windows
//! Terminal tabs (recorded by the PowerShell shim, one small file per terminal
//! session) and reopens the chosen ones as new tabs.
use crate::win;
use serde::Deserialize;
use std::{
    collections::HashSet,
    fs, io,
    io::Write,
    path::{Path, PathBuf},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};
use windows_sys::Win32::{
    System::Console::*,
    UI::Input::KeyboardAndMouse::{
        VK_DOWN, VK_END, VK_ESCAPE, VK_HOME, VK_NEXT, VK_PRIOR, VK_RETURN, VK_SPACE, VK_UP,
    },
};

const MAX_AGE_SECS: u64 = 30 * 24 * 3600;
const MAX_ENTRIES: usize = 30;
const VISIBLE_ROWS: usize = 10;
/// FILETIME ticks (100 ns) of slack when matching a process start time.
const START_SLACK: u64 = 20_000_000;

#[derive(Deserialize, Clone, Debug, PartialEq)]
pub struct Session {
    pub path: String,
    #[serde(default)]
    pub profile: String,
    #[serde(default)]
    pub pid: u32,
    #[serde(default)]
    pub started: u64,
    #[serde(default)]
    pub updated: u64,
}

pub struct Args {
    pub state: PathBuf,
    pub list: bool,
    /// 1-based indexes chosen without the interactive picker.
    pub select: Option<String>,
    pub wt_exe: Option<PathBuf>,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Reads every recorded session and deletes the ones nobody will want again.
fn load(state: &Path) -> Vec<Session> {
    let directory = state.join("sessions");
    let mut sessions = Vec::new();
    for entry in fs::read_dir(&directory).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.extension().is_none_or(|e| e != "json") {
            continue;
        }
        let Some(session) = fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Session>(&bytes).ok())
        else {
            continue;
        };
        if now().saturating_sub(session.updated) > MAX_AGE_SECS {
            let _ = fs::remove_file(&path);
        } else {
            sessions.push(session);
        }
    }
    sessions
}

fn same_path(a: &str, b: &str) -> bool {
    a.trim_end_matches('\\')
        .eq_ignore_ascii_case(b.trim_end_matches('\\'))
}

/// The shell that recorded the session is still running.
fn alive(session: &Session) -> bool {
    session.started != 0
        && win::process_start(session.pid)
            .is_some_and(|started| started.abs_diff(session.started) <= START_SLACK)
}

/// Most recent first, one entry per directory, skipping directories that are
/// open right now or no longer exist.
fn candidates(
    mut sessions: Vec<Session>,
    alive: impl Fn(&Session) -> bool,
    exists: impl Fn(&str) -> bool,
) -> Vec<Session> {
    let open: Vec<String> = sessions
        .iter()
        .filter(|s| alive(s))
        .map(|s| s.path.clone())
        .collect();
    sessions.sort_by_key(|s| std::cmp::Reverse(s.updated));
    let mut seen: HashSet<String> = HashSet::new();
    sessions
        .into_iter()
        .filter(|s| !open.iter().any(|p| same_path(p, &s.path)))
        // `;` separates wt subcommands and its escaping rules are not reliable
        // for every position, so such directories are not offered for restore.
        .filter(|s| !s.path.contains(';'))
        .filter(|s| exists(&s.path))
        .filter(|s| seen.insert(s.path.trim_end_matches('\\').to_lowercase()))
        .take(MAX_ENTRIES)
        .collect()
}

fn age(seconds: u64) -> String {
    match seconds {
        0..=59 => t!("just now", "刚刚"),
        60..=3599 => t!("{} min ago", "{} 分钟前", seconds / 60),
        3600..=86399 => t!("{} h ago", "{} 小时前", seconds / 3600),
        _ => t!("{} d ago", "{} 天前", seconds / 86400),
    }
}

// ---- picker model -------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Key {
    Up,
    Down,
    PageUp,
    PageDown,
    Home,
    End,
    Space,
    All,
    Enter,
    Esc,
}

#[derive(Debug, PartialEq)]
pub enum Outcome {
    Continue,
    Done(Vec<usize>),
    Cancel,
}

pub struct Picker {
    len: usize,
    visible: usize,
    pub cursor: usize,
    pub top: usize,
    pub selected: Vec<bool>,
}

impl Picker {
    pub fn new(len: usize, visible: usize) -> Self {
        Self {
            len,
            visible: visible.min(len).max(1),
            cursor: 0,
            top: 0,
            selected: vec![false; len],
        }
    }

    pub fn apply(&mut self, key: Key) -> Outcome {
        let last = self.len.saturating_sub(1);
        match key {
            Key::Up => {
                self.cursor = if self.cursor == 0 {
                    last
                } else {
                    self.cursor - 1
                }
            }
            Key::Down => {
                self.cursor = if self.cursor >= last {
                    0
                } else {
                    self.cursor + 1
                }
            }
            Key::PageUp => self.cursor = self.cursor.saturating_sub(self.visible),
            Key::PageDown => self.cursor = (self.cursor + self.visible).min(last),
            Key::Home => self.cursor = 0,
            Key::End => self.cursor = last,
            Key::Space => self.selected[self.cursor] = !self.selected[self.cursor],
            Key::All => {
                let target = !self.selected.iter().all(|&s| s);
                self.selected.iter_mut().for_each(|s| *s = target);
            }
            Key::Esc => return Outcome::Cancel,
            Key::Enter => {
                let chosen: Vec<usize> = (0..self.len).filter(|&i| self.selected[i]).collect();
                // Nothing ticked: Enter takes the highlighted row.
                return Outcome::Done(if chosen.is_empty() {
                    vec![self.cursor]
                } else {
                    chosen
                });
            }
        }
        if self.cursor < self.top {
            self.top = self.cursor;
        } else if self.cursor >= self.top + self.visible {
            self.top = self.cursor + 1 - self.visible;
        }
        Outcome::Continue
    }
}

/// Terminal cells a character occupies (CJK is double width).
fn cells(c: char) -> usize {
    match c as u32 {
        0x1100..=0x115F
        | 0x2E80..=0xA4CF
        | 0xAC00..=0xD7A3
        | 0xF900..=0xFAFF
        | 0xFE30..=0xFE6F
        | 0xFF00..=0xFF60
        | 0xFFE0..=0xFFE6 => 2,
        _ => 1,
    }
}

/// Keeps the end of a path (the informative part) within `limit` cells.
fn fit(text: &str, limit: usize) -> String {
    let total: usize = text.chars().map(cells).sum();
    if total <= limit {
        return text.to_string();
    }
    let mut kept: Vec<char> = Vec::new();
    let mut used = 1; // the ellipsis
    for c in text.chars().rev() {
        if used + cells(c) > limit {
            break;
        }
        used += cells(c);
        kept.push(c);
    }
    kept.push('…');
    kept.iter().rev().collect()
}

fn render(rows: &[(String, String)], picker: &Picker, width: usize) -> Vec<String> {
    let chosen = picker.selected.iter().filter(|&&s| s).count();
    let mut lines = vec![t!(
        "Select sessions to reopen  (Up/Down move, Space select, A all, Enter confirm, Esc cancel)  selected: {chosen}",
        "选择要恢复的会话  （上下键移动，空格选中，A 全选，回车确认，Esc 取消）  已选：{chosen}"
    )];
    let age_width = rows
        .iter()
        .map(|r| r.1.chars().map(cells).sum())
        .max()
        .unwrap_or(0);
    let path_width = width.saturating_sub(6 + 2 + age_width + 1).max(10);
    for (index, (path, when)) in rows
        .iter()
        .enumerate()
        .skip(picker.top)
        .take(picker.visible)
    {
        let shown = fit(path, path_width);
        let padding = path_width.saturating_sub(shown.chars().map(cells).sum());
        lines.push(format!(
            "{} [{}] {shown}{}  {when}",
            if index == picker.cursor { ">" } else { " " },
            if picker.selected[index] { "x" } else { " " },
            " ".repeat(padding)
        ));
    }
    lines
}

// ---- console ------------------------------------------------------------

struct RawConsole {
    input: *mut std::ffi::c_void,
    output: *mut std::ffi::c_void,
    input_mode: u32,
    output_mode: u32,
}

impl RawConsole {
    /// None when stdin/stdout are not a real console (redirected, or a pipe).
    fn enter() -> Option<Self> {
        unsafe {
            let input = GetStdHandle(STD_INPUT_HANDLE);
            let output = GetStdHandle(STD_OUTPUT_HANDLE);
            let (mut input_mode, mut output_mode) = (0, 0);
            if GetConsoleMode(input, &mut input_mode) == 0
                || GetConsoleMode(output, &mut output_mode) == 0
            {
                return None;
            }
            if SetConsoleMode(
                output,
                output_mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING,
            ) == 0
            {
                return None;
            }
            // Ctrl+C arrives as a key (handled as cancel) so the modes always get restored.
            let raw =
                input_mode & !(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
            if SetConsoleMode(input, raw) == 0 {
                SetConsoleMode(output, output_mode);
                return None;
            }
            Some(Self {
                input,
                output,
                input_mode,
                output_mode,
            })
        }
    }

    fn width(&self) -> usize {
        let mut info: CONSOLE_SCREEN_BUFFER_INFO = unsafe { std::mem::zeroed() };
        if unsafe { GetConsoleScreenBufferInfo(self.output, &mut info) } == 0 {
            return 80;
        }
        ((info.srWindow.Right - info.srWindow.Left + 1).max(20)) as usize
    }

    fn read_key(&self) -> Option<Key> {
        loop {
            let mut record: INPUT_RECORD = unsafe { std::mem::zeroed() };
            let mut read = 0;
            if unsafe { ReadConsoleInputW(self.input, &mut record, 1, &mut read) } == 0 || read == 0
            {
                return None;
            }
            if record.EventType != KEY_EVENT as u16 {
                continue;
            }
            let key = unsafe { record.Event.KeyEvent };
            if key.bKeyDown == 0 {
                continue;
            }
            let character = unsafe { key.uChar.UnicodeChar };
            return Some(match key.wVirtualKeyCode {
                VK_UP => Key::Up,
                VK_DOWN => Key::Down,
                VK_PRIOR => Key::PageUp,
                VK_NEXT => Key::PageDown,
                VK_HOME => Key::Home,
                VK_END => Key::End,
                VK_SPACE => Key::Space,
                VK_RETURN => Key::Enter,
                VK_ESCAPE => Key::Esc,
                _ if character == 3 => Key::Esc,
                _ if character == u16::from(b'a') || character == u16::from(b'A') => Key::All,
                _ if character == u16::from(b'k') => Key::Up,
                _ if character == u16::from(b'j') => Key::Down,
                _ => continue,
            });
        }
    }
}

impl Drop for RawConsole {
    fn drop(&mut self) {
        unsafe {
            SetConsoleMode(self.input, self.input_mode);
            SetConsoleMode(self.output, self.output_mode);
        }
    }
}

/// Runs the picker; None when cancelled or when there is no console to draw on.
fn pick(rows: &[(String, String)]) -> Option<Option<Vec<usize>>> {
    let console = RawConsole::enter()?;
    let mut picker = Picker::new(rows.len(), VISIBLE_ROWS);
    let mut drawn = 0;
    let mut stdout = io::stdout();
    let result = loop {
        let lines = render(rows, &picker, console.width());
        let mut frame = String::new();
        if drawn > 0 {
            frame.push_str(&format!("\x1b[{drawn}A\r\x1b[J"));
        }
        for line in &lines {
            frame.push_str(line);
            frame.push_str("\r\n");
        }
        drawn = lines.len();
        let _ = stdout.write_all(frame.as_bytes());
        let _ = stdout.flush();
        let Some(key) = console.read_key() else {
            break None;
        };
        match picker.apply(key) {
            Outcome::Continue => {}
            Outcome::Done(chosen) => break Some(chosen),
            Outcome::Cancel => break None,
        }
    };
    let _ = stdout.write_all(format!("\x1b[{drawn}A\r\x1b[J").as_bytes());
    let _ = stdout.flush();
    Some(result)
}

// ---- launching ----------------------------------------------------------

fn wt_exe(requested: Option<&Path>) -> Result<PathBuf, String> {
    if let Some(path) = requested {
        return Ok(path.to_path_buf());
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let alias = PathBuf::from(local).join(r"Microsoft\WindowsApps\wt.exe");
        if alias.exists() {
            return Ok(alias);
        }
    }
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path)
        .map(|dir| dir.join("wt.exe"))
        .find(|candidate| candidate.is_file())
        .ok_or_else(|| {
            t!(
                "Cannot find wt.exe (Windows Terminal).",
                "找不到 wt.exe（Windows Terminal）。"
            )
        })
}

/// `{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}`, the only profile form handed to wt.
fn is_profile_guid(text: &str) -> bool {
    text.len() == 38
        && text.starts_with('{')
        && text.ends_with('}')
        && text[1..37].chars().enumerate().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                c == '-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

/// One `wt` command line that opens every session as a tab of the current window.
fn wt_args(sessions: &[&Session]) -> Vec<String> {
    let mut args: Vec<String> = vec!["-w".into(), "0".into()];
    for (index, session) in sessions.iter().enumerate() {
        if index > 0 {
            args.push(";".into());
        }
        args.push("new-tab".into());
        if is_profile_guid(&session.profile) {
            args.push("-p".into());
            args.push(session.profile.clone());
        }
        args.push("-d".into());
        let directory = if session.path.len() > 3 {
            session.path.trim_end_matches('\\')
        } else {
            &session.path
        };
        // Paths containing `;` never get here (see `candidates`).
        args.push(directory.to_string());
    }
    args
}

fn parse_select(text: &str, count: usize) -> Result<Vec<usize>, String> {
    let mut chosen = Vec::new();
    for part in text.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let number: usize = part.parse().map_err(|_| {
            t!(
                "'{part}' is not a session number.",
                "'{part}' 不是有效的会话编号。"
            )
        })?;
        if number == 0 || number > count {
            return Err(t!(
                "Session {number} does not exist (1-{count}).",
                "会话 {number} 不存在（范围 1-{count}）。"
            ));
        }
        if !chosen.contains(&(number - 1)) {
            chosen.push(number - 1);
        }
    }
    if chosen.is_empty() {
        return Err(t!("No session selected.", "没有选中任何会话。"));
    }
    Ok(chosen)
}

pub fn run(args: &Args, out: &mut dyn Write) -> Result<(), String> {
    let items = candidates(load(&args.state), alive, |path| Path::new(path).is_dir());
    if items.is_empty() {
        let _ = writeln!(
            out,
            "{}",
            t!(
                "No recent sessions to restore. Directories are recorded for PowerShell tabs opened after installing.",
                "没有可恢复的最近会话。安装后新开的 PowerShell 标签页才会被记录目录。"
            )
        );
        return Ok(());
    }
    let current = now();
    let rows: Vec<(String, String)> = items
        .iter()
        .map(|s| (s.path.clone(), age(current.saturating_sub(s.updated))))
        .collect();
    if args.list {
        for (index, (path, when)) in rows.iter().enumerate() {
            let _ = writeln!(out, "{:>2}  {path}  ({when})", index + 1);
        }
        return Ok(());
    }
    let chosen = if let Some(text) = &args.select {
        parse_select(text, items.len())?
    } else {
        match pick(&rows) {
            Some(Some(chosen)) => chosen,
            Some(None) => return Ok(()),
            None => {
                return Err(t!(
                    "restore needs an interactive terminal; use --list to see the sessions and --select N,M to reopen them.",
                    "restore 需要在交互式终端中运行；可用 --list 查看会话，用 --select N,M 直接恢复。"
                ));
            }
        }
    };
    let picked: Vec<&Session> = chosen.iter().map(|&i| &items[i]).collect();
    let status = Command::new(wt_exe(args.wt_exe.as_deref())?)
        .args(wt_args(&picked))
        .status()
        .map_err(|e| {
            t!(
                "Cannot start Windows Terminal: {e}",
                "无法启动 Windows Terminal：{e}"
            )
        })?;
    if !status.success() {
        return Err(t!(
            "Windows Terminal exited with {status}.",
            "Windows Terminal 退出，状态：{status}。"
        ));
    }
    let count = picked.len();
    let _ = writeln!(
        out,
        "{}",
        t!(
            "Reopened {count} tab(s) in Windows Terminal.",
            "已在 Windows Terminal 中恢复 {count} 个标签页。"
        )
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(path: &str, updated: u64, pid: u32) -> Session {
        Session {
            path: path.into(),
            profile: String::new(),
            pid,
            started: 1,
            updated,
        }
    }

    #[test]
    fn candidates_are_recent_first_unique_and_skip_open_or_missing_paths() {
        let sessions = vec![
            session(r"C:\a", 10, 1),
            session(r"C:\b", 30, 2),
            session(r"c:\A\", 20, 3), // same directory as C:\a, newer
            session(r"C:\gone", 40, 4),
            session(r"C:\open", 50, 5),
            session(r"C:\open", 5, 6), // an older closed tab of a directory that is open now
        ];
        let result = candidates(sessions, |s| s.pid == 5, |p| p != r"C:\gone");
        let paths: Vec<&str> = result.iter().map(|s| s.path.as_str()).collect();
        assert_eq!(paths, [r"C:\b", r"c:\A\"]);
    }

    #[test]
    fn candidates_are_capped() {
        let sessions = (0..100)
            .map(|i| session(&format!(r"C:\d{i}"), i, 0))
            .collect();
        assert_eq!(candidates(sessions, |_| false, |_| true).len(), MAX_ENTRIES);
    }

    #[test]
    fn picker_moves_wraps_scrolls_and_selects() {
        let mut picker = Picker::new(5, 2);
        assert_eq!(picker.apply(Key::Up), Outcome::Continue);
        assert_eq!((picker.cursor, picker.top), (4, 3));
        picker.apply(Key::Down);
        assert_eq!((picker.cursor, picker.top), (0, 0));
        picker.apply(Key::Space);
        picker.apply(Key::Down);
        picker.apply(Key::Down);
        picker.apply(Key::Space);
        assert_eq!(picker.apply(Key::Enter), Outcome::Done(vec![0, 2]));
        picker.apply(Key::Space); // untick row 2
        picker.apply(Key::Space); // and tick it again
        picker.apply(Key::Space);
        assert_eq!(picker.selected, [true, false, false, false, false]);
    }

    #[test]
    fn enter_without_ticks_takes_the_highlighted_row_and_esc_cancels() {
        let mut picker = Picker::new(3, 3);
        picker.apply(Key::Down);
        assert_eq!(picker.apply(Key::Enter), Outcome::Done(vec![1]));
        assert_eq!(picker.apply(Key::Esc), Outcome::Cancel);
    }

    #[test]
    fn all_toggles_every_row() {
        let mut picker = Picker::new(3, 3);
        picker.apply(Key::All);
        assert!(picker.selected.iter().all(|&s| s));
        picker.apply(Key::All);
        assert!(picker.selected.iter().all(|&s| !s));
    }

    #[test]
    fn fit_keeps_the_end_of_long_paths_and_respects_wide_characters() {
        assert_eq!(fit("short", 10), "short");
        let fitted = fit(r"C:\very\long\directory\name", 12);
        assert!(fitted.starts_with('…') && fitted.ends_with("name"));
        assert!(fitted.chars().map(cells).sum::<usize>() <= 12);
        let wide = fit("目录目录目录目录目录", 7);
        assert!(wide.chars().map(cells).sum::<usize>() <= 7);
    }

    #[test]
    fn render_marks_cursor_and_selection_within_the_width() {
        let rows: Vec<(String, String)> = (0..3)
            .map(|i| (format!(r"C:\project{i}"), "1 min".to_string()))
            .collect();
        let mut picker = Picker::new(3, 3);
        picker.apply(Key::Space);
        picker.apply(Key::Down);
        let lines = render(&rows, &picker, 60);
        assert_eq!(lines.len(), 4);
        assert!(lines[1].starts_with("  [x] "));
        assert!(lines[2].starts_with("> [ ] "));
        assert!(
            lines[1..]
                .iter()
                .all(|l| l.chars().map(cells).sum::<usize>() < 60)
        );
    }

    #[test]
    fn wt_args_open_one_tab_per_session_in_the_current_window() {
        let a = Session {
            profile: "{574e775e-4f2a-5b96-ac1e-a2962a402336}".into(),
            ..session(r"D:\work\a\", 1, 0)
        };
        let b = session(r"D:\", 1, 0);
        assert_eq!(
            wt_args(&[&a, &b]),
            [
                "-w",
                "0",
                "new-tab",
                "-p",
                "{574e775e-4f2a-5b96-ac1e-a2962a402336}",
                "-d",
                r"D:\work\a",
                ";",
                "new-tab",
                "-d",
                r"D:\"
            ]
        );
    }

    #[test]
    fn semicolon_paths_are_never_offered_and_profiles_must_be_guids() {
        let sessions = vec![
            session(r"C:\odd;", 4, 0),
            session(r"C:\a;calc.exe", 3, 0),
            session(r"C:\;new-tab", 2, 0),
            session(r"C:\fine", 1, 0),
        ];
        let result = candidates(sessions, |_| false, |_| true);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].path, r"C:\fine");
        let hostile = Session {
            profile: r"{x}; new-tab -d C:\evil".into(),
            ..session(r"C:\fine", 1, 0)
        };
        assert_eq!(
            wt_args(&[&hostile]),
            ["-w", "0", "new-tab", "-d", r"C:\fine"]
        );
        assert!(is_profile_guid("{574e775e-4f2a-5b96-ac1e-a2962a402336}"));
        assert!(!is_profile_guid("{574e775e-4f2a-5b96-ac1e-a2962a40233}"));
        assert!(!is_profile_guid("{574e775e-4f2a-5b96-ac1e-a2962a40233g}"));
        assert!(!is_profile_guid(""));
    }

    #[test]
    fn select_parses_one_based_lists_and_rejects_bad_input() {
        assert_eq!(parse_select("2, 1,2", 3).unwrap(), [1, 0]);
        assert!(parse_select("4", 3).is_err());
        assert!(parse_select("0", 3).is_err());
        assert!(parse_select("x", 3).is_err());
        assert!(parse_select(" , ", 3).is_err());
    }

    #[test]
    fn session_files_parse_with_missing_optional_fields() {
        let parsed: Session = serde_json::from_str(r#"{"path":"C:\\x","updated":5}"#).unwrap();
        assert_eq!(
            (parsed.path.as_str(), parsed.pid, parsed.updated),
            (r"C:\x", 0, 5)
        );
    }
}
