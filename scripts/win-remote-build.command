#!/bin/bash
# 双击运行：在终端中执行 win-remote-build.sh（带 --e2e 可传参）
exec "$(cd "$(dirname "$0")" && pwd)/win-remote-build.sh" "$@"
