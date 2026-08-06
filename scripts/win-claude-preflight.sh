#!/usr/bin/env bash
#
# Windows 端 Claude CLI 预检（供 win-remote-build.sh --e2e 使用）
#
# 依赖（由调用方提供）：
#   - win_ssh()：通过 SSH 在 Windows 上执行命令的函数
#   - CLAUDE_CMD：Windows 上 claude.cmd 的绝对路径
#
# 用法：
#   source win-claude-preflight.sh
#   win_claude_preflight || exit 1
#
# 返回 0：Claude CLI 可启动；返回非 0：不可用（附原因与修复命令）。

win_claude_preflight() {
  local out rc
  say "检查 Windows Claude CLI（${CLAUDE_CMD}）"

  out="$(win_ssh "if exist \"${CLAUDE_CMD}\" (echo CLAUDE_CMD_FOUND) else (echo CLAUDE_CMD_MISSING)" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "SSH 检查失败，无法确认 Claude CLI 状态（隧道或 Windows sshd 可能不可用）。"
    printf '%s\n' "$out"
    return 1
  fi
  if ! printf '%s' "$out" | grep -q CLAUDE_CMD_FOUND; then
    echo "未找到 ${CLAUDE_CMD}"
    echo "请先在 Windows 上安装 Claude Code：npm install -g @anthropic-ai/claude-code"
    return 1
  fi

  out="$(win_ssh "\"${CLAUDE_CMD}\" --version" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "claude.cmd 存在但无法启动（claude.exe 可能丢失或损坏），原始输出："
    printf '%s\n' "$out"
    echo "请重新安装："
    echo "  npm uninstall -g @anthropic-ai/claude-code"
    echo "  npm install -g @anthropic-ai/claude-code"
    return 1
  fi
  echo "Claude CLI 可用：$(printf '%s\n' "$out" | tail -1)"
}
