//! The managed block in the PowerShell profile that loads the startup shim.
const BEGIN: &str = "# >>> wttools >>>";
const END: &str = "# <<< wttools <<<";

/// Single-quoted PowerShell literal. PowerShell also treats the curly single
/// quotes as delimiters, so every one of them is doubled.
pub fn quote(value: &str) -> String {
    let mut quoted = String::from("'");
    for c in value.chars() {
        if matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}') {
            quoted.push(c);
        }
        quoted.push(c);
    }
    quoted.push('\'');
    quoted
}

pub fn block(startup: &str, state: &str, newline: &str) -> String {
    let (startup, state) = (quote(startup), quote(state));
    [
        BEGIN.to_string(),
        "if ($env:WT_SESSION) {".into(),
        format!("    if ([IO.File]::Exists({startup})) {{"),
        "        try {".into(),
        format!("            . {startup} -StateRoot {state}"),
        "        } catch {".into(),
        r#"            Write-Warning "wtpocket failed to initialize: $_""#.into(),
        "        }".into(),
        "    } else {".into(),
        "        Write-Warning 'wtpocket is missing. Run the install command again to repair it.'"
            .into(),
        "    }".into(),
        "}".into(),
        END.to_string(),
    ]
    .join(newline)
}

fn bounds(text: &str) -> Option<(usize, usize)> {
    // The block starts at a line start and ends after its closing marker line.
    let begin = text
        .match_indices(BEGIN)
        .map(|(i, _)| i)
        .find(|&i| i == 0 || text.as_bytes()[i - 1] == b'\n')?;
    let end = begin + text[begin..].find(END)? + END.len();
    let after = &text[end..];
    let trailing = after
        .strip_prefix("\r\n")
        .map(|_| 2)
        .or_else(|| after.strip_prefix('\n').map(|_| 1))
        .unwrap_or(0);
    Some((begin, end + trailing))
}

fn newline_of(text: &str) -> &'static str {
    if text.contains('\n') && !text.contains("\r\n") {
        "\n"
    } else {
        "\r\n"
    }
}

/// Replaces the managed block, or appends one when absent.
pub fn upsert(text: &str, startup: &str, state: &str) -> String {
    let newline = newline_of(text);
    let block = block(startup, state, newline) + newline;
    match bounds(text) {
        Some((begin, end)) => format!("{}{}{}", &text[..begin], block, &text[end..]),
        None => {
            let separator = if text.is_empty() || text.ends_with('\n') {
                ""
            } else {
                newline
            };
            format!("{text}{separator}{block}")
        }
    }
}

pub fn remove(text: &str) -> String {
    match bounds(text) {
        Some((begin, end)) => format!("{}{}", &text[..begin], &text[end..]),
        None => text.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_doubles_every_powershell_quote() {
        assert_eq!(
            quote("a'b\u{2019}c\u{2018}"),
            "'a''b\u{2019}\u{2019}c\u{2018}\u{2018}'"
        );
    }

    #[test]
    fn upsert_appends_replaces_and_removes_without_touching_user_text() {
        let user = "Set-Alias x y\r\n";
        let first = upsert(user, r"C:\a\Startup.ps1", r"C:\s");
        assert!(
            first.starts_with(user) && first.contains(r". 'C:\a\Startup.ps1' -StateRoot 'C:\s'")
        );
        let second = upsert(&first, r"C:\b\Startup.ps1", r"C:\s");
        assert_eq!(second.matches(BEGIN).count(), 1);
        assert!(second.contains(r"C:\b\Startup.ps1") && !second.contains(r"C:\a\"));
        assert_eq!(remove(&second), user);
    }

    #[test]
    fn upsert_handles_empty_and_unterminated_profiles_and_lf_files() {
        assert!(upsert("", "S", "T").starts_with(BEGIN));
        let lf = upsert("echo hi", "S", "T");
        assert!(lf.starts_with("echo hi\r\n"));
        let unix = upsert("a\nb\n", "S", "T");
        assert!(!unix.contains('\r'));
        assert_eq!(remove(&unix), "a\nb\n");
    }

    #[test]
    fn replaces_a_block_written_by_the_previous_powershell_installer() {
        let old = "before\r\n# >>> wttools >>>\r\nif ($env:WT_SESSION) { old }\r\n# <<< wttools <<<\r\nafter\r\n";
        let updated = upsert(old, "S", "T");
        assert!(updated.starts_with("before\r\n") && updated.ends_with("after\r\n"));
        assert!(!updated.contains("old"));
    }
}
