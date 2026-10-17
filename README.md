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

安装器下载适合当前系统架构的最新 Release，校验 SHA-256 后安装。后台是直接运行的 Rust 原生程序，**无需额外安装 Rust、.NET Runtime、SDK 或 VC++ 运行库**。

v0.2.0 的本机 x64 压缩包约 **0.4 MB**（v0.1.2 约 35 MB），不再携带完整 .NET 运行时。PowerShell 接入保留一个很小的 Win32 接口 DLL，使用 PowerShell 自带的 .NET。

安装后新开一个 PowerShell 标签页，按 **Alt+F**。安装器会先备份 PowerShell 配置，再添加带标记的接入代码；不修改 WT 设置，也不添加登录启动项。

如果希望先检查脚本，再执行：

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/huanfeng/wt-pocket/main/install.ps1 -OutFile install.ps1
Get-Content ./install.ps1
pwsh -NoProfile -File ./install.ps1
```

指定版本安装，例如已发布的 `v0.1.0`：

```powershell
pwsh -NoProfile -File ./install.ps1 -Version v0.1.0
```

也可从 [Releases](https://github.com/huanfeng/wt-pocket/releases) 下载适合架构的 ZIP 和校验文件，核对 `Get-FileHash <压缩包> -Algorithm SHA256` 后解压，在解压目录中执行：

```powershell
pwsh -NoProfile -File ./scripts/Install-WtTools.ps1
```

离线安装使用已构建的 Release ZIP，无需联网编译。校验文件用于检查下载完整性，不是代码签名。

## 使用

| 操作 | 效果 |
| --- | --- |
| 在主终端提示符按 **Alt+F** | 首次在当前目录创建 Panel，之后显示或隐藏同一个 Panel |
| 在 Panel 内按 **Alt+F** | 隐藏 Panel，运行中的命令继续执行 |
| **Alt + 鼠标左键拖动** Panel 内容区 | 移动无标题栏窗口 |
| 正常关闭 Panel，再按 **Alt+F** | 根据主终端此时的目录创建新会话 |

Panel 使用 WT 焦点模式隐藏标题栏和标签栏，初始约为来源窗口宽度的 68%、高度的 60%，尺寸限制在显示器工作区内。重新显示时保留位置、大小、目录和运行状态，支持不同缩放比例的多显示器。

关联不依赖标签页标题：在 Panel 中新建或切换标签页、运行改变标题的程序，仍能显示或隐藏同一窗口。直接把标签页拖出成为另一窗口时，关联不会自动迁移。

主窗口关闭后，隐藏的 Panel 会重新显示，避免正在运行的终端留在不可见状态。

也可使用命令：

```powershell
Open-WtPanel
Open-WtPanel -Directory 'D:\Develop\my project'
Stop-WtTools
```

`-Directory` 只决定新 Panel 的初始目录。已有 Panel 显示时不会自动切换目录或向运行中的程序发送 `cd`。`Stop-WtTools` 停止控制程序并显示仍存活的 Panel，不结束它们的 Shell；下次打开 Panel 会重新启动控制程序。

## 目录记忆

- 按 **WT Profile** 保存最后目录。同一 Profile 的多个普通终端共享记录，最近一次目录变更获胜。
- 新 Shell 从用户主目录启动时恢复记录；从资源管理器或 `wt -d` 指定其他目录启动时，保留指定目录。显式指定主目录与默认启动在主目录无法区分。
- Panel 不写入普通终端的目录记录，首次创建始终使用调用者的目录。
- 使用 PowerShell 的 `LocationChangedAction`，保留原有处理器，不替换 `prompt` 或 `cd`。

目录记忆不是完整会话恢复：重启电脑后不会恢复进程。当前版本也不修改 WT 的“＋”按钮行为。

## 更新与卸载

更新时重新执行安装命令。安装器将完整文件校验后放进 `wttools/app/versions/<内容哈希>`，再切换 PowerShell 启动配置；相同内容重复安装会复用已有目录。即使旧 DLL 正被使用，也无需关闭终端即可安装，包括从早期的平铺目录升级。

新开的 PowerShell 标签页使用新版接入脚本；已有 Shell、Panel 和运行中的命令继续使用原来的文件。正在运行的共享控制程序保持运行，如需立即启用新版控制程序，在新标签页先执行 `Open-WtPanel` 加载模块，再执行 `Stop-WtTools`，之后再次打开 Panel。停止控制程序会显示原有 Panel 并解除关联，旧 Panel 可正常关闭后重建。

配置备份、目录记录、旧安装文件都会保留。安装器不自动清理旧版本，因为其他 Shell 仍可能使用它们。

从 v0.1.x 升到 Rust 版本后，新标签页首次使用 Panel 会优雅停止旧 C# 控制程序，再启动 Rust 后台。旧 Panel 会重新显示并解除关联，其中运行的 Shell 和命令继续保留；可正常关闭后重建。之后同一 Rust 后台的更新继续保留正在运行的控制程序。

卸载：

```powershell
$uninstaller = Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'wttools/app/scripts/Uninstall-WtTools.ps1'
pwsh -NoProfile -File $uninstaller
```

卸载移除配置中的标记块，停止控制程序并显示 Panel，不关闭 Shell。安装文件、目录记忆和备份保留，方便恢复；新开的 Shell 不再启用 WTPocket。

为兼容早期版本，内部命令仍叫 `Open-WtPanel`、`Enable-WtTools`、`Stop-WtTools`，默认安装目录仍为 PowerShell 用户配置目录下的 `wttools/app`，状态文件保存在其父目录 `wttools`。产品和 GitHub 仓库名称为 WTPocket / `wt-pocket`，无需手工重命名已有目录。

## 使用边界

- 主终端的 Alt+F 由 PSReadLine 处理，仅在 PowerShell 等待输入时生效；在主终端运行编辑器、SSH 等前台程序时不能呼出 Panel。Panel 内的 Alt+F 由控制程序处理，运行命令时也能隐藏。
- 目前支持本地 PowerShell 的文件系统目录，不支持 WSL、Git Bash、注册表目录。
- Panel 是独立 WT 窗口，不嵌入主终端，不跟随主窗口连续移动，也不强制全局置顶。
- 使用相同权限级别的终端；管理员 WT 与普通权限控制程序混用未验证。
- 若 WT 自身绑定了 Alt+F，需要移除该绑定。WTPocket 会覆盖当前 Shell 的 Alt+F；卸载后新开 Shell，由原配置恢复自定义绑定。

## 开发与验证

需要 PowerShell 7.4+、**Rust 1.88+ MSVC 工具链、Visual Studio C++ Build Tools 与 Windows SDK**，以及用于构建小型 PowerShell 接口 DLL 的 **.NET 8+ SDK**。Rust 后台静态链接 CRT；接口 DLL 目标为 .NET 8，兼容 PowerShell 7.4+。

后台使用 `windows-sys`、`serde` / `serde_json` 和 `base64`，依赖版本锁定在 `Cargo.lock`；没有 GUI 或异步运行时框架。Release 附带依赖及 Rust 标准库的许可声明。

```powershell
git clone https://github.com/huanfeng/wt-pocket.git
cd wt-pocket
pwsh -NoProfile -File ./scripts/Build.ps1
pwsh -NoProfile -File ./scripts/Install-WtTools.ps1
```

默认构建当前机器架构。交叉构建 ARM64 还需对应的 Rust target 和 Visual Studio ARM64 工具；CI/Release 分别在 x64、ARM64 Windows 机器上原生构建和测试。

本机打包可执行 `./scripts/Package.ps1 -Version 0.2.0 -Runtime win-x64`。生成许可声明需要 `rustup component add rust-docs`；这只影响开发机打包，不是用户安装依赖。

自动检查不依赖 Pester：

```powershell
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
pwsh -NoProfile -File ./tests/Smoke.Tests.ps1
pwsh -NoProfile -File ./tests/Drag.Tests.ps1
pwsh -NoProfile -File ./tests/Drag.Dpi.Tests.ps1
pwsh -NoProfile -File ./tests/Module.Tests.ps1
pwsh -NoProfile -File ./tests/Startup.Tests.ps1
pwsh -NoProfile -File ./tests/Backend.Migration.Tests.ps1
pwsh -NoProfile -File ./tests/Install.Release.Tests.ps1
```

真实 WT 集成测试需在本地安装 Windows Terminal 后运行，会短暂创建专用测试窗口：

```powershell
pwsh -NoProfile -File ./tests/Panel.Integration.Tests.ps1
# 指定显示器；空闲桌面上可附加 -ExerciseKeyboard 验证按键和焦点
pwsh -NoProfile -File ./tests/Panel.Integration.Tests.ps1 -MonitorIndex 1
```

检查覆盖目录继承、窗口显隐、会话复用、新增标签页后的关联、孤立 Panel 恢复、轻量启动、无效/超长/超时管道请求，以及鼠标移动事件放行和 DPI 上下文恢复。Rust 的 DPI 测试使用各显示器上的临时原生窗口，由 `Drag.Dpi.Tests.ps1` 显式运行；无桌面的 CI 跳过该项。默认不注入键盘或鼠标事件；Rust 后台的真实手动拖动和持续跨屏拖动仍需人工验证。

新 Shell 只加载轻量接入脚本；首次使用 Panel 才加载完整模块和预编译的 Win32 接口 DLL，并启动共享 Rust 控制程序。不同 Panel 的 PowerShell 会话各自保留。首次加载 PSReadLine 仍有初始化成本，启动耗时会受用户配置影响。

## CI 与 Release

GitHub Actions 在推送和 Pull Request 时构建并运行自动检查。真实桌面交互测试保留为本地验证，不以无桌面的 CI 结果替代。

推送 `v*` 版本标签触发 Release 工作流，在 Windows **x64 / ARM64** 机器上分别构建和测试原生程序，并上传 ZIP 和合并后的 SHA-256 校验文件到 GitHub Releases。发布前应先确保 `main` 的 CI 通过，并在实际 WT 环境完成交互验证。

```powershell
git tag v0.1.0
git push origin v0.1.0
```

## 源码结构

```text
install.ps1                    在线 Release 安装入口
powershell/Startup.ps1         轻量启动接入
powershell/WtTools.psm1        Shell 集成、目录记忆、快捷键、IPC
Cargo.toml / Cargo.lock       Rust 构建与锁定依赖
src/host/                    Rust 窗口管理、快捷键、命名管道与回归测试
src/WtTools.ShellNative/       预编译的 Shell Win32 接口
scripts/                      构建、打包、许可声明、安装与卸载
tests/                        自动检查与 WT 集成测试
.github/workflows/            CI 与 Release
```

## 许可

[MIT](LICENSE) © 2026 huanfeng。WTPocket 是独立开源项目，与 Microsoft 无隶属关系。
