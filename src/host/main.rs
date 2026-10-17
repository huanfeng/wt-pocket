#![cfg_attr(not(test), windows_subsystem = "windows")]

mod ipc;
mod model;
#[cfg(test)]
mod tests;
mod win;

use model::{Bounds, Request, bootstrap};
use std::os::windows::process::CommandExt;
use std::{
    cell::RefCell,
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    process::{Command, ExitCode},
    ptr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use windows_sys::Win32::{
    Foundation::*,
    System::Threading::*,
    UI::{Input::KeyboardAndMouse::*, WindowsAndMessaging::*},
};

const HIDE_PANEL: u32 = WM_APP + 1;
const MAINTENANCE: usize = 1;
fn version() -> &'static str {
    option_env!("WTPOCKET_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
}

#[derive(Clone)]
struct Panel {
    window: isize,
    source: isize,
    title: String,
    bounds: Bounds,
}
impl Panel {
    fn valid(&self) -> bool {
        win::is_terminal(self.window) && win::marked(self.window, &self.title)
    }
}

struct Host {
    state: PathBuf,
    module: String,
    shell: String,
    panels: Mutex<HashMap<String, Panel>>,
    stopping: AtomicBool,
}

impl Host {
    fn log(&self, error: &str) {
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.state.join("host.log"))
        {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            let _ = writeln!(file, "{now} {error}");
        }
    }

    fn toggle(&self, request: Request) -> Result<(), String> {
        let source = request.source_window as isize;
        if !win::is_terminal(source) {
            return Err("Run Open-WtPanel in a foreground Windows Terminal window.".into());
        }
        {
            let mut panels = self.panels.lock().unwrap();
            if let Some(panel) = panels
                .values_mut()
                .find(|p| p.window == source && p.valid())
            {
                Self::hide_panel(panel);
                return Ok(());
            }
        }
        let path = Path::new(&request.directory);
        // Reject drive-relative paths as well as missing filesystem directories.
        if !path.is_absolute() || !path.is_dir() {
            return Err(
                "The current directory no longer exists or is not an absolute filesystem path."
                    .into(),
            );
        }
        let session = if request.session_id.trim().is_empty() {
            source.to_string()
        } else {
            request.session_id
        };
        {
            let mut panels = self.panels.lock().unwrap();
            if let Some(panel) = panels.get_mut(&session).filter(|p| p.valid()) {
                panel.source = source;
                if win::visible(panel.window) {
                    Self::hide_panel(panel);
                } else {
                    win::show(panel.window, panel.bounds);
                }
                return Ok(());
            }
        }

        let mut panel = Panel {
            window: 0,
            source,
            title: win::unique_title()?,
            bounds: win::initial_bounds(source)?,
        };
        let b = panel.bounds;
        // No caller-controlled paths go through WT's semicolon command parser.
        Command::new("wt.exe")
            .creation_flags(CREATE_NO_WINDOW)
            .args([
                "-w",
                &panel.title,
                "--focus",
                "--pos",
                &format!("{},{}", b.x, b.y),
                "--size",
                "80,20",
                "new-tab",
                "--title",
                &panel.title,
                "--suppressApplicationTitle",
                &self.shell,
                "-NoLogo",
                "-NoProfile",
                "-NoExit",
                "-EncodedCommand",
                &bootstrap(
                    &request.directory,
                    &self.module,
                    &self.state.to_string_lossy(),
                ),
            ])
            .spawn()
            .map_err(|e| format!("Cannot start Windows Terminal: {e}"))?;
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            panel.window = win::find_panel(&panel.title);
            if panel.window != 0 {
                break;
            }
            if self.stopping.load(Ordering::Relaxed) {
                return Err("Host is stopping.".into());
            }
            if Instant::now() >= deadline {
                return Err("Windows Terminal did not create the panel within 8 seconds. Check wt.exe and your Terminal profile.".into());
            }
            thread::sleep(Duration::from_millis(80));
        }
        win::mark(panel.window, &panel.title)?;
        thread::sleep(Duration::from_millis(600));
        // The IPC worker waits for WT, leaving the hook/message thread free.
        win::show(panel.window, panel.bounds);
        self.panels.lock().unwrap().insert(session, panel);
        Ok(())
    }

    fn hide_panel(panel: &mut Panel) {
        if !panel.valid() {
            return;
        }
        if let Some(bounds) = win::hide(panel.window, panel.source) {
            panel.bounds = bounds;
        }
    }

    fn hide_window(&self, window: isize) {
        if let Some(panel) = self
            .panels
            .lock()
            .unwrap()
            .values_mut()
            .find(|p| p.window == window)
        {
            Self::hide_panel(panel);
        }
    }

    fn recover_orphans(&self) {
        let Ok(mut panels) = self.panels.try_lock() else {
            return;
        };
        panels.retain(|_, p| {
            if !p.valid() {
                return false;
            }
            if !win::is_terminal(p.source) {
                win::reveal(p.window);
                win::unmark(p.window, &p.title);
                return false;
            }
            true
        });
    }

    fn reveal_all(&self) {
        for panel in self.panels.lock().unwrap().values() {
            if panel.valid() {
                win::reveal(panel.window);
                win::unmark(panel.window, &panel.title);
            }
        }
    }
}

#[derive(Clone, Copy)]
struct Drag {
    window: isize,
    origin: POINT,
    bounds: Bounds,
}
#[derive(Default)]
struct HookState {
    host: Option<Arc<Host>>,
    drag: Option<Drag>,
    f_down: bool,
}
thread_local! { static HOOKS: RefCell<HookState> = RefCell::new(HookState::default()); }

fn modifier(key: u16) -> bool {
    unsafe { GetAsyncKeyState(i32::from(key)) < 0 }
}
fn no_extra_modifiers() -> bool {
    ![VK_SHIFT, VK_CONTROL, VK_LWIN, VK_RWIN]
        .into_iter()
        .any(modifier)
}

unsafe extern "system" fn keyboard(code: i32, message: WPARAM, data: LPARAM) -> LRESULT {
    if code >= 0 {
        // Windows provides a valid KBDLLHOOKSTRUCT for nonnegative hook codes.
        let key = unsafe { &*(data as *const KBDLLHOOKSTRUCT) };
        if key.vkCode == u32::from(b'F') {
            let consumed = HOOKS.with(|cell| {
                let mut hooks = cell.borrow_mut();
                if message == WM_KEYUP as usize || message == WM_SYSKEYUP as usize {
                    return std::mem::take(&mut hooks.f_down);
                }
                if hooks.f_down {
                    return true;
                }
                if key.flags & LLKHF_ALTDOWN != 0 && no_extra_modifiers() {
                    let window = win::foreground();
                    let owned = hooks.host.as_ref().is_some_and(|host| {
                        host.panels.try_lock().is_ok_and(|panels| {
                            panels.values().any(|p| p.window == window && p.valid())
                        })
                    });
                    if owned {
                        unsafe {
                            PostThreadMessageW(
                                GetCurrentThreadId(),
                                HIDE_PANEL,
                                window as usize,
                                0,
                            );
                        }
                        hooks.f_down = true;
                        return true;
                    }
                }
                false
            });
            if consumed {
                return 1;
            }
        }
    }
    unsafe { CallNextHookEx(ptr::null_mut(), code, message, data) }
}

unsafe extern "system" fn mouse(code: i32, message: WPARAM, data: LPARAM) -> LRESULT {
    if code < 0 {
        return unsafe { CallNextHookEx(ptr::null_mut(), code, message, data) };
    }
    let _dpi = win::PhysicalDpi::enter();
    let event = unsafe { &*(data as *const MSLLHOOKSTRUCT) };
    let consumed = HOOKS.with(|cell| {
        let mut hooks = cell.borrow_mut();
        if message == WM_LBUTTONDOWN as usize && modifier(VK_MENU) && no_extra_modifiers() {
            let window =
                unsafe { GetAncestor(WindowFromPhysicalPoint(event.pt), GA_ROOT) } as isize;
            let owned = hooks.host.as_ref().is_some_and(|host| {
                host.panels.try_lock().is_ok_and(|panels| {
                    panels
                        .values()
                        .any(|p| p.window == window && win::marked(window, &p.title))
                })
            });
            if owned && let Some(bounds) = win::rect(window) {
                hooks.drag = Some(Drag {
                    window,
                    origin: event.pt,
                    bounds,
                });
                return true;
            }
        }
        if let Some(drag) = hooks.drag
            && (message == WM_MOUSEMOVE as usize || message == WM_LBUTTONUP as usize)
        {
            unsafe {
                SetWindowPos(
                    win::hwnd(drag.window),
                    ptr::null_mut(),
                    drag.bounds.x + event.pt.x - drag.origin.x,
                    drag.bounds.y + event.pt.y - drag.origin.y,
                    0,
                    0,
                    SWP_ASYNCWINDOWPOS | SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE,
                );
            }
            if message == WM_LBUTTONUP as usize {
                hooks.drag = None;
                return true;
            }
            // Passing moves through is essential: swallowing them freezes
            // the pointer and makes the panel snap back on the next event.
        }
        false
    });
    if consumed {
        1
    } else {
        unsafe { CallNextHookEx(ptr::null_mut(), code, message, data) }
    }
}

struct Hook(HHOOK);
impl Drop for Hook {
    fn drop(&mut self) {
        unsafe {
            UnhookWindowsHookEx(self.0);
        }
    }
}

fn run(arguments: &[String]) -> io::Result<()> {
    if arguments.len() != 4 {
        return Err(io::Error::other(
            "Expected pipeName, stateRoot, modulePath and pwshPath.",
        ));
    }
    let pipe_name = &arguments[0];
    if pipe_name.is_empty() || pipe_name.contains(['\\', '/', '\0']) {
        return Err(io::Error::other("Invalid pipe name."));
    }
    let singleton = win::Handle(unsafe {
        CreateMutexW(
            ptr::null(),
            1,
            win::wide(&format!("Local\\{pipe_name}")).as_ptr(),
        )
    });
    if singleton.0.is_null() {
        return Err(io::Error::last_os_error());
    }
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        return Ok(());
    }
    let host = Arc::new(Host {
        state: PathBuf::from(&arguments[1]),
        module: arguments[2].clone(),
        shell: arguments[3].clone(),
        panels: Mutex::new(HashMap::new()),
        stopping: AtomicBool::new(false),
    });
    fs::create_dir_all(&host.state)?;
    let _dpi = win::PhysicalDpi::enter();
    let message_thread = unsafe { GetCurrentThreadId() };
    unsafe {
        PeekMessageW(&mut MSG::default(), ptr::null_mut(), 0, 0, PM_NOREMOVE);
    }
    HOOKS.with(|state| state.borrow_mut().host = Some(host.clone()));
    let _keyboard = Hook(win::install_hook(WH_KEYBOARD_LL, Some(keyboard))?);
    let _mouse = Hook(win::install_hook(WH_MOUSE_LL, Some(mouse))?);
    let info_path = host.state.join("host.json");
    fs::write(
        &info_path,
        serde_json::to_vec(
            &serde_json::json!({"pid":std::process::id(), "pipeName":pipe_name,"backend":"rust","version":version()}),
        )?,
    )?;
    let server_host = host.clone();
    let pipe_name = pipe_name.clone();
    let server = thread::spawn(move || {
        if let Err(error) = ipc::serve(&pipe_name, server_host.clone(), message_thread) {
            server_host.log(&error.to_string());
            unsafe {
                PostThreadMessageW(message_thread, WM_QUIT, 1, 0);
            }
            return Err(error);
        }
        Ok(())
    });
    let timer = unsafe { SetTimer(ptr::null_mut(), MAINTENANCE, 2000, None) };
    let mut message = MSG::default();
    let message_result = loop {
        let result = unsafe { GetMessageW(&mut message, ptr::null_mut(), 0, 0) };
        if result <= 0 {
            break result;
        }
        if message.message == HIDE_PANEL {
            host.hide_window(message.wParam as isize);
        } else if message.message == WM_TIMER {
            host.recover_orphans();
        } else {
            unsafe {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    };
    host.stopping.store(true, Ordering::Relaxed);
    unsafe {
        KillTimer(ptr::null_mut(), timer);
    }
    let server_result = server
        .join()
        .map_err(|_| io::Error::other("IPC thread panicked."));
    host.reveal_all();
    HOOKS.with(|state| *state.borrow_mut() = HookState::default());
    let _ = fs::remove_file(info_path);
    unsafe {
        ReleaseMutex(singleton.0);
    }
    server_result??;
    if message_result < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn main() -> ExitCode {
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    if arguments.as_slice() == ["--version"] {
        println!("wttools-host {} (Rust)", version());
        return ExitCode::SUCCESS;
    }
    match run(&arguments) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            if let Some(state) = arguments.get(1) {
                let _ = fs::create_dir_all(state);
                if let Ok(mut log) = OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(Path::new(state).join("host.log"))
                {
                    let _ = writeln!(log, "{error}");
                }
            }
            ExitCode::FAILURE
        }
    }
}
