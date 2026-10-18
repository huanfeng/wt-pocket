use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Request {
    pub action: String,
    pub directory: String,
    pub source_window: i64,
    pub session_id: String,
}

impl Default for Request {
    fn default() -> Self {
        Self {
            action: "toggle".into(),
            directory: String::new(),
            source_window: 0,
            session_id: String::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Bounds {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl Bounds {
    pub fn fit(mut self, work: Bounds) -> Self {
        self.width = self.width.min(work.width).max(1);
        self.height = self.height.min(work.height).max(1);
        self.x = self.x.clamp(work.x, work.x + work.width - self.width);
        self.y = self.y.clamp(work.y, work.y + work.height - self.height);
        self
    }
}

pub fn center(parent: Bounds, work: Bounds) -> Bounds {
    let width = ((f64::from(parent.width) * 0.68) as i32).max(640);
    let height = ((f64::from(parent.height) * 0.60) as i32).max(360);
    let width = width.min(work.width).max(1);
    let height = height.min(work.height).max(1);
    Bounds {
        x: parent.x + (parent.width - width) / 2,
        y: parent.y + (parent.height - height) / 2,
        width,
        height,
    }
    .fit(work)
}

/// Builds the `-EncodedCommand` payload. The directory is embedded as Base64
/// UTF-8, an alphabet with no characters PowerShell treats as quotes (including
/// the curly ones), so it can never break out of the script.
pub fn bootstrap(directory: &str) -> String {
    let code = format!(
        "$env:WTTOOLS_PANEL = '1'; \
         foreach ($p in @($PROFILE.AllUsersAllHosts,$PROFILE.AllUsersCurrentHost,$PROFILE.CurrentUserAllHosts,$PROFILE.CurrentUserCurrentHost)) \
         {{ if (Test-Path -LiteralPath $p) {{ . $p }} }}; \
         Set-Location -LiteralPath ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{}')))",
        STANDARD.encode(directory)
    );
    STANDARD.encode(
        code.encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect::<Vec<_>>(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fits_small_negative_and_straddling_monitors() {
        for (parent, work) in [
            ([0, 0, 1920, 1080], [0, 0, 1920, 1040]),
            ([-1920, 0, 1920, 1080], [-1920, 0, 1920, 1040]),
            ([0, 0, 400, 250], [0, 0, 400, 230]),
            ([1500, -100, 1900, 1500], [1920, 0, 1920, 1080]),
        ] {
            let bounds = |b: [i32; 4]| Bounds {
                x: b[0],
                y: b[1],
                width: b[2],
                height: b[3],
            };
            let work = bounds(work);
            let result = center(bounds(parent), work);
            assert!(result.x >= work.x && result.y >= work.y);
            assert!(result.x + result.width <= work.x + work.width);
            assert!(result.y + result.height <= work.y + work.height);
            assert!(result.width > 0 && result.height > 0);
        }
    }

    #[test]
    fn request_protocol_preserves_session_and_defaults() {
        let request: Request =
            serde_json::from_str(r#"{"sourceWindow":123,"sessionId":"shell-1"}"#).unwrap();
        assert_eq!(request.action, "toggle");
        assert_eq!(request.source_window, 123);
        assert_eq!(request.session_id, "shell-1");
        assert!(serde_json::from_str::<Request>("null").is_err());
        assert!(serde_json::from_str::<Request>(r#"{"sourceWindow":"wrong"}"#).is_err());
    }

    #[test]
    fn bootstrap_embeds_the_directory_as_base64() {
        let path = "D:\\中文 a'b; $(throw 'injection') [x] `literal \u{2019}; calc; \u{2018}";
        let bytes = STANDARD.decode(bootstrap(path)).unwrap();
        let units: Vec<u16> = bytes
            .chunks(2)
            .map(|p| u16::from_le_bytes([p[0], p[1]]))
            .collect();
        let code = String::from_utf16(&units).unwrap();
        assert!(code.starts_with("$env:WTTOOLS_PANEL = '1';"));
        assert!(code.ends_with(&format!(
            "Set-Location -LiteralPath ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{}')))",
            STANDARD.encode(path)
        )));
        // Caller data must not appear in the script, so no quote can escape it.
        assert!(!code.contains("injection") && !code.contains("calc"));
        assert!(!code.contains(['\u{2018}', '\u{2019}', '\u{201A}', '\u{201B}']));
    }
}
