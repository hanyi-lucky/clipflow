#!/usr/bin/env bash
#
# ClipFlow Windows 远程构建（一键脚本）
#
# 前置条件：
#   1. 本机与 Windows 两端都打开 UU 远程，并保持端口映射
#      （本机 127.0.0.1:22 -> Windows OpenSSH 22）
#   2. 本机存在密钥 ~/.ssh/clipflow_win（已配置到 Windows）
#   3. Windows 上 sshd 已运行、仓库位于 E:\VSCode\clipflow
#
# 用法：
#   bash scripts/win-remote-build.sh          # 只构建
#   bash scripts/win-remote-build.sh --e2e    # 构建后调用 Windows Claude Code 做 e2e 自查
set -uo pipefail

KEY="$HOME/.ssh/clipflow_win"
WIN_USER="20982"
WIN_HOST="127.0.0.1"
WIN_PORT=22
WIN_PROJECT='E:\VSCode\clipflow'
FLUTTER_BAT='E:\flutter\bin\flutter.bat'
CLAUDE_CMD='C:\Users\20982\AppData\Roaming\npm\claude.cmd'

RUN_E2E=0
for arg in "$@"; do
  case "$arg" in
    --e2e) RUN_E2E=1 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }

win_ssh() {
  ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${WIN_USER}@${WIN_HOST}" "$@"
}

if [ ! -f "$KEY" ]; then
  echo "缺少密钥：$KEY"
  echo "请先生成并配置密钥（或检查 ~/.ssh/clipflow_win 是否存在）。"
  exit 1
fi

say "检查 UU 隧道（${WIN_HOST}:${WIN_PORT}）"
if ! nc -z -w 5 "$WIN_HOST" "$WIN_PORT" >/dev/null 2>&1; then
  echo "隧道未就绪：请在本机和 Windows 两端都打开 UU 远程，并保持 clipflow-ssh 映射成功。"
  exit 1
fi
echo "隧道可用"

say "SSH 登录 Windows"
if ! win_ssh "echo WINDOWS_OK && whoami"; then
  echo "SSH 登录失败：请确认 Windows sshd 已运行（Start-Service sshd），且密钥已加入 administrators_authorized_keys。"
  exit 1
fi

say "Windows 上拉取最新代码（git pull）"
win_ssh "cd /d ${WIN_PROJECT} && git pull --ff-only origin main" || {
  echo "git pull 失败，请检查 Windows 网络或仓库状态。"
  exit 1
}

say "Windows 上执行 flutter pub get"
win_ssh "cd /d ${WIN_PROJECT} && ${FLUTTER_BAT} pub get" || {
  echo "flutter pub get 失败。"
  exit 1
}

say "Windows 上执行 flutter build windows --release"
win_ssh "cd /d ${WIN_PROJECT} && ${FLUTTER_BAT} build windows --release" || {
  echo "flutter build 失败，请把上面的错误信息发回。"
  exit 1
}

say "构建产物确认"
win_ssh "dir /b ${WIN_PROJECT}\\build\\windows\\x64\\runner\\Release\\clipflow.exe" || {
  echo "产物路径检查失败（构建可能成功但路径不同）。"
}

if [ "$RUN_E2E" = "1" ]; then
  say "调用 Windows Claude Code 做 e2e 自查（构建 + 冒烟）"
  win_ssh "cd /d ${WIN_PROJECT} && ${CLAUDE_CMD} -p \"阅读 PROGRESS.md 与 WINDOWS_SETUP.md，执行 flutter build windows --release，按 e2e 清单在真实剪贴板测试文件同步并报告结果\"" || {
    echo "Claude Code e2e 执行失败，可重试或手动在 Windows 上运行。"
    exit 1
  }
fi

echo
echo "完成。Windows 产物：${WIN_PROJECT}\\build\\windows\\x64\\runner\\Release\\clipflow.exe"
