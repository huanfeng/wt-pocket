//! Managed Windows Terminal key binding that leaves focus mode (`setFocusMode`
//! false) so orphaned panels get their title bar back. WT has no command-line
//! equivalent, and its settings are JSONC, so the entries are spliced in as text
//! between marker comments instead of re-serializing the user's file.
const ID: &str = "User.WTPocket.ExitFocus";
pub const KEYS: &str = "ctrl+shift+alt+f24";
const BEGIN: &str = "/* >>> wtpocket >>> */";
const END: &str = "/* <<< wtpocket <<< */";

/// Byte offset just past the `[` of a top-level array property, plus the offset
/// just past the root object's `{`.
fn locate(text: &str, key: &str) -> (Option<usize>, Option<usize>) {
    let bytes = text.as_bytes();
    let (mut i, mut depth) = (0, 0usize);
    let (mut root, mut found) = (None, None);
    let mut expect_key = false;
    while i < bytes.len() {
        match bytes[i] {
            b'/' if bytes.get(i + 1) == Some(&b'/') => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
                continue;
            }
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                i += 2;
                while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                    i += 1;
                }
                i += 2;
                continue;
            }
            b'"' => {
                let start = i + 1;
                i += 1;
                while i < bytes.len() && bytes[i] != b'"' {
                    i += if bytes[i] == b'\\' { 2 } else { 1 };
                }
                if depth == 1 && expect_key && text.get(start..i) == Some(key) {
                    let mut j = i + 1;
                    let skip = |j: &mut usize| {
                        while *j < bytes.len() && bytes[*j].is_ascii_whitespace() {
                            *j += 1;
                        }
                    };
                    skip(&mut j);
                    if bytes.get(j) == Some(&b':') {
                        j += 1;
                        skip(&mut j);
                        if bytes.get(j) == Some(&b'[') {
                            found = Some(j + 1);
                        }
                    }
                }
                expect_key = false;
            }
            b'{' => {
                depth += 1;
                if depth == 1 && root.is_none() {
                    root = Some(i + 1);
                }
                expect_key = depth == 1;
            }
            b'[' => depth += 1,
            b'}' | b']' => depth = depth.saturating_sub(1),
            b',' => expect_key = depth == 1,
            _ => {}
        }
        i += 1;
    }
    (found, root)
}

/// True when the next token after `at`, skipping whitespace and comments, is
/// not the closing `]` (so a separator comma is needed after our entry).
fn has_following_item(text: &str, at: usize) -> bool {
    let bytes = text.as_bytes();
    let mut i = at;
    while i < bytes.len() {
        match bytes[i] {
            b if b.is_ascii_whitespace() => i += 1,
            b'/' if bytes.get(i + 1) == Some(&b'/') => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
            }
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                i += 2;
                while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                    i += 1;
                }
                i += 2;
            }
            b']' => return false,
            _ => return true,
        }
    }
    false
}

fn insert_at(text: &mut String, at: usize, entry: &str) {
    // Windows Terminal rejects a comma before `]`, so only separate real neighbours.
    let comma = if has_following_item(text, at) {
        ","
    } else {
        ""
    };
    text.insert_str(at, &format!(" {BEGIN} {entry}{comma} {END}"));
}

/// Returns the settings text with the managed binding added or refreshed.
pub fn add(text: &str) -> Result<String, String> {
    let mut text = remove(text);
    let action = format!(
        r#"{{ "command": {{ "action": "setFocusMode", "isFocusMode": false }}, "id": "{ID}" }}"#
    );
    let binding = format!(r#"{{ "id": "{ID}", "keys": "{KEYS}" }}"#);
    for (key, entry) in [("keybindings", binding), ("actions", action)] {
        // Insert the later array first so earlier offsets stay valid.
        match locate(&text, key) {
            (Some(at), _) => insert_at(&mut text, at, &entry),
            (None, Some(root)) => {
                let list = format!(r#""{key}": [{BEGIN} {entry} {END}],"#);
                text.insert_str(root, &format!(" {list}"));
            }
            (None, None) => return Err("settings.json is not a JSON object.".into()),
        }
    }
    Ok(text)
}

/// Removes every managed block, leaving user content untouched.
pub fn remove(text: &str) -> String {
    let mut result = text.to_string();
    while let Some(begin) = result.find(BEGIN) {
        let Some(end) = result[begin..].find(END) else {
            break;
        };
        let mut start = begin;
        let mut stop = begin + end + END.len();
        // A property we created for a missing key is removed whole.
        for key in ["actions", "keybindings"] {
            let wrapper = format!("\"{key}\": [");
            if result[..begin].ends_with(&wrapper) && result[stop..].starts_with("],") {
                start = begin - wrapper.len();
                stop += 2;
            }
        }
        // Drop the single separator space insert_at/add put in front.
        if result[..start].ends_with(' ') {
            start -= 1;
        }
        result.replace_range(start..stop, "");
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const WITH_ARRAYS: &str = "{\n  // comment with \"actions\": [ and { braces\n  \"actions\": [],\n  \"keybindings\": [\n    { \"id\": \"Terminal.CopyToClipboard\", \"keys\": \"ctrl+c\" }\n  ],\n  \"profiles\": { \"actions\": [ 1 ] }\n}\n";

    #[test]
    fn adds_to_existing_arrays_and_round_trips() {
        let added = add(WITH_ARRAYS).unwrap();
        assert_eq!(added.matches(ID).count(), 2);
        assert!(added.contains(KEYS));
        // The nested profiles.actions and the comment are not touched.
        assert!(added.contains("\"profiles\": { \"actions\": [ 1 ] }"));
        assert_eq!(remove(&added), WITH_ARRAYS);
    }

    #[test]
    fn adding_twice_is_idempotent() {
        let once = add(WITH_ARRAYS).unwrap();
        assert_eq!(add(&once).unwrap(), once);
    }

    #[test]
    fn creates_missing_arrays_and_removes_them_again() {
        let source = "{\n  \"defaultProfile\": \"x\"\n}\n";
        let added = add(source).unwrap();
        assert!(added.contains("\"actions\": [") && added.contains("\"keybindings\": ["));
        assert_eq!(remove(&added), source);
    }

    #[test]
    fn rejects_non_objects() {
        assert!(add("[1, 2]").is_err());
    }

    /// Strict JSON once comments are removed: Windows Terminal rejects trailing commas.
    fn strict(text: &str) -> serde_json::Value {
        let mut out = String::new();
        let mut rest = text;
        while let Some(start) = rest.find("/*") {
            out.push_str(&rest[..start]);
            let end = rest[start..].find("*/").unwrap() + start + 2;
            rest = &rest[end..];
        }
        out.push_str(rest);
        let lines: Vec<&str> = out
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .collect();
        let joined = lines.join("\n");
        serde_json::from_str(&joined).unwrap_or_else(|e| panic!("{e}: {joined}"))
    }

    #[test]
    fn result_is_strict_json_for_empty_populated_and_missing_arrays() {
        for source in [
            WITH_ARRAYS,
            "{ \"actions\": [], \"keybindings\": [] }",
            "{ \"actions\": [ ], \"keybindings\": [\n // none\n ] }",
            "{ \"actions\": [ { \"id\": \"a\" } ] }",
            "{\n  \"defaultProfile\": \"x\"\n}\n",
        ] {
            let added = add(source).unwrap();
            let value = strict(&added);
            let actions = value["actions"].as_array().unwrap();
            assert_eq!(actions.iter().filter(|a| a["id"] == ID).count(), 1);
            let keys = value["keybindings"].as_array().unwrap();
            assert_eq!(keys.iter().filter(|k| k["keys"] == KEYS).count(), 1);
            assert_eq!(remove(&added), source);
        }
    }
}
