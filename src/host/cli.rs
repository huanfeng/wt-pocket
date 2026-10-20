//! Argument parsing and dispatch for the management commands.
use crate::{
    client::{self, OpenArgs},
    install::{self, Options, TerminalSettings},
    paths::Layout,
    restore,
    update::{self, Update},
    version, win,
};
use std::{io, path::PathBuf};

pub fn usage() -> String {
    let body = t!(
        "\
Usage: wtpocket <command> [options]   (short form: wtp)

Commands:
  open [DIR]     Show or hide the panel for the current terminal (default: current directory)
  run CMD [ARGS] Run a program (e.g. claude) so Alt+F works while it runs
  stop           Stop the background host; panels are revealed and keep running
  restore (r)    Pick recently closed tabs (by directory) and reopen them; --list only prints them
  update         Install the latest release (--version vX.Y.Z for a specific one, --force to reinstall)
  install        Install this package and enable it for new PowerShell sessions
  uninstall      Disable WTPocket for new shells; installed files are kept
  version        Print the version

Options (install, uninstall, update, open, stop):
  --state DIR              State directory (default: Documents\\PowerShell\\wttools)
  --destination DIR        Install directory (default: <state>\\app)
  --profile FILE           PowerShell profile to edit (default: Microsoft.PowerShell_profile.ps1)
  --no-terminal-settings   Do not touch Windows Terminal's settings.json
  --terminal-settings FILE Edit this settings file instead of the detected ones (repeatable)
  --no-stop                (update) Keep the running host
",
        "\
用法：wtpocket <命令> [选项]   （简写：wtp）

命令：
  open [目录]    显示或隐藏当前终端的 Panel（默认使用当前目录）
  run 命令 [参数] 运行程序（如 claude），运行期间 Alt+F 仍然可用
  stop           停止后台程序；Panel 会被显示出来并继续运行
  restore (r)    选择最近关闭的标签页（按目录）并重新打开；--list 只列出不打开
  update         安装最新版本（--version vX.Y.Z 指定版本，--force 重新安装）
  install        安装当前安装包，并为新的 PowerShell 会话启用
  uninstall      为新的 Shell 停用 WTPocket；已安装的文件会保留
  version        显示版本

选项（install、uninstall、update、open、stop）：
  --state 目录              状态目录（默认：Documents\\PowerShell\\wttools）
  --destination 目录        安装目录（默认：<state>\\app）
  --profile 文件            要修改的 PowerShell 配置（默认：Microsoft.PowerShell_profile.ps1）
  --no-terminal-settings    不改动 Windows Terminal 的 settings.json
  --terminal-settings 文件  改为修改指定的设置文件，不自动检测（可重复）
  --no-stop                 （update）保留运行中的后台程序
"
    );
    format!("{body}\n{}\n", crate::install::hotkey_help())
}

#[derive(Default)]
struct Parsed {
    positional: Vec<String>,
    state: Option<PathBuf>,
    destination: Option<PathBuf>,
    profile: Option<PathBuf>,
    session: Option<String>,
    source_window: Option<isize>,
    pwsh: Option<PathBuf>,
    version: Option<String>,
    terminal_files: Vec<PathBuf>,
    skip_terminal: bool,
    force: bool,
    no_stop: bool,
    list: bool,
    select: Option<String>,
    wt_exe: Option<PathBuf>,
}

fn parse(args: &[String]) -> Result<Parsed, String> {
    let mut parsed = Parsed::default();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        let mut value = |name: &str| {
            iter.next()
                .cloned()
                .ok_or_else(|| format!("{name} requires a value."))
        };
        match arg.as_str() {
            "--state" => parsed.state = Some(value("--state")?.into()),
            "--destination" => parsed.destination = Some(value("--destination")?.into()),
            "--profile" => parsed.profile = Some(value("--profile")?.into()),
            "--session" => parsed.session = Some(value("--session")?),
            // Hidden: tests use it to pick the source window instead of the focused one.
            "--source-window" => {
                parsed.source_window = Some(
                    value("--source-window")?
                        .parse()
                        .map_err(|_| "--source-window must be a window handle number.")?,
                )
            }
            "--pwsh" => parsed.pwsh = Some(value("--pwsh")?.into()),
            "--version" => parsed.version = Some(value("--version")?),
            "--terminal-settings" => parsed
                .terminal_files
                .push(value("--terminal-settings")?.into()),
            "--no-terminal-settings" => parsed.skip_terminal = true,
            "--force" => parsed.force = true,
            "--no-stop" => parsed.no_stop = true,
            "--list" => parsed.list = true,
            // Hidden: pick sessions without the interactive list, and choose the wt executable.
            "--select" => parsed.select = Some(value("--select")?),
            "--wt-exe" => parsed.wt_exe = Some(value("--wt-exe")?.into()),
            other if other.starts_with("--") => {
                return Err(t!("Unknown option '{other}'.", "未知选项 '{other}'。"));
            }
            _ => parsed.positional.push(arg.clone()),
        }
    }
    Ok(parsed)
}

impl Parsed {
    fn layout(&self) -> Result<Layout, String> {
        let mut layout = Layout::default_user().map_err(|e| e.to_string())?;
        if let Some(state) = &self.state {
            layout.destination = state.join("app");
            layout.state = state.clone();
        }
        if let Some(destination) = &self.destination {
            layout.destination = destination.clone();
        }
        if let Some(profile) = &self.profile {
            layout.profile = profile.clone();
        }
        Ok(layout)
    }

    fn options(&self) -> Result<Options, String> {
        let layout = self.layout()?;
        Ok(Options {
            destination: layout.destination,
            profile: layout.profile,
            state: layout.state,
            terminal_settings: if self.skip_terminal {
                TerminalSettings::Skip
            } else if !self.terminal_files.is_empty() {
                TerminalSettings::Files(self.terminal_files.clone())
            } else {
                TerminalSettings::Detect
            },
        })
    }

    /// The options a spawned installer needs to behave like this process would.
    fn install_args(&self) -> Result<Vec<String>, String> {
        let options = self.options()?;
        let mut args = vec![
            "--state".into(),
            options.state.to_string_lossy().into_owned(),
            "--destination".into(),
            options.destination.to_string_lossy().into_owned(),
            "--profile".into(),
            options.profile.to_string_lossy().into_owned(),
        ];
        match options.terminal_settings {
            TerminalSettings::Skip => args.push("--no-terminal-settings".into()),
            TerminalSettings::Files(files) => {
                for file in files {
                    args.push("--terminal-settings".into());
                    args.push(file.to_string_lossy().into_owned());
                }
            }
            TerminalSettings::Detect => {}
        }
        Ok(args)
    }
}

pub fn run(command: &str, args: &[String]) -> Result<(), String> {
    // Capture the focused terminal before anything can change focus.
    let source_window = win::foreground();
    let parsed = parse(args)?;
    let mut out = io::stdout();
    match command {
        "open" => {
            let directory = match parsed.positional.first() {
                Some(dir) => PathBuf::from(dir),
                None => std::env::current_dir().map_err(|e| e.to_string())?,
            };
            client::open(&OpenArgs {
                state: parsed.layout()?.state,
                directory,
                session: parsed.session.unwrap_or_default(),
                pwsh: parsed.pwsh,
                source_window: parsed.source_window.unwrap_or(source_window),
            })
        }
        "stop" => {
            if client::stop(&parsed.layout()?.state)? {
                println!(
                    "{}",
                    t!(
                        "Stopped the WTPocket host. Panels were revealed and keep running.",
                        "已停止 WTPocket 后台程序。Panel 已显示，其中的 Shell 继续运行。"
                    )
                );
            } else {
                let rescued = client::rescue_stranded();
                if rescued > 0 {
                    println!(
                        "{}",
                        t!(
                            "The WTPocket host is not running. Released {rescued} hidden panel(s) it left behind.",
                            "WTPocket 后台程序未运行。已释放它遗留的 {rescued} 个隐藏 Panel。"
                        )
                    );
                } else {
                    println!(
                        "{}",
                        t!(
                            "The WTPocket host is not running.",
                            "WTPocket 后台程序未运行。"
                        )
                    );
                }
            }
            Ok(())
        }
        "restore" | "r" => restore::run(
            &restore::Args {
                state: parsed.layout()?.state,
                list: parsed.list,
                select: parsed.select.clone(),
                wt_exe: parsed.wt_exe.clone(),
            },
            &mut out,
        ),
        "install" => install::install(&parsed.options()?, &mut out).map(drop),
        "uninstall" => {
            let options = parsed.options()?;
            let _ = client::stop(&options.state);
            install::uninstall(&options, &mut out)
        }
        "update" => {
            let layout = parsed.layout()?;
            update::run(
                &Update {
                    version: parsed.version.clone(),
                    force: parsed.force,
                    no_stop: parsed.no_stop,
                    state: &layout.state,
                    install_args: parsed.install_args()?,
                },
                version(),
                &mut out,
            )
        }
        other => Err(format!(
            "{}\n\n{}",
            t!("Unknown command '{other}'.", "未知命令 '{other}'。"),
            usage()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn parses_options_and_positionals() {
        let parsed = parse(&args(&[
            "C:\\dir",
            "--state",
            "S",
            "--force",
            "--terminal-settings",
            "a",
            "--terminal-settings",
            "b",
        ]))
        .unwrap();
        assert_eq!(parsed.positional, ["C:\\dir"]);
        assert_eq!(parsed.state.as_deref(), Some(std::path::Path::new("S")));
        assert!(parsed.force && parsed.terminal_files.len() == 2);
    }

    #[test]
    fn rejects_unknown_options_and_missing_values() {
        assert!(parse(&args(&["--bogus"])).is_err());
        assert!(parse(&args(&["--state"])).is_err());
    }

    #[test]
    fn state_implies_the_app_directory_unless_overridden() {
        let layout = parse(&args(&["--state", "X"])).unwrap().layout().unwrap();
        assert_eq!(layout.destination, PathBuf::from("X").join("app"));
        let layout = parse(&args(&["--state", "X", "--destination", "Y"]))
            .unwrap()
            .layout()
            .unwrap();
        assert_eq!(layout.destination, PathBuf::from("Y"));
    }
}
