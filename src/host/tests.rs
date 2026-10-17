//! Real callback tests with disposable native windows; no input is injected.
use super::*;
use windows_sys::Win32::{Graphics::Gdi::*, UI::HiDpi::*};

#[test]
fn drag_moves_pass_through_and_release_ends_drag() {
    HOOKS.with(|s| {
        s.borrow_mut().drag = Some(Drag {
            window: 0,
            origin: POINT::default(),
            bounds: Bounds {
                x: 0,
                y: 0,
                width: 1,
                height: 1,
            },
        })
    });
    for (x, y) in [(200, 300), (400, 500), (-100, 500)] {
        let event = MSLLHOOKSTRUCT {
            pt: POINT { x, y },
            ..Default::default()
        };
        assert_eq!(
            unsafe { mouse(0, WM_MOUSEMOVE as usize, &event as *const _ as isize) },
            0
        );
        assert!(HOOKS.with(|s| s.borrow().drag.is_some()));
    }
    let event = MSLLHOOKSTRUCT::default();
    assert_eq!(
        unsafe { mouse(0, WM_LBUTTONUP as usize, &event as *const _ as isize) },
        1
    );
    assert!(HOOKS.with(|s| s.borrow().drag.is_none()));
    assert_eq!(
        unsafe { mouse(0, WM_MOUSEMOVE as usize, &event as *const _ as isize) },
        0
    );
    assert_eq!(unsafe { mouse(-1, WM_MOUSEMOVE as usize, 0) }, 0);
}

#[test]
fn keyboard_release_and_repeats_do_not_leak_to_the_owner() {
    HOOKS.with(|s| s.borrow_mut().f_down = true);
    let event = KBDLLHOOKSTRUCT {
        vkCode: b'F' as u32,
        ..Default::default()
    };
    assert_eq!(
        unsafe { keyboard(0, WM_SYSKEYDOWN as usize, &event as *const _ as isize) },
        1
    );
    assert_eq!(
        unsafe { keyboard(0, WM_SYSKEYUP as usize, &event as *const _ as isize) },
        1
    );
    assert!(!HOOKS.with(|s| s.borrow().f_down));
    assert_eq!(
        unsafe { keyboard(0, WM_SYSKEYUP as usize, &event as *const _ as isize) },
        0
    );
    assert_eq!(unsafe { keyboard(-1, WM_SYSKEYUP as usize, 0) }, 0);
}

struct Window(HWND);
impl Drop for Window {
    fn drop(&mut self) {
        unsafe {
            DestroyWindow(self.0);
        }
    }
}

#[test]
#[ignore = "requires desktop monitors; run tests/Drag.Dpi.Tests.ps1 locally"]
fn dpi_drag_uses_physical_pixels_on_each_monitor_and_restores_caller() {
    unsafe extern "system" fn monitor(
        monitor: HMONITOR,
        _: HDC,
        _: *mut RECT,
        data: LPARAM,
    ) -> i32 {
        let areas = unsafe { &mut *(data as *mut Vec<RECT>) };
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if unsafe { GetMonitorInfoW(monitor, &mut info) } != 0 {
            areas.push(info.rcWork);
        }
        1
    }
    let _dpi = win::PhysicalDpi::enter();
    let mut areas = Vec::<RECT>::new();
    unsafe {
        EnumDisplayMonitors(
            ptr::null_mut(),
            ptr::null(),
            Some(monitor),
            &mut areas as *mut _ as isize,
        );
    }
    assert!(
        !areas.is_empty(),
        "No monitor available for disposable-window regression test"
    );
    for work in areas {
        let window = Window(unsafe {
            CreateWindowExW(
                WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                win::wide("BUTTON").as_ptr(),
                win::wide("WTPocket disposable DPI test").as_ptr(),
                WS_POPUP,
                work.left + 120,
                work.top + 120,
                240,
                180,
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null(),
            )
        });
        assert!(!window.0.is_null());
        let bounds = win::rect(window.0 as isize).unwrap();
        let origin = POINT {
            x: bounds.x + 100,
            y: bounds.y + 100,
        };
        let event = MSLLHOOKSTRUCT {
            pt: POINT {
                x: origin.x + 35,
                y: origin.y + 25,
            },
            ..Default::default()
        };
        for context in [
            DPI_AWARENESS_CONTEXT_UNAWARE,
            DPI_AWARENESS_CONTEXT_SYSTEM_AWARE,
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        ] {
            {
                let _physical = win::PhysicalDpi::enter();
                unsafe {
                    SetWindowPos(
                        window.0,
                        ptr::null_mut(),
                        bounds.x,
                        bounds.y,
                        0,
                        0,
                        SWP_NOZORDER | SWP_NOSIZE | SWP_NOACTIVATE,
                    );
                }
            }
            HOOKS.with(|s| {
                s.borrow_mut().drag = Some(Drag {
                    window: window.0 as isize,
                    origin,
                    bounds,
                })
            });
            let previous = unsafe { SetThreadDpiAwarenessContext(context) };
            let before = unsafe { GetThreadDpiAwarenessContext() };
            assert_eq!(
                unsafe { mouse(0, WM_MOUSEMOVE as usize, &event as *const _ as isize) },
                0
            );
            assert_ne!(
                unsafe { AreDpiAwarenessContextsEqual(before, GetThreadDpiAwarenessContext()) },
                0
            );
            unsafe {
                SetThreadDpiAwarenessContext(previous);
            }
            let actual = win::rect(window.0 as isize).unwrap();
            assert_eq!((actual.x, actual.y), (bounds.x + 35, bounds.y + 25));
        }
        HOOKS.with(|s| s.borrow_mut().drag = None);
        println!(
            "Physical drag verified at {},{} (DPI={}) under three caller contexts",
            work.left,
            work.top,
            unsafe { GetDpiForWindow(window.0) }
        );
    }
}
