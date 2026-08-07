#!/usr/bin/env bash
#
# 归档 .codex/pipeline/ 到 archive/<里程碑>/pipeline/
#
# 用法：
#   bash scripts/archive-pipeline.sh <里程碑名>
#   例：bash scripts/archive-pipeline.sh v1.5-phase5
#
# 原则（见 AGENTS.md §6.3）：
#   新阶段开工前归档上一阶段过程文件；保留最近 1 个里程碑全过程 + 历史摘要。
set -euo pipefail

MILESTONE="${1:?用法: bash scripts/archive-pipeline.sh <里程碑名>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPE="$ROOT/.codex/pipeline"
DEST="$ROOT/archive/$MILESTONE/pipeline"

if [ ! -d "$PIPE" ]; then
  echo "没有可归档的 pipeline 目录: $PIPE"
  exit 0
fi

mkdir -p "$DEST"
count=0
for f in "$PIPE"/*; do
  [ -e "$f" ] || continue
  mv "$f" "$DEST/"
  count=$((count + 1))
done

echo "已归档 $count 个文件到 $DEST"
echo "提示：保留最近 1 个里程碑全过程即可，更早里程碑可只留终报+决策摘要后删除。"
