//! `wtpocket run`: runs a program (claude, vim, ssh...) inside a private pseudo
//! console and relays bytes between it and the tab's console. Every key typed
//! while it runs passes through here, so Alt+F can toggle the panel even though
//! PowerShell's own handler is not reading input. Everything else is forwarded
//! unchanged.
use crate::{
    client::{self, OpenArgs},
    paths::Layout,
    win::{self, Handle},
};
use std::{
    ffi::c_void,
    fs::OpenOptions,
    io::Write,
    mem::size_of,
    path::{Path, PathBuf},
    process::Command,
    ptr,
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use windows_sys::Win32::{
    Foundation::*,
    Storage::FileSystem::{ReadFile, WriteFile},
    System::{Console::*, Diagnostics::ToolHelp::*, Pipes::CreatePipe, Threading::*},
};

const ESC: u8 = 0x1b;
const VK_F: u32 = 0x46;
// win32-input-mode control-key state bits.
const RIGHT_ALT: u32 = 0x01;
const LEFT_ALT: u32 = 0x02;
const CTRL: u32 = 0x04 | 0x08;
const SHIFT: u32 = 0x10;
const RESET_MODES: &[u8] = b"\x1b[?2004l\x1b[?1004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2031l\x1b[?9001l\x1b[<99u\x1b[>4m\x1b[?25h\x1b[0m";
/// Longest partial `ESC [ ...` sequence kept across reads.
const MAX_PENDING: usize = 64;

/// Finds Alt+F in the tab's input and removes it; every other byte is
/// forwarded unchanged, in order.
#[derive(Default)]
pub struct InputFilter {
    pending: Vec<u8>,
    /// The F key-up that belongs to a swallowed Alt+F, which may arrive after Alt is released.
    swallow_f_up: bool,
}

impl InputFilter {
    /// Returns the bytes to forward and how many Alt+F presses were removed.
    pub fn feed(&mut self, data: &[u8]) -> (Vec<u8>, usize) {
        let mut input = std::mem::take(&mut self.pending);
        input.extend_from_slice(data);
        let mut out = Vec::with_capacity(input.len());
        let mut hits = 0;
        let mut i = 0;
        while i < input.len() {
            if input[i] == ESC && input.get(i + 1) == Some(&b'[') {
                let mut end = i + 2;
                while end < input.len() && (input[end].is_ascii_digit() || input[end] == b';') {
                    end += 1;
                }
                if end == input.len() {
                    // Incomplete; the next read finishes it.
                    if end - i <= MAX_PENDING {
                        self.pending = input[i..].to_vec();
                    } else {
                        out.extend_from_slice(&input[i..]);
                    }
                    break;
                }
                if input[end] == b'_' {
                    let key = Win32Key::parse(&input[i + 2..end]);
                    match self.classify(&key) {
                        Some(hit) => hits += usize::from(hit),
                        None => out.extend_from_slice(&input[i..=end]),
                    }
                    i = end + 1;
                    continue;
                }
                if end == i + 2 && matches!(input[end], b'I' | b'O') {
                    // Focus moved (the panel took it): the F release went elsewhere.
                    self.swallow_f_up = false;
                }
            } else if input[i] == ESC && input.get(i + 1) == Some(&b'f') {
                // Legacy encoding, used when win32-input-mode is off.
                hits += 1;
                i += 2;
                continue;
            }
            out.push(input[i]);
            i += 1;
        }
        (out, hits)
    }

    /// `Some(true)`: a new Alt+F press; `Some(false)`: its repeat or release
    /// (also swallowed); `None`: forward.
    fn classify(&mut self, key: &Win32Key) -> Option<bool> {
        if key.vk != VK_F {
            // Auto-repeat sends only F downs; any other press starts a new chord.
            if key.down {
                self.swallow_f_up = false;
            }
            return None;
        }
        if !key.down {
            return std::mem::take(&mut self.swallow_f_up).then_some(false);
        }
        let alt = key.state & (LEFT_ALT | RIGHT_ALT) != 0;
        // Ctrl+Alt is AltGr on many layouts; leave it, and Shift+Alt+F, alone.
        if !alt || key.state & (CTRL | SHIFT) != 0 {
            return None;
        }
        let repeat = self.swallow_f_up;
        self.swallow_f_up = true;
        Some(!repeat)
    }
}

/// `ESC [ Vk ; Sc ; Uc ; Kd ; Cs ; Rc _`; omitted fields are 0.
struct Win32Key {
    vk: u32,
    down: bool,
    state: u32,
}
impl Win32Key {
    fn parse(params: &[u8]) -> Self {
        let mut fields = [0u32; 6];
        for (slot, text) in fields.iter_mut().zip(params.split(|&b| b == b';')) {
            *slot = std::str::from_utf8(text)
                .ok()
                .and_then(|t| t.parse().ok())
                .unwrap_or(0);
        }
        Self {
            vk: fields[0],
            down: fields[3] != 0,
            state: fields[4],
        }
    }
}

/// .NET `DateTime` ticks at the FILETIME epoch (1601-01-01).
const DOTNET_FILETIME_EPOCH: u64 = 504_911_232_000_000_000;
static TOGGLING: AtomicBool = AtomicBool::new(false);

/// The tab's panel, as the PowerShell Alt+F handler of the calling shell
/// would open it.
#[derive(Clone)]
struct Target {
    state: PathBuf,
    /// The calling shell's location: PowerShell starts native programs in it.
    directory: PathBuf,
    session: String,
}

impl Target {
    fn detect() -> Result<Self, String> {
        let state = Layout::default_user().map_err(|e| e.to_string())?.state;
        let own = std::process::id();
        let started = win::process_start(own).ok_or("Cannot read the process start time.")?;
        // A parent that started after us is a recycled id, not our shell.
        let session = parent_of(own)
            .and_then(|parent| win::process_start(parent).map(|start| (parent, start)))
            .filter(|&(_, start)| start <= started)
            // Same id as the PowerShell handler: "$PID-$StartTime.ToUniversalTime().Ticks".
            .map(|(parent, start)| format!("{parent}-{}", start + DOTNET_FILETIME_EPOCH))
            .unwrap_or_default();
        Ok(Self {
            state,
            directory: std::env::current_dir().map_err(|e| e.to_string())?,
            session,
        })
    }

    /// Shows or hides the panel off the input thread; a press while one is
    /// in flight is ignored.
    fn toggle(&self) {
        // Capture the focused terminal before anything can change focus.
        let source_window = win::foreground();
        if TOGGLING.swap(true, Ordering::AcqRel) {
            return;
        }
        let target = self.clone();
        thread::spawn(move || {
            let result = client::open(&OpenArgs {
                state: target.state.clone(),
                directory: target.directory,
                session: target.session,
                pwsh: None,
                source_window,
            });
            match result {
                Ok(()) => trace("Alt+F: toggled"),
                Err(error) => crate::append_log(&target.state, &format!("run: Alt+F: {error}")),
            }
            TOGGLING.store(false, Ordering::Release);
        });
    }
}

fn parent_of(pid: u32) -> Option<u32> {
    let snapshot = Handle(unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) });
    if snapshot.0 == INVALID_HANDLE_VALUE {
        return None;
    }
    let mut entry = PROCESSENTRY32W {
        dwSize: size_of::<PROCESSENTRY32W>() as u32,
        ..unsafe { std::mem::zeroed() }
    };
    let mut more = unsafe { Process32FirstW(snapshot.0, &mut entry) } != 0;
    while more {
        if entry.th32ProcessID == pid {
            return Some(entry.th32ParentProcessID);
        }
        more = unsafe { Process32NextW(snapshot.0, &mut entry) } != 0;
    }
    None
}

fn tracing() -> bool {
    std::env::var_os("WTPOCKET_RUN_TRACE").is_some()
}

/// Troubleshooting log (`WTPOCKET_RUN_TRACE=1`); it records every key.
fn trace(line: &str) {
    if !tracing() {
        return;
    }
    let path = std::env::temp_dir().join("wtpocket-run.log");
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let _ = writeln!(file, "{now} [{}] {line}", std::process::id());
    }
}

/// Quotes one argument for `CreateProcessW` (MSVCRT rules).
fn quote(arg: &str) -> String {
    if !arg.is_empty() && !arg.contains([' ', '\t', '"']) {
        return arg.to_string();
    }
    let mut out = String::from("\"");
    let mut backslashes = 0;
    for c in arg.chars() {
        match c {
            '\\' => backslashes += 1,
            '"' => {
                out.extend(std::iter::repeat_n('\\', backslashes * 2 + 1));
                out.push('"');
                backslashes = 0;
            }
            _ => {
                out.extend(std::iter::repeat_n('\\', backslashes));
                out.push(c);
                backslashes = 0;
            }
        }
    }
    out.extend(std::iter::repeat_n('\\', backslashes * 2));
    out.push('"');
    out
}

fn window_size(output: HANDLE) -> Option<COORD> {
    let mut info = CONSOLE_SCREEN_BUFFER_INFO::default();
    if unsafe { GetConsoleScreenBufferInfo(output, &mut info) } == 0 {
        return None;
    }
    let w = info.srWindow;
    Some(COORD {
        X: w.Right - w.Left + 1,
        Y: w.Bottom - w.Top + 1,
    })
}

fn last_error(what: &str) -> String {
    format!("{what}: {}", std::io::Error::last_os_error())
}

/// Finds `name` the way a shell would: an explicit path is used as given,
/// a bare name is looked up on PATH with each PATHEXT extension.
fn resolve(name: &str) -> Option<PathBuf> {
    let path = Path::new(name);
    if path.components().count() > 1 {
        return path.is_file().then(|| path.to_path_buf());
    }
    let extensions = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
    let extensions: Vec<&str> = extensions.split(';').filter(|e| !e.is_empty()).collect();
    let has_extension = path.extension().is_some();
    std::env::split_paths(&std::env::var_os("PATH")?)
        .flat_map(|dir| {
            let plain = has_extension.then(|| dir.join(name));
            let extended = extensions
                .iter()
                .map(move |ext| dir.join(format!("{name}{ext}")));
            plain.into_iter().chain(extended)
        })
        .find(|candidate| candidate.is_file())
}

/// The full command line: batch files (npm shims such as claude.cmd) run
/// through cmd.exe, which strips the outer quotes with /s.
fn command_line(program: &Path, args: &[String]) -> String {
    let mut line = quote(&program.to_string_lossy());
    for arg in args {
        line.push(' ');
        line.push_str(&quote(arg));
    }
    let batch = program
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"));
    if batch {
        let shell = std::env::var("ComSpec").unwrap_or_else(|_| "cmd.exe".into());
        line = format!("{} /d /s /c \"{line}\"", quote(&shell));
    }
    line
}

pub fn run(args: &[String]) -> Result<u32, String> {
    let args = match args.first().map(String::as_str) {
        Some("--") => &args[1..],
        _ => args,
    };
    let Some((name, rest)) = args.split_first() else {
        return Err(t!(
            "Usage: wtpocket run [--] <program> [arguments...]",
            "用法：wtpocket run [--] <程序> [参数...]"
        ));
    };
    let program = resolve(name).ok_or_else(|| {
        t!(
            "Cannot find '{name}' on PATH. PowerShell aliases and functions cannot be run this way.",
            "在 PATH 中找不到“{name}”。PowerShell 的别名和函数不能这样运行。"
        )
    })?;

    let stdin = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
    let stdout = unsafe { GetStdHandle(STD_OUTPUT_HANDLE) };
    let (mut in_mode, mut out_mode) = (0, 0);
    let console = unsafe {
        GetConsoleMode(stdin, &mut in_mode) != 0 && GetConsoleMode(stdout, &mut out_mode) != 0
    };
    let size = window_size(stdout);
    let target = Target::detect();
    // Outside Windows Terminal, or with redirected input or output, there is
    // no panel to toggle: run the program plainly.
    let (Some(size), true, true, Ok(target)) = (
        size,
        console,
        std::env::var_os("WT_SESSION").is_some(),
        target,
    ) else {
        return Command::new(&program)
            .args(rest)
            .status()
            .map(|status| status.code().unwrap_or(1) as u32)
            .map_err(|e| e.to_string());
    };
    let line = command_line(&program, rest);
    unsafe {
        // Raw VT input (as golang.org/x/term MakeRaw): Ctrl+C and friends
        // arrive as bytes for the inner shell.
        SetConsoleMode(
            stdin,
            in_mode & !(ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT)
                | ENABLE_VIRTUAL_TERMINAL_INPUT,
        );
        // A bare LF from the inner pseudo console must only move down.
        SetConsoleMode(
            stdout,
            out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN,
        );
        SetConsoleCtrlHandler(None, 1);
    }
    let result = relay(&line, size, stdin, stdout, target);
    // Undo modes a TUI may have left on (bracketed paste, focus and mouse
    // reporting, keyboard protocols) so the tab works normally afterwards.
    let _ = write_console(stdout as isize, &mut Vec::new(), RESET_MODES);
    unsafe {
        SetConsoleMode(stdin, in_mode);
        SetConsoleMode(stdout, out_mode);
    }
    result
}

fn relay(
    line: &str,
    size: COORD,
    stdin: HANDLE,
    stdout: HANDLE,
    target: Target,
) -> Result<u32, String> {
    let (mut pty_in, mut to_pty) = (ptr::null_mut(), ptr::null_mut());
    let (mut from_pty, mut pty_out) = (ptr::null_mut(), ptr::null_mut());
    unsafe {
        if CreatePipe(&mut pty_in, &mut to_pty, ptr::null(), 0) == 0
            || CreatePipe(&mut from_pty, &mut pty_out, ptr::null(), 0) == 0
        {
            return Err(last_error("CreatePipe"));
        }
    }
    let (pty_in, to_pty, from_pty, pty_out) = (
        Handle(pty_in),
        Handle(to_pty),
        Handle(from_pty),
        Handle(pty_out),
    );
    let mut console: HPCON = 0;
    let hr = unsafe { CreatePseudoConsole(size, pty_in.0, pty_out.0, 0, &mut console) };
    if hr < 0 {
        return Err(format!("CreatePseudoConsole failed: 0x{hr:08x}"));
    }
    // The pseudo console holds its own duplicates.
    drop((pty_in, pty_out));

    let process = spawn(line, console)?;
    trace(&format!("started {line} size={}x{}", size.X, size.Y));

    let (output_source, output_sink) = (from_pty.0 as isize, stdout as isize);
    let output = thread::spawn(move || copy(output_source, output_sink));

    let (input_source, input_sink) = (stdin as isize, to_pty.0 as isize);
    thread::spawn(move || {
        let mut filter = InputFilter::default();
        let mut reader = ConsoleReader::default();
        loop {
            let Some(chunk) = reader.read(input_source) else {
                return;
            };
            let chunk = chunk.as_bytes();
            if tracing() {
                trace(&format!("in {}", chunk.escape_ascii()));
            }
            let (forward, hits) = filter.feed(chunk);
            if hits > 0 {
                target.toggle();
            }
            if !forward.is_empty() && !write_all(input_sink, &forward) {
                return;
            }
        }
    });

    let resize_console = console;
    let resize_output = stdout as isize;
    thread::spawn(move || {
        let mut last = size;
        loop {
            thread::sleep(Duration::from_millis(100));
            if let Some(now) = window_size(resize_output as HANDLE)
                && (now.X != last.X || now.Y != last.Y)
            {
                unsafe { ResizePseudoConsole(resize_console, now) };
                last = now;
            }
        }
    });

    unsafe { WaitForSingleObject(process.0, INFINITE) };
    let mut code = 0;
    unsafe { GetExitCodeProcess(process.0, &mut code) };
    // Closing flushes the final output to the reader, then ends its pipe.
    unsafe { ClosePseudoConsole(console) };
    let _ = output.join();
    trace(&format!("exited {code}"));
    Ok(code)
}

fn spawn(line: &str, console: HPCON) -> Result<Handle, String> {
    let mut size = 0;
    unsafe { InitializeProcThreadAttributeList(ptr::null_mut(), 1, 0, &mut size) };
    // usize storage keeps the opaque list pointer-aligned.
    let mut storage = vec![0usize; size.div_ceil(size_of::<usize>())];
    let list = storage.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
    unsafe {
        if InitializeProcThreadAttributeList(list, 1, 0, &mut size) == 0 {
            return Err(last_error("InitializeProcThreadAttributeList"));
        }
        if UpdateProcThreadAttribute(
            list,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
            console as *const c_void,
            size_of::<HPCON>(),
            ptr::null_mut(),
            ptr::null(),
        ) == 0
        {
            DeleteProcThreadAttributeList(list);
            return Err(last_error("UpdateProcThreadAttribute"));
        }
    }
    let mut startup = STARTUPINFOEXW::default();
    startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
    startup.lpAttributeList = list;
    let mut command: Vec<u16> = line.encode_utf16().chain(Some(0)).collect();
    let mut info = PROCESS_INFORMATION::default();
    let ok = unsafe {
        CreateProcessW(
            ptr::null(),
            command.as_mut_ptr(),
            ptr::null(),
            ptr::null(),
            0,
            EXTENDED_STARTUPINFO_PRESENT,
            ptr::null(),
            ptr::null(),
            &startup.StartupInfo,
            &mut info,
        )
    };
    unsafe { DeleteProcThreadAttributeList(list) };
    if ok == 0 {
        return Err(last_error(&format!("Cannot start {line}")));
    }
    drop(Handle(info.hThread));
    Ok(Handle(info.hProcess))
}

fn write_all(sink: isize, mut data: &[u8]) -> bool {
    while !data.is_empty() {
        let mut written = 0;
        let ok = unsafe {
            WriteFile(
                sink as HANDLE,
                data.as_ptr(),
                data.len() as u32,
                &mut written,
                ptr::null_mut(),
            )
        };
        if ok == 0 || written == 0 {
            return false;
        }
        data = &data[written as usize..];
    }
    true
}

/// Reads the tab's console as UTF-16, independent of its code page: with
/// `ReadFile`, IME text arrives in the ANSI code page (GBK on Chinese systems).
#[derive(Default)]
struct ConsoleReader {
    /// A high surrogate whose partner is in the next read.
    high: Option<u16>,
}
impl ConsoleReader {
    fn read(&mut self, console: isize) -> Option<String> {
        let mut units = [0u16; 2048];
        let start = usize::from(self.high.is_some());
        if let Some(high) = self.high.take() {
            units[0] = high;
        }
        let mut read = 0;
        let ok = unsafe {
            ReadConsoleW(
                console as HANDLE,
                units[start..].as_mut_ptr().cast(),
                (units.len() - start) as u32,
                &mut read,
                ptr::null(),
            )
        };
        if ok == 0 {
            return None;
        }
        let mut end = start + read as usize;
        if end > 0 && (0xD800..0xDC00).contains(&units[end - 1]) {
            end -= 1;
            self.high = Some(units[end]);
        }
        Some(String::from_utf16_lossy(&units[..end]))
    }
}

/// Writes UTF-8 to the tab's console as UTF-16.
fn write_console(console: isize, pending: &mut Vec<u8>, data: &[u8]) -> bool {
    let text = decode_utf8(pending, data);
    let units: Vec<u16> = text.encode_utf16().collect();
    let mut units = &units[..];
    while !units.is_empty() {
        let mut written = 0;
        let ok = unsafe {
            WriteConsoleW(
                console as HANDLE,
                units.as_ptr().cast(),
                units.len() as u32,
                &mut written,
                ptr::null(),
            )
        };
        if ok == 0 || written == 0 {
            return false;
        }
        units = &units[written as usize..];
    }
    true
}

/// Decodes `pending` + `data`. A code point split across reads waits in
/// `pending`; invalid bytes become U+FFFD.
fn decode_utf8(pending: &mut Vec<u8>, data: &[u8]) -> String {
    pending.extend_from_slice(data);
    let mut text = String::new();
    let mut rest: &[u8] = pending;
    loop {
        match std::str::from_utf8(rest) {
            Ok(valid) => {
                text.push_str(valid);
                rest = &[];
                break;
            }
            Err(error) => {
                let (valid, after) = rest.split_at(error.valid_up_to());
                text.push_str(std::str::from_utf8(valid).unwrap_or_default());
                match error.error_len() {
                    Some(bad) => {
                        text.push('\u{FFFD}');
                        rest = &after[bad..];
                    }
                    None => {
                        rest = after;
                        break;
                    }
                }
            }
        }
    }
    *pending = rest.to_vec();
    text
}

fn copy(source: isize, sink: isize) {
    let mut buffer = vec![0u8; 64 * 1024];
    let mut pending = Vec::new();
    loop {
        let mut read = 0;
        let ok = unsafe {
            ReadFile(
                source as HANDLE,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
                &mut read,
                ptr::null_mut(),
            )
        };
        if ok == 0 || read == 0 || !write_console(sink, &mut pending, &buffer[..read as usize]) {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(vk: u32, down: bool, state: u32) -> Vec<u8> {
        format!("\x1b[{vk};33;102;{};{state};1_", u8::from(down)).into_bytes()
    }

    #[test]
    fn swallows_win32_alt_f_down_and_its_release() {
        let mut f = InputFilter::default();
        let mut input = b"a".to_vec();
        input.extend(key(0x12, true, LEFT_ALT)); // Alt itself passes through
        input.extend(key(VK_F, true, LEFT_ALT));
        input.extend(key(VK_F, true, LEFT_ALT)); // auto-repeat
        input.extend(key(0x12, false, 0));
        input.extend(key(VK_F, false, 0)); // released after Alt
        input.push(b'b');
        let (out, hits) = f.feed(&input);
        let mut expected = b"a".to_vec();
        expected.extend(key(0x12, true, LEFT_ALT));
        expected.extend(key(0x12, false, 0));
        expected.push(b'b');
        assert_eq!((out, hits), (expected, 1));
    }

    #[test]
    fn leaves_other_keys_and_modifier_combinations_alone() {
        let mut f = InputFilter::default();
        for input in [
            key(VK_F, true, 0),
            key(VK_F, false, 0),
            key(VK_F, true, LEFT_ALT | 0x08), // AltGr
            key(VK_F, true, LEFT_ALT | SHIFT),
            b"\x1b[A".to_vec(),
            b"\x1bb".to_vec(),
        ] {
            assert_eq!(f.feed(&input), (input.clone(), 0));
        }
    }

    #[test]
    fn a_release_lost_to_the_panel_does_not_swallow_the_next_press() {
        let mut f = InputFilter::default();
        // The panel takes focus before F is released, so that release never arrives here.
        assert_eq!(f.feed(&key(VK_F, true, LEFT_ALT)).1, 1);
        assert_eq!(f.feed(b"\x1b[O\x1b[I"), (b"\x1b[O\x1b[I".to_vec(), 0));
        assert_eq!(f.feed(&key(VK_F, true, LEFT_ALT)).1, 1);
        // Without focus events, pressing Alt again also starts a new chord.
        f.feed(&key(0x12, true, LEFT_ALT));
        assert_eq!(f.feed(&key(VK_F, true, LEFT_ALT)).1, 1);
    }

    #[test]
    fn joins_sequences_split_across_reads() {
        let mut f = InputFilter::default();
        let whole = key(VK_F, true, RIGHT_ALT);
        let (a, b) = whole.split_at(5);
        assert_eq!(f.feed(a), (vec![], 0));
        assert_eq!(f.feed(b), (vec![], 1));
    }

    #[test]
    fn detects_the_legacy_escape_f_encoding() {
        assert_eq!(InputFilter::default().feed(b"x\x1bfy"), (b"xy".to_vec(), 1));
    }

    #[test]
    fn decodes_utf8_split_across_reads() {
        let mut pending = Vec::new();
        let bytes = "中文".as_bytes();
        assert_eq!(decode_utf8(&mut pending, &bytes[..4]), "中");
        assert_eq!(decode_utf8(&mut pending, &bytes[4..]), "文");
        assert!(pending.is_empty());
        assert_eq!(decode_utf8(&mut pending, b"a\xffb"), "a\u{FFFD}b");
    }

    #[test]
    fn batch_files_run_through_cmd_with_outer_quotes() {
        let exe = command_line(Path::new(r"C:\Tools\vim.exe"), &["a b".into()]);
        assert_eq!(exe, r#"C:\Tools\vim.exe "a b""#);
        let batch = command_line(Path::new(r"C:\npm dir\claude.cmd"), &["-c".into()]);
        assert!(
            batch.ends_with(r#" /d /s /c ""C:\npm dir\claude.cmd" -c""#),
            "{batch}"
        );
    }

    #[test]
    fn resolves_bare_names_on_path_and_rejects_missing_ones() {
        let found = resolve("cmd").expect("cmd.exe is on PATH");
        assert!(found.is_absolute() && found.is_file());
        assert!(resolve("wtpocket-no-such-program").is_none());
        assert!(resolve(r"C:\no\such\program.exe").is_none());
    }

    #[test]
    fn quotes_arguments_for_create_process() {
        assert_eq!(quote("plain"), "plain");
        assert_eq!(quote("a b"), "\"a b\"");
        assert_eq!(quote(""), "\"\"");
        assert_eq!(quote(r#"say "hi""#), r#""say \"hi\"""#);
        assert_eq!(quote(r"C:\dir with space\"), r#""C:\dir with space\\""#);
    }
}
