#!/usr/bin/env bash
#
# 回归测试：win_claude_preflight（不依赖真实 Windows/SSH）
# 运行：bash scripts/win-claude-preflight_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$SCRIPT_DIR/win-claude-preflight.sh"
FAIL=0
TMP_OUT="$(mktemp)"

say() { :; }

# case 1：claude.cmd 不存在 → 应失败并提示安装
win_ssh() {
  if [[ "$*" == *"if exist"* ]]; then echo "CLAUDE_CMD_MISSING"; return 0; fi
  echo "unexpected call: $*"; return 1
}
CLAUDE_CMD='C:\missing\claude.cmd'
source "$PREFLIGHT"
if win_claude_preflight >"$TMP_OUT" 2>&1; then
  echo "case1 FAIL: 期望失败却成功"; FAIL=1
else
  if grep -q "未找到" "$TMP_OUT"; then echo "case1 pass"; else echo "case1 FAIL: 缺少未找到提示"; FAIL=1; fi
fi

# case 2：claude.cmd 存在但 claude.exe 损坏（--version 失败）→ 应失败并提示重装
win_ssh() {
  if [[ "$*" == *"if exist"* ]]; then echo "CLAUDE_CMD_FOUND"; return 0; fi
  echo "'claude.exe' 不是内部或外部命令"; return 1
}
CLAUDE_CMD='C:\Users\20982\AppData\Roaming\npm\claude.cmd'
source "$PREFLIGHT"
if win_claude_preflight >"$TMP_OUT" 2>&1; then
  echo "case2 FAIL: 期望失败却成功"; FAIL=1
else
  if grep -q "重新安装" "$TMP_OUT"; then echo "case2 pass"; else echo "case2 FAIL: 缺少重新安装提示"; FAIL=1; fi
fi

# case 3：正常可用 → 应成功并输出版本
win_ssh() {
  if [[ "$*" == *"if exist"* ]]; then echo "CLAUDE_CMD_FOUND"; return 0; fi
  echo "2.1.0"; return 0
}
CLAUDE_CMD='C:\Users\20982\AppData\Roaming\npm\claude.cmd'
source "$PREFLIGHT"
if win_claude_preflight >"$TMP_OUT" 2>&1; then
  if grep -q "Claude CLI 可用：2.1.0" "$TMP_OUT"; then echo "case3 pass"; else echo "case3 FAIL: 输出缺少版本"; FAIL=1; fi
else
  echo "case3 FAIL: 期望成功却失败"; FAIL=1
fi

rm -f "$TMP_OUT"
if [ "$FAIL" -eq 0 ]; then
  echo "win-claude-preflight tests passed"
  exit 0
else
  echo "win-claude-preflight tests FAILED"
  exit 1
fi
