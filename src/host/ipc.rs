//! Bounded byte-mode pipes, restricted to the current Windows user.
//! Nonblocking pipe operations keep connect/read/write cancellable without an
//! async runtime or a thread per client. Only one request is handled at a time.
use crate::{
    Host,
    model::Request,
    win::{Handle, wide},
};
use serde_json::json;
use std::{
    ffi::c_void,
    io,
    mem::size_of,
    ptr,
    sync::{Arc, atomic::Ordering},
    thread,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::*,
    Security::{Authorization::*, *},
    Storage::FileSystem::*,
    System::{Pipes::*, Threading::*},
    UI::WindowsAndMessaging::{PostThreadMessageW, WM_QUIT},
};

struct Security(*mut c_void);
impl Drop for Security {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0);
        }
    }
}

/// The current user's SID in string form (`S-1-5-...`).
pub fn current_user_sid() -> io::Result<String> {
    unsafe {
        let mut token = ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err(io::Error::last_os_error());
        }
        let token = Handle(token);
        let mut length = 0;
        GetTokenInformation(token.0, TokenUser, ptr::null_mut(), 0, &mut length);
        // usize storage provides alignment for TOKEN_USER and its inline SID.
        let mut buffer = vec![0usize; (length as usize).div_ceil(size_of::<usize>())];
        if GetTokenInformation(
            token.0,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            length,
            &mut length,
        ) == 0
        {
            return Err(io::Error::last_os_error());
        }
        let user = &*(buffer.as_ptr() as *const TOKEN_USER);
        let mut sid_text = ptr::null_mut();
        if ConvertSidToStringSidW(user.User.Sid, &mut sid_text) == 0 {
            return Err(io::Error::last_os_error());
        }
        let _sid_allocation = Security(sid_text.cast());
        let mut count = 0;
        while *sid_text.add(count) != 0 {
            count += 1;
        }
        Ok(String::from_utf16_lossy(std::slice::from_raw_parts(
            sid_text, count,
        )))
    }
}

fn current_user_security() -> io::Result<Security> {
    let sddl = wide(&format!("D:P(A;;GA;;;{})", current_user_sid()?));
    let mut descriptor = ptr::null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            ptr::null_mut(),
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(Security(descriptor))
}

fn read_request(pipe: HANDLE, host: &Host) -> Result<Vec<u8>, String> {
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut text = Vec::new();
    loop {
        if host.stopping.load(Ordering::Relaxed) {
            return Err("Host is stopping.".into());
        }
        if Instant::now() >= deadline {
            return Err("Client timed out.".into());
        }
        let mut available = 0;
        if unsafe {
            PeekNamedPipe(
                pipe,
                ptr::null_mut(),
                0,
                ptr::null_mut(),
                &mut available,
                ptr::null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error().to_string());
        }
        if available == 0 {
            thread::sleep(Duration::from_millis(5));
            continue;
        }
        let mut chunk = [0u8; 4096];
        let mut read = 0;
        if unsafe {
            ReadFile(
                pipe,
                chunk.as_mut_ptr(),
                available.min(chunk.len() as u32),
                &mut read,
                ptr::null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error().to_string());
        }
        for &byte in &chunk[..read as usize] {
            if byte == b'\n' {
                return Ok(text);
            }
            if text.len() >= 65536 {
                return Err("Request exceeds 64 KiB.".into());
            }
            text.push(byte);
        }
    }
}

pub fn serve(pipe_name: &str, host: Arc<Host>, message_thread: u32) -> io::Result<()> {
    let security = current_user_security()?;
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: security.0,
        bInheritHandle: 0,
    };
    let name = wide(&format!("\\\\.\\pipe\\{pipe_name}"));
    while !host.stopping.load(Ordering::Relaxed) {
        let pipe = Handle(unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                8192,
                8192,
                0,
                &attributes,
            )
        });
        if pipe.0 == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        loop {
            if host.stopping.load(Ordering::Relaxed) {
                return Ok(());
            }
            if unsafe { ConnectNamedPipe(pipe.0, ptr::null_mut()) } != 0 {
                break;
            }
            match unsafe { GetLastError() } {
                ERROR_PIPE_CONNECTED => break,
                ERROR_PIPE_LISTENING => thread::sleep(Duration::from_millis(10)),
                ERROR_NO_DATA => unsafe {
                    DisconnectNamedPipe(pipe.0);
                },
                _ => return Err(io::Error::last_os_error()),
            }
        }
        let result = read_request(pipe.0, &host)
            .and_then(|bytes| serde_json::from_slice::<Request>(&bytes).map_err(|e| e.to_string()));
        let mut shutdown = false;
        let result = result.and_then(|request| match request.action.as_str() {
            "shutdown" => {
                shutdown = true;
                Ok(())
            }
            "toggle" => host.toggle(request),
            _ => Err("Unknown action.".into()),
        });
        let response = match result {
            Ok(()) => json!({"ok":true}),
            Err(error) => {
                // Deserialization errors can echo client strings. Keep the
                // reply below the nonblocking pipe's output-buffer limit.
                let error: String = error.chars().take(1024).collect();
                host.log(&error);
                json!({"ok":false,"error":error})
            }
        };
        let line = format!("{response}\n");
        let mut written = 0;
        // Never wait for a stalled client to drain a pipe. The small response
        // fits in the output buffer; disconnecting only follows a successful write.
        unsafe {
            WriteFile(
                pipe.0,
                line.as_ptr(),
                line.len() as u32,
                &mut written,
                ptr::null_mut(),
            );
        }
        // Closing the server handle preserves buffered bytes for the connected
        // reader. DisconnectNamedPipe would discard them before it can read.
        drop(pipe);
        if shutdown {
            unsafe {
                PostThreadMessageW(message_thread, WM_QUIT, 0, 0);
            }
            return Ok(());
        }
    }
    Ok(())
}
