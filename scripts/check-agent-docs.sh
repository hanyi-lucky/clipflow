#!/usr/bin/env bash
#
# 校验 AI 指引文件的一致性（配套 D+ 单一事实源方案）
#
# 背景：AGENTS.md 是本项目唯一的 AI 指引事实源（入库）；
#       CLAUDE.md 是薄导入层（@AGENTS.md）+ Claude Code 硬红线保底（入库）；
#       .claude/agents/*.md 与 .codex/agents/*.toml 是同一份 agent 定义的两种容器格式。
#
# 用法：
#   bash scripts/check-agent-docs.sh            # 结构性问题=失败(1)；agent 正文漂移=仅警告
#   bash scripts/check-agent-docs.sh --strict   # 漂移也失败
#
# 退出码：0 通过；1 结构性破坏；2 agent 正文漂移（仅 --strict）
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

fail=0

echo "== 1) AGENTS.md 必须被 git 追踪 =="
if git ls-files --error-unmatch AGENTS.md >/dev/null 2>&1; then
  echo "   OK   AGENTS.md 已入库"
else
  echo "   FAIL AGENTS.md 未入库 —— 单一事实源失效"
  echo "        修法：把 AGENTS.md 从 .gitignore 移除后 git add AGENTS.md"
  fail=1
fi

echo "== 2) CLAUDE.md 必须包含 @AGENTS.md 导入 =="
# 用整行精确匹配：前缀匹配会放过 `@AGENTS.md.bak` / `@AGENTS.md.old` 这类变体
if grep -qE '^@AGENTS\.md[[:space:]]*$' CLAUDE.md 2>/dev/null; then
  echo "   OK   找到独立成行的 @AGENTS.md 导入"
else
  echo "   FAIL CLAUDE.md 里没有独立成行的 @AGENTS.md —— Claude 侧会静默丢失全部项目指引"
  echo "        修法：在 CLAUDE.md 顶部恢复一行（必须独占一行，不能带后缀、不能在代码围栏里）"
  fail=1
fi

echo "== 3) CLAUDE.md 必须保留有实质内容的硬红线 =="
if ! grep -q '^## 硬红线' CLAUDE.md 2>/dev/null; then
  echo "   FAIL CLAUDE.md 没有硬红线段 —— 导入失效时无任何保护"; fail=1
else
  # 只查标题会被"掏空"绕过：数实质条目（`- **xxx**：`）
  n=$(awk '/^## 硬红线/{f=1;next} /^---$/{f=0} f' CLAUDE.md | grep -c '^- \*\*')
  if [ "$n" -ge 8 ]; then
    echo "   OK   硬红线段存在，含 ${n} 条实质条目"
  else
    echo "   FAIL 硬红线段只有 ${n} 条实质条目（需 >=8）—— 内容疑似被掏空"
    fail=1
  fi
fi

echo "== 3b) AGENTS.md 不能被掏空（仍在 git 但没有实质内容）=="
missing=""
for marker in '### 2.2 强制底限' '### 2.7 任务预算' '## 6. 主代理编排规范' '## 工具差异对照' '## 核心设计决策'; do
  grep -qF "$marker" AGENTS.md 2>/dev/null || missing="$missing [$marker]"
done
if [ -z "$missing" ]; then
  echo "   OK   关键章节齐全"
else
  echo "   FAIL AGENTS.md 缺少关键章节：${missing}"; fail=1
fi

echo "== 4) 两套 agent 定义的正文是否一致 =="
python3 - <<'PY'
import re, os, sys
def claude_body(p):
    t = open(p, encoding='utf-8').read()
    m = re.match(r'\A---\n.*?\n---\n(.*)\Z', t, re.S)
    return re.sub(r'\s+', ' ', (m.group(1) if m else t)).strip()
def codex_body(p):
    t = open(p, encoding='utf-8').read()
    m = re.search(r'developer_instructions\s*=\s*"""(.*?)"""', t, re.S)
    return re.sub(r'\s+', ' ', (m.group(1) if m else '')).strip()
bad = []
names = sorted(n[:-3] for n in os.listdir('.claude/agents') if n.endswith('.md'))
if not names:
    print("   FAIL .claude/agents/ 下没有 agent 定义"); sys.exit(3)
for n in names:
    cp, tp = f'.claude/agents/{n}.md', f'.codex/agents/{n}.toml'
    if not os.path.exists(tp):
        print(f"   WARN {n}: Codex 侧缺少 {tp}（只有一侧存在，无法比对）"); continue
    if claude_body(cp) != codex_body(tp):
        print(f"   FAIL {n}: 两侧正文不一致 → 改动后未同步")
        bad.append(n)
    else:
        print(f"   OK   {n}")
sys.exit(2 if bad else 0)
PY
rc=$?
# 关键兜底：python 段的任何非 0 退出码（目录缺失=1/3、python3 缺失=127、解析崩溃）
# 都必须算失败，不能静默放行 —— 否则"删掉全部 agent 定义"这种最坏情况反而全绿。
case "$rc" in
  0) : ;;                                        # 一致
  2)                                             # 正文漂移
    if [ "$STRICT" = "1" ]; then echo "   → --strict 模式，视为失败"; fail=2
    else echo "   → 仅警告（未加 --strict）。改动任一侧后请同步另一侧"; fi ;;
  *)  echo "   → 检查本身出错（退出码 ${rc}），按失败处理"; fail=1 ;;
esac

echo
if [ "$fail" = "0" ]; then echo "✅ 通过"; exit 0
elif [ "$fail" = "2" ]; then echo "❌ 失败：agent 正文漂移（--strict）"; exit 2
else echo "❌ 失败：结构性问题"; exit 1; fi
