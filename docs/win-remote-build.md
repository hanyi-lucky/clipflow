# Windows 远程一键构建（UU 远程 + SSH）

把 ClipFlow Windows 端的构建/调试流程自动化：本机（macOS）通过 UU 远程端口映射 SSH 到 Windows，在 Windows 上 `git pull` + `flutter pub get` + `flutter build windows --release`，可选调用 Windows 上的 Claude Code 做 e2e 自查。

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
