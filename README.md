# WTPocket

[![CI](https://github.com/huanfeng/wt-pocket/actions/workflows/ci.yml/badge.svg)](https://github.com/huanfeng/wt-pocket/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/huanfeng/wt-pocket)](https://github.com/huanfeng/wt-pocket/releases/latest)
[![MIT License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**A floating terminal for every Windows Terminal session.**

为 Windows Terminal 增加随叫随到的浮动 PowerShell 终端，并记住上次使用的目录。按 **Alt+F** 在当前目录打开 Panel，再按一次隐藏；运行中的程序继续执行。

无需修改或编译 Windows Terminal。每个 PowerShell 会话拥有独立 Panel，同一窗口的多个标签页或窗格可以分别使用。

## 安装

要求 **Windows 10/11、Windows Terminal 和 PowerShell 7.4+**。支持 Windows x64、ARM64；请在 PowerShell 7 的 `pwsh` 中运行，不使用 Windows PowerShell 5.1。

在 Windows Terminal 的 PowerShell 中执行：

```powershell
irm https://raw.githubusercontent.com/huanfeng/wt-pocket/main/install.ps1 | iex
```

安装脚本只负责下载适合当前系统架构的最新 Release、校验 SHA-256，然后运行包内的 `wtpocket.exe install`。WTPocket 是单个 Rust 原生程序加一个很小的 PowerShell 接入脚本，**无需额外安装 Rust、.NET Runtime、SDK 或 VC++ 运行库**，x64 压缩包约 **0.4 MB**。

安装后新开一个 PowerShell 标签页，按 **Alt+F**。安装器会先备份 PowerShell 配置，再添加带标记的接入代码；还会在 Windows Terminal 的 `settings.json` 里添加一个带标记的按键绑定（见下文“窗口残留与标题栏”），同样先备份。不添加登录启动项。

如果希望先检查脚本，再执行：

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/huanfeng/wt-pocket/main/install.ps1 -OutFile install.ps1
Get-Content ./install.ps1
pwsh -NoProfile -File ./install.ps1
```

指定版本安装，例如 `v0.3.0`：

```powershell
pwsh -NoProfile -File ./install.ps1 -Version v0.3.0
```

也可从 [Releases](https://github.com/huanfeng/wt-pocket/releases) 下载适合架构的 ZIP 和校验文件，核对 `Get-FileHash <压缩包> -Algorithm SHA256` 后解压，在解压目录中执行：

```powershell
./wtpocket.exe install
```

离线安装使用已构建的 Release ZIP，无需联网编译。校验文件用于检查下载完整性，不是代码签名。

## 命令

安装后，新开的 PowerShell 标签页里有 `wtpocket` 命令：

| 命令 | 作用 |
| --- | --- |
| `wtpocket open [目录]` | 显示或隐藏当前终端的 Panel，等同于 Alt+F；`目录` 只决定新 Panel 的初始目录 |
| `wtpocket stop` | 停止后台控制程序，显示仍存活的 Panel（不结束它们的 Shell） |
| `wtpocket update` | 检查并安装最新 Release；`--version vX.Y.Z` 指定版本，`--force` 强制重装 |
| `wtpocket uninstall` | 停用新 Shell 中的 WTPocket，保留安装文件、目录记忆和备份 |
| `wtpocket install` | 安装当前这份程序包（离线安装用） |
| `wtpocket version` | 显示版本 |

`install`、`uninstall`、`update` 支持 `--no-terminal-settings`（不改动 Windows Terminal 设置）以及 `--state`、`--destination`、`--profile` 指定非默认位置。

## 使用

| 操作 | 效果 |
| --- | --- |
| 在主终端提示符按 **Alt+F** | 首次在当前目录创建 Panel，之后显示或隐藏同一个 Panel |
| 在 Panel 内按 **Alt+F** | 隐藏 Panel，运行中的命令继续执行 |
| **Alt + 鼠标左键拖动** Panel 内容区 | 移动无标题栏窗口 |
| 正常关闭 Panel，再按 **Alt+F** | 根据主终端此时的目录创建新会话 |

Panel 使用 WT 焦点模式隐藏标题栏和标签栏，初始约为来源窗口宽度的 68%、高度的 60%，尺寸限制在显示器工作区内。重新显示时保留位置、大小、目录和运行状态，支持不同缩放比例的多显示器。

关联不依赖标签页标题：在 Panel 中新建或切换标签页、运行改变标题的程序，仍能显示或隐藏同一窗口。直接把标签页拖出成为另一窗口时，关联不会自动迁移。

### 窗口残留与标题栏

主窗口关闭后，其 Panel 不会留在不可见状态：约 2 秒内，后台会把它重新显示出来，解除与主窗口的关联，并恢复标题栏和标签栏，让它成为一个普通的 Windows Terminal 窗口。窗口里的 Shell 和命令继续运行，之后由你自行关闭。`wtpocket stop` 和卸载时也是同样处理。

Windows Terminal 没有命令行能让已存在的窗口退出焦点模式，只能通过按键绑定。因此安装器会在 `settings.json` 的 `actions` / `keybindings` 里添加一条带 `/* >>> wtpocket >>> */` 标记的绑定：`ctrl+shift+alt+f24` 触发 `setFocusMode: false`（键盘上没有 F24，不会与你的任何绑定冲突）。后台在释放 Panel 时，仅当该窗口确实获得了前台焦点，才向它发送这个组合键，因此不会误发给其他程序。卸载会移除这段标记内容；使用 `--no-terminal-settings` 安装则不改动设置，此时被释放的窗口会保持无标题栏状态。

如果多个标签页各开过 Panel 后一起关掉主窗口，这些 Panel 会同时显示，需要逐个关闭。

## 目录记忆

- 按 **WT Profile** 保存最后目录。同一 Profile 的多个普通终端共享记录，最近一次目录变更获胜。
- 新 Shell 从用户主目录启动时恢复记录；从资源管理器或 `wt -d` 指定其他目录启动时，保留指定目录。显式指定主目录与默认启动在主目录无法区分。
- Panel 不写入普通终端的目录记录，首次创建始终使用调用者的目录。
- 使用 PowerShell 的 `LocationChangedAction`，保留原有处理器，不替换 `prompt` 或 `cd`。

目录记忆不是完整会话恢复：重启电脑后不会恢复进程。当前版本也不修改 WT 的“＋”按钮行为。

## 更新与卸载

更新：

```powershell
wtpocket update
```

它会下载最新 Release、校验 SHA-256，运行新包的安装逻辑，并停止旧的后台控制程序（Panel 会被显示出来并解除关联，其中的 Shell 继续运行）。新版本在你下一次按 Alt+F 时自动启动。也可以重新执行上面的在线安装命令，效果相同，但需要手动运行 `wtpocket stop` 才会切换后台。

安装器把完整校验过的文件放进 `wttools/app/versions/<内容哈希>`，再切换 PowerShell 启动配置；相同内容重复安装会复用已有目录。即使旧的 `wtpocket.exe` 正被使用，也无需关闭终端即可安装。新开的标签页使用新版接入脚本；已有 Shell 和 Panel 继续使用原来的文件。配置备份、目录记录、旧安装文件都会保留，不自动清理旧版本，因为其他 Shell 仍可能使用它们。

从 v0.2.x 升级：新的安装会替换 PowerShell 配置里的接入块，旧版本目录保留。旧标签页里的 `Open-WtPanel` 等命令随旧 Shell 继续工作；新标签页改用 `wtpocket`。**v0.3.0 起 `Open-WtPanel`、`Enable-WtTools`、`Stop-WtTools` 被移除**，请改用 `wtpocket open` / `wtpocket stop`。

卸载：

```powershell
wtpocket uninstall
```

卸载移除 PowerShell 配置和 Windows Terminal 设置中的标记块，停止控制程序并显示 Panel，不关闭 Shell。安装文件、目录记忆和备份保留，方便恢复；新开的 Shell 不再启用 WTPocket。

默认安装目录为 PowerShell 用户配置目录下的 `wttools/app`，状态文件保存在其父目录 `wttools`。为兼容早期版本，目录名仍沿用 `wttools`；产品和 GitHub 仓库名称为 WTPocket / `wt-pocket`，无需手工重命名已有目录。

## 使用边界

- 主终端的 Alt+F 由 PSReadLine 处理，仅在 PowerShell 等待输入时生效；在主终端运行编辑器、SSH 等前台程序时不能呼出 Panel。Panel 内的 Alt+F 由控制程序处理，运行命令时也能隐藏。
- 目前支持本地 PowerShell 的文件系统目录，不支持 WSL、Git Bash、注册表目录。
- Panel 是独立 WT 窗口，不嵌入主终端，不跟随主窗口连续移动，也不强制全局置顶。
- 使用相同权限级别的终端；管理员 WT 与普通权限控制程序混用未验证。
- 若 WT 自身绑定了 Alt+F，需要移除该绑定。WTPocket 会覆盖当前 Shell 的 Alt+F；卸载后新开 Shell，由原配置恢复自定义绑定。
- 后台被强制结束（如任务管理器）时无法执行清理，隐藏的 Panel 会留在不可见状态。确认没有其他 WTPocket 进程在运行后，`wtpocket stop` 会找出这些遗留的隐藏 Panel，显示出来并恢复标题栏。

## 开发与验证

需要 PowerShell 7.4+，以及 **Rust 1.88+ MSVC 工具链、Visual Studio C++ Build Tools 与 Windows SDK**。后台静态链接 CRT，不需要 .NET SDK。

后台使用 `windows-sys`、`serde` / `serde_json`、`base64` 和 `sha2`，依赖版本锁定在 `Cargo.lock`；没有 GUI 或异步运行时框架。`update` 命令调用 Windows 自带的 `curl.exe` 和 `tar.exe`。Release 附带依赖及 Rust 标准库的许可声明。

```powershell
git clone https://github.com/huanfeng/wt-pocket.git
cd wt-pocket
pwsh -NoProfile -File ./scripts/Build.ps1
./artifacts/host/wtpocket.exe install
```

默认构建当前机器架构。交叉构建 ARM64 还需对应的 Rust target 和 Visual Studio ARM64 工具；CI/Release 分别在 x64、ARM64 Windows 机器上原生构建和测试。

本机打包可执行 `./scripts/Package.ps1 -Version 0.3.0 -Runtime win-x64`。生成许可声明需要 `rustup component add rust-docs`；这只影响开发机打包，不是用户安装依赖。

自动检查不依赖 Pester：

```powershell
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
pwsh -NoProfile -File ./tests/Smoke.Tests.ps1
pwsh -NoProfile -File ./tests/Cli.Tests.ps1
pwsh -NoProfile -File ./tests/Startup.Tests.ps1
pwsh -NoProfile -File ./tests/Backend.Migration.Tests.ps1
pwsh -NoProfile -File ./tests/Drag.Tests.ps1
pwsh -NoProfile -File ./tests/Drag.Dpi.Tests.ps1
pwsh -NoProfile -File ./tests/Install.Release.Tests.ps1
```

真实 WT 集成测试需在本地安装 Windows Terminal 后运行，会短暂创建专用测试窗口：

```powershell
pwsh -NoProfile -File ./tests/Panel.Integration.Tests.ps1
# 指定显示器；空闲桌面上可附加 -ExerciseKeyboard 验证按键和焦点
pwsh -NoProfile -File ./tests/Panel.Integration.Tests.ps1 -MonitorIndex 1
# 验证孤立 Panel 恢复标题栏；会临时修改并还原你的 WT settings.json（先备份）
pwsh -NoProfile -File ./tests/Panel.Integration.Tests.ps1 -VerifyTitleBarRestore
```

检查覆盖目录继承、窗口显隐、会话复用、新增标签页后的关联、孤立 Panel 恢复、轻量启动、无效/超长/超时管道请求，以及鼠标移动事件放行和 DPI 上下文恢复。Rust 的 DPI 测试使用各显示器上的临时原生窗口，由 `Drag.Dpi.Tests.ps1` 显式运行；无桌面的 CI 跳过该项。默认不注入键盘或鼠标事件；真实手动拖动和持续跨屏拖动仍需人工验证。

新 Shell 只加载轻量接入脚本；首次按 Alt+F 才启动共享 Rust 控制程序。不同 Panel 的 PowerShell 会话各自保留。首次加载 PSReadLine 仍有初始化成本，启动耗时会受用户配置影响。

## CI 与 Release

GitHub Actions 在推送和 Pull Request 时构建并运行自动检查。真实桌面交互测试保留为本地验证，不以无桌面的 CI 结果替代。

推送 `v*` 版本标签触发 Release 工作流：它会先等待同一提交的 CI 成功，再在 Windows **x64 / ARM64** 机器上分别构建和测试原生程序，并上传 ZIP 和合并后的 SHA-256 校验文件到 GitHub Releases。仍应在实际 WT 环境完成交互验证。

```powershell
git tag vX.Y.Z   # 与 Cargo.toml、CHANGELOG 中的版本一致
git push origin vX.Y.Z
```

## 源码结构

```text
install.ps1               在线安装入口：下载、校验，然后运行 wtpocket.exe install
powershell/Startup.ps1    PowerShell 接入：目录记忆、Alt+F、wtpocket 命令
Cargo.toml / Cargo.lock   Rust 构建与锁定依赖
src/host/                 wtpocket 的全部逻辑
  main.rs / cli.rs          入口、命令分发；窗口管理、快捷键钩子、孤立恢复
  client.rs / ipc.rs        命名管道客户端（open/stop）与服务端
  install.rs / update.rs    安装卸载、在线更新
  profile.rs / wtsettings.rs  PowerShell 配置块与 WT 设置绑定的文本编辑
  win.rs / model.rs         Win32 封装、几何与协议模型
scripts/                  构建、打包、许可声明
tests/                    自动检查与 WT 集成测试
.github/workflows/        CI 与 Release
```

## 许可

[MIT](LICENSE) © 2026 huanfeng。WTPocket 是独立开源项目，与 Microsoft 无隶属关系。
