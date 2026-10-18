#!/bin/bash
# 编译 K3BatterySyncService
#
#   ./build.sh          构建出 ./K3BatterySyncService
#   ./build.sh run      构建完直接跑（Ctrl-C 退出）
set -euo pipefail
cd "$(dirname "$0")"

BIN="K3BatterySyncService"

echo "==> 编译"
rm -f "$BIN"
swiftc -O -swift-version 5 \
    -framework AppKit -framework IOKit \
    Sources/*.swift \
    -o "$BIN"

echo "==> 完成: $(pwd)/$BIN"

if [ "${1:-}" = "run" ]; then
    echo "==> 启动（Ctrl-C 退出）"
    echo
    exec "./$BIN"
fi
