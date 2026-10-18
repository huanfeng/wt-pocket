//! Output language: Chinese when the Windows display language is Chinese,
//! English otherwise. `WTPOCKET_LANG=en|zh` overrides the detection.
use std::sync::OnceLock;
use windows_sys::Win32::Globalization::GetUserDefaultUILanguage;

const LANG_CHINESE: u16 = 0x04;

fn detect() -> bool {
    if let Ok(value) = std::env::var("WTPOCKET_LANG") {
        let value = value.trim().to_ascii_lowercase();
        if value.starts_with("zh") {
            return true;
        }
        if value.starts_with("en") {
            return false;
        }
    }
    unsafe { GetUserDefaultUILanguage() & 0x3ff == LANG_CHINESE }
}

pub fn zh() -> bool {
    static ZH: OnceLock<bool> = OnceLock::new();
    *ZH.get_or_init(detect)
}

/// `t!("English {x}", "中文 {x}", args...)` formats the text for the output language.
macro_rules! t {
    ($en:literal, $zh:literal $(, $arg:expr)* $(,)?) => {
        if $crate::i18n::zh() {
            format!($zh $(, $arg)*)
        } else {
            format!($en $(, $arg)*)
        }
    };
}
