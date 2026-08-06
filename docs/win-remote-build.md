# Windows 远程一键构建（UU 远程 + SSH）

把 ClipFlow Windows 端的构建/调试流程自动化：本机（macOS）通过 UU 远程端口映射 SSH 到 Windows，在 Windows 上 `git pull` + `flutter pub get` + `flutter build windows --release`，可选调用 Windows 上的 Claude Code 做 e2e 自查。

> **两套脚本，别用反了**（Windows 重启/环境坏了优先跑第二套）：
>
> | 脚本 | 在哪运行 | 干什么 |
> |------|---------|--------|
> | `scripts/windows/setup-windows.cmd` | **Windows 端**双击（自动提权） | 环境一键配置：检查 git/node/npm/flutter、**修复 Claude Code**、**配置 sshd 开机自启**、拉取最新代码 |
> | `scripts/win-remote-build.sh`（或 `.command`） | **macOS 端** | 通过 UU+SSH 遥控 Windows 拉代码、analyze/test/build，`--e2e` 可调 Windows Claude 自查 |
>
> `win-remote-build.sh` 是 bash 脚本、依赖 macOS 侧密钥与 UU 隧道，**不能在 Windows 上直接运行**。

## 一次性准备

### Windows 侧
1. 安装并启动 OpenSSH Server（管理员 PowerShell）：
   `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`
   `Start-Service sshd`
   `Set-Service sshd -StartupType Automatic`
2. 本机账户 `20982` 是管理员，密钥要写入：
   `C:\ProgramData\ssh\administrators_authorized_keys`
   （内容为本机 `~/.ssh/clipflow_win.pub` 的公钥，并用 `icacls` 只授权 Administrators/SYSTEM）
3. 项目目录：`E:\VSCode\clipflow`
4. Flutter：`E:\flutter\bin\flutter.bat`
5. Claude Code：`C:\Users\20982\AppData\Roaming\npm\claude.cmd`

### 本机（macOS）侧
1. 密钥：`~/.ssh/clipflow_win`（私钥）已生成并配置到 Windows。
2. UU 远程：新增端口映射 `clipflow-ssh`：
   - 本地端口：22
   - 目标地址：127.0.0.1
   - 目标端口：22
3. 使用前，本机与 Windows 两端都要打开 UU 远程，并确认映射状态为成功（本机 `lsof -nP -iTCP:22 -sTCP:LISTEN` 能看到监听）。

## Windows 端：环境一键配置（推荐先跑一次）

> 用于 Windows 重启后恢复环境：修复 Claude Code（claude.exe 缺失）、把 OpenSSH Server 设为开机自启并启动（避免以后重启又连不上 SSH）、拉取最新代码。

1. 在 Windows 上打开项目目录，`git pull`（或直接双击下面的脚本，它会自己拉）。
2. 双击 `scripts\windows\setup-windows.cmd`，允许 UAC 提权。
3. 脚本自动完成：环境检查 → 重装 Claude Code → 校验 `claude.cmd --version` → sshd 开机自启+启动 → `git pull`。
4. 之后在 macOS 端执行 `bash scripts/win-remote-build.sh`（记得两端 UU 远程都打开）。

> **编码注意**：`setup-windows.ps1` 必须保持 **UTF-8 with BOM** 编码。用无 BOM 的 UTF-8 保存后，Windows PowerShell 5.1 会按 ANSI 解析导致乱码/语法报错。

等价的手动 PowerShell（管理员）：
```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\setup-windows.ps1
```

## 每次使用

1. 打开两端 UU 远程，确认 `clipflow-ssh` 映射成功。
2. 本机执行：
   `bash scripts/win-remote-build.sh`
   或双击 `scripts/win-remote-build.command`。
3. 需要调用 Windows Claude Code 做 e2e 自查时：
   `bash scripts/win-remote-build.sh --e2e`

脚本会自动：检查隧道 → SSH 登录 → `git pull --ff-only origin main` → `flutter pub get` → `flutter build windows --release` → 显示产物路径。

## 约定参数（改脚本顶部即可）

| 变量 | 当前值 |
|------|--------|
| `WIN_USER` | `20982` |
| `WIN_HOST` / `WIN_PORT` | `127.0.0.1` / `22` |
| `WIN_PROJECT` | `E:\VSCode\clipflow` |
| `FLUTTER_BAT` | `E:\flutter\bin\flutter.bat` |
| `CLAUDE_CMD` | `C:\Users\20982\AppData\Roaming\npm\claude.cmd` |
| `KEY` | `~/.ssh/clipflow_win` |

## 常见问题

- 隧道检查失败：两端 UU 远程没开，或映射规则未生效。
- SSH 登录失败：Windows `sshd` 未运行（`Start-Service sshd`），或密钥未写入 `administrators_authorized_keys`。
- 构建报错：把脚本输出的错误信息原样发回，不要在 Windows 上重复排查。
