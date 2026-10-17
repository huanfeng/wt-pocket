//! Win32 boundary. HWNDs cross threads as integer identities, never owned pointers.
use crate::model::{Bounds, center};
use std::{ffi::c_void, io, mem::size_of, ptr};
use windows_sys::Win32::{
    Foundation::*,
    Graphics::Gdi::*,
    System::{Com::CoCreateGuid, LibraryLoader::GetModuleHandleW, Threading::*},
    UI::{HiDpi::*, WindowsAndMessaging::*},
};

pub fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}
pub fn hwnd(window: isize) -> HWND {
    window as HWND
}

pub struct Handle(pub HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

/// Restores the caller's context even on early returns. Hooks must use physical pixels.
pub struct PhysicalDpi(*mut c_void);
impl PhysicalDpi {
    pub fn enter() -> Self {
        Self(unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) })
    }
}
impl Drop for PhysicalDpi {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                SetThreadDpiAwarenessContext(self.0);
            }
        }
    }
}

pub fn rect(window: isize) -> Option<Bounds> {
    let mut rect = RECT::default();
    if unsafe { GetWindowRect(hwnd(window), &mut rect) } == 0 {
        return None;
    }
    Some(Bounds {
        x: rect.left,
        y: rect.top,
        width: rect.right - rect.left,
        height: rect.bottom - rect.top,
    })
}

fn work_area(window: isize) -> Option<Bounds> {
    let mut info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    if unsafe {
        GetMonitorInfoW(
            MonitorFromWindow(hwnd(window), MONITOR_DEFAULTTONEAREST),
            &mut info,
        )
    } == 0
    {
        return None;
    }
    let r = info.rcWork;
    Some(Bounds {
        x: r.left,
        y: r.top,
        width: r.right - r.left,
        height: r.bottom - r.top,
    })
}

pub fn initial_bounds(source: isize) -> Result<Bounds, String> {
    let _dpi = PhysicalDpi::enter();
    let parent = rect(source).ok_or("Cannot read the source terminal bounds.")?;
    let work = work_area(source).ok_or("Cannot read the source monitor work area.")?;
    Ok(center(parent, work))
}

pub fn is_window(window: isize) -> bool {
    unsafe { IsWindow(hwnd(window)) != 0 }
}
pub fn visible(window: isize) -> bool {
    unsafe { IsWindowVisible(hwnd(window)) != 0 }
}
pub fn foreground() -> isize {
    unsafe { GetForegroundWindow() as isize }
}
pub fn reveal(window: isize) {
    unsafe {
        ShowWindow(hwnd(window), SW_SHOW);
    }
}

pub fn is_terminal(window: isize) -> bool {
    if !is_window(window) {
        return false;
    }
    let mut pid = 0;
    unsafe {
        GetWindowThreadProcessId(hwnd(window), &mut pid);
    }
    let process = Handle(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) });
    if process.0.is_null() {
        return false;
    }
    let mut buffer = vec![0u16; 32768];
    let mut length = buffer.len() as u32;
    if unsafe { QueryFullProcessImageNameW(process.0, 0, buffer.as_mut_ptr(), &mut length) } == 0 {
        return false;
    }
    String::from_utf16_lossy(&buffer[..length as usize])
        .rsplit('\\')
        .next()
        .is_some_and(|name| name.eq_ignore_ascii_case("WindowsTerminal.exe"))
}

pub fn mark(window: isize, title: &str) -> Result<(), String> {
    if unsafe { SetPropW(hwnd(window), wide(title).as_ptr(), 1isize as HANDLE) } == 0 {
        return Err(io::Error::last_os_error().to_string());
    }
    Ok(())
}
pub fn marked(window: isize, title: &str) -> bool {
    unsafe { GetPropW(hwnd(window), wide(title).as_ptr()) as isize == 1 }
}
pub fn unmark(window: isize, title: &str) {
    unsafe {
        RemovePropW(hwnd(window), wide(title).as_ptr());
    }
}

pub fn show(window: isize, bounds: Bounds) {
    let _dpi = PhysicalDpi::enter();
    let Some(work) = work_area(window) else {
        return;
    };
    let b = bounds.fit(work);
    unsafe {
        ShowWindow(hwnd(window), SW_RESTORE);
        SetWindowPos(
            hwnd(window),
            ptr::null_mut(),
            b.x,
            b.y,
            b.width,
            b.height,
            SWP_SHOWWINDOW,
        );
    }
    focus(window);
}

pub fn hide(window: isize, source: isize) -> Option<Bounds> {
    let _dpi = PhysicalDpi::enter();
    let saved = rect(window);
    unsafe {
        ShowWindow(hwnd(window), SW_HIDE);
    }
    if is_window(source) {
        focus(source);
    }
    saved
}

pub fn focus(window: isize) {
    unsafe {
        if SetForegroundWindow(hwnd(window)) != 0 {
            return;
        }
        PeekMessageW(&mut MSG::default(), ptr::null_mut(), 0, 0, PM_NOREMOVE);
        let current = GetCurrentThreadId();
        let foreground = GetWindowThreadProcessId(GetForegroundWindow(), ptr::null_mut());
        let attached = foreground != 0
            && foreground != current
            && AttachThreadInput(current, foreground, 1) != 0;
        SetForegroundWindow(hwnd(window));
        if attached {
            AttachThreadInput(current, foreground, 0);
        }
    }
}

pub fn find_panel(title: &str) -> isize {
    struct Search<'a> {
        title: &'a str,
        found: isize,
    }
    unsafe extern "system" fn visit(window: HWND, data: LPARAM) -> i32 {
        // EnumWindows invokes this synchronously while Search remains alive.
        let search = unsafe { &mut *(data as *mut Search<'_>) };
        let mut text = [0u16; 1024];
        let length = unsafe { GetWindowTextW(window, text.as_mut_ptr(), text.len() as i32) };
        if String::from_utf16_lossy(&text[..length as usize]).contains(search.title)
            && is_terminal(window as isize)
        {
            search.found = window as isize;
            return 0;
        }
        1
    }
    let mut search = Search { title, found: 0 };
    unsafe {
        EnumWindows(Some(visit), &mut search as *mut _ as isize);
    }
    search.found
}

pub fn unique_title() -> Result<String, String> {
    let mut guid = windows_sys::core::GUID::from_u128(0);
    if unsafe { CoCreateGuid(&mut guid) } < 0 {
        return Err("Cannot generate a panel identifier.".into());
    }
    Ok(format!("wttools Panel · {:08x}", guid.data1))
}

pub fn install_hook(kind: i32, callback: HOOKPROC) -> io::Result<HHOOK> {
    let hook = unsafe { SetWindowsHookExW(kind, callback, GetModuleHandleW(ptr::null()), 0) };
    if hook.is_null() {
        Err(io::Error::last_os_error())
    } else {
        Ok(hook)
    }
}
