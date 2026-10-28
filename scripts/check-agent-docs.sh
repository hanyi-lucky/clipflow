#!/usr/bin/env bash
#
# 校验 AI 指引、agent 定义与治理快照一致性（配套 D+ 单一事实源方案）
#
# 背景：AGENTS.md 是本项目唯一的 AI 指引事实源（入库）；
#       CLAUDE.md 是薄导入层（@AGENTS.md）+ Claude Code 硬红线保底（入库）；
#       .claude/agents/*.md 与 .codex/agents/*.toml 是同一份 agent 定义的两种容器格式。
#
# 用法：
#   bash scripts/check-agent-docs.sh                     # 工作树；结构问题=失败(1)
#   bash scripts/check-agent-docs.sh --strict            # 工作树；所有问题均失败
#   bash scripts/check-agent-docs.sh --staged --strict   # pre-commit：检查治理快照
#
# 退出码：0 通过；1 结构性破坏；2 agent 正文漂移（仅 --strict）
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
STRICT=0
STAGED=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --staged) STAGED=1 ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

# pre-commit 必须校验同一个提交快照。文档与 agent 检查读取工作树，因此相关
# 治理文件只要存在未暂存差异或未跟踪残留，就 fail-closed。
if [ "$STAGED" = "1" ]; then
  required_tracked=(
    .gitignore
    AGENTS.md
    CLAUDE.md
    PROGRESS.md
    docs/architecture.md
    docs/pipeline-workflow.md
    docs/server-operations.md
    docs/optimization-roadmap.md
    docs/decisions/README.md
    scripts/check-agent-docs.sh
    .githooks/pre-commit
  )
  for role in architect coder debugger explorer reviewer tester; do
    required_tracked+=(".claude/agents/${role}.md")
    required_tracked+=(".codex/agents/${role}.toml")
  done

  snapshot_bad=0
  for path in "${required_tracked[@]}"; do
    if ! git show ":${path}" >/dev/null 2>&1; then
      echo "FAIL 治理文件未存在于暂存区：${path}"
      snapshot_bad=1
      continue
    fi
    if ! git diff --quiet -- "$path"; then
      echo "FAIL 治理文件存在未暂存差异：${path}"
      snapshot_bad=1
    fi
  done

  untracked_governance=$(git ls-files --others --exclude-standard -- \
    AGENTS.md CLAUDE.md PROGRESS.md \
    docs/architecture.md docs/pipeline-workflow.md docs/server-operations.md \
    docs/optimization-roadmap.md docs/decisions/README.md \
    .claude/agents .codex/agents scripts .githooks)
  if [ -n "$untracked_governance" ]; then
    echo "FAIL 治理目录存在未跟踪文件；请暂存或移出仓库："
    printf '%s\n' "$untracked_governance"
    snapshot_bad=1
  fi

  if [ "$snapshot_bad" -ne 0 ]; then
    exit 1
  fi
fi

fail=0

# 在 --staged 模式读取暂存区内容；工作树模式读取工作树。
read_governance_file() {
  if [ "$STAGED" = "1" ]; then
    git show ":$1"
  else
    cat "$1"
  fi
}

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
claude_content=$(read_governance_file CLAUDE.md 2>/dev/null) || true
if printf '%s\n' "$claude_content" | grep -qE '^@AGENTS\.md[[:space:]]*$'; then
  echo "   OK   找到独立成行的 @AGENTS.md 导入"
else
  echo "   FAIL CLAUDE.md 里没有独立成行的 @AGENTS.md —— Claude 侧会静默丢失全部项目指引"
  echo "        修法：在 CLAUDE.md 顶部恢复一行（必须独占一行，不能带后缀、不能在代码围栏里）"
  fail=1
fi

echo "== 3) CLAUDE.md 必须保留有实质内容的硬红线 =="
if ! printf '%s\n' "$claude_content" | grep -q '^## 硬红线'; then
  echo "   FAIL CLAUDE.md 没有硬红线段 —— 导入失效时无任何保护"; fail=1
else
  # 只查标题会被"掏空"绕过：数实质条目（`- **xxx**：`）
  n=$(printf '%s\n' "$claude_content" | awk '/^## 硬红线/{f=1;next} /^---$/{f=0} f' | grep -c '^- \*\*')
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
  agents_content=$(read_governance_file AGENTS.md 2>/dev/null) || true
  printf '%s\n' "$agents_content" | grep -qF "$marker" || missing="$missing [$marker]"
done
if [ -z "$missing" ]; then
  echo "   OK   关键章节齐全"
else
  echo "   FAIL AGENTS.md 缺少关键章节：${missing}"; fail=1
fi

echo "== 4) 两套 agent 定义的正文是否一致 =="
if [ "$STAGED" = "1" ]; then
  staged_root=$(mktemp -d "${TMPDIR:-/tmp}/clipflow-governance.XXXXXX")
  trap 'rm -rf "$staged_root"' EXIT
  mkdir -p "$staged_root/.claude/agents" "$staged_root/.codex/agents"
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    git show ":./${path}" > "$staged_root/${path}" || exit 1
  done < <(git ls-files -z -- .claude/agents .codex/agents)
  for role in architect coder debugger explorer reviewer tester; do
    mkdir -p "$staged_root/.claude/agents" "$staged_root/.codex/agents"
    [ -f "$staged_root/.claude/agents/${role}.md" ] || exit 1
    [ -f "$staged_root/.codex/agents/${role}.toml" ] || exit 1
  done
  cd "$staged_root" || exit 1
fi
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
expected = {'architect', 'coder', 'debugger', 'explorer', 'reviewer', 'tester'}
names = sorted(n[:-3] for n in os.listdir('.claude/agents') if n.endswith('.md'))
if not names:
    print("   FAIL .claude/agents/ 下没有 agent 定义"); sys.exit(3)
if set(names) != expected:
    print(f"   FAIL Claude agent 角色清单不一致：expected={sorted(expected)} actual={names}")
    sys.exit(3)
if not os.path.isdir('.codex/agents'):
    print("   FAIL .codex/agents/ 不存在；agent 定义必须随仓库入库")
    sys.exit(3)
codex_names = sorted(n[:-5] for n in os.listdir('.codex/agents') if n.endswith('.toml'))
extra_codex = set(codex_names) - expected
if extra_codex:
    print(f"   FAIL Codex 侧存在孤立 agent：{sorted(extra_codex)}")
    sys.exit(3)
for n in names:
    cp, tp = f'.claude/agents/{n}.md', f'.codex/agents/{n}.toml'
    if not os.path.exists(tp):
        print(f"   FAIL {n}: Codex 侧缺少 {tp}")
        sys.exit(3)
    if claude_body(cp) != codex_body(tp):
        print(f"   FAIL {n}: 两侧正文不一致 → 改动后未同步")
        bad.append(n)
    else:
        print(f"   OK   {n}")
sys.exit(2 if bad else 0)
PY
rc=$?
case "$rc" in
  0) : ;;
  2)
    if [ "$STRICT" = "1" ]; then echo "   → --strict 模式，视为失败"; fail=2
    else echo "   → 仅警告（未加 --strict）。改动任一侧后请同步另一侧"; fi ;;
  *)  echo "   → 检查本身出错（退出码 ${rc}），按失败处理"; fail=1 ;;
esac

echo
if [ "$fail" = "0" ]; then echo "✅ 通过"; exit 0
elif [ "$fail" = "2" ]; then echo "❌ 失败：agent 正文漂移（--strict）"; exit 2
else echo "❌ 失败：结构性问题"; exit 1; fi
