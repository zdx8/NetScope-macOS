#!/bin/bash
# 双通道并行诊断：逐批对比 external 与 physical 的增量，验证 VPN 去重前提。
# 用法：bash Scripts/traffic-probe.sh [秒数]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="/tmp/netscope-traffic-probe"
DURATION="${1:-8}"

# swiftc 只允许 main.swift 里写顶层代码，这里复制成 main.swift 再编译
SOURCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/netscope-probe.XXXXXX")"
cp Scripts/traffic-probe.swift "$SOURCE_DIR/main.swift"

swiftc -O -o "$OUT" \
  Sources/NetScope/Core/ProcCounters.swift \
  Sources/NetScope/Core/NettopPTY.swift \
  Sources/NetScope/Core/TunnelDetector.swift \
  "$SOURCE_DIR/main.swift"

rm -f "$SOURCE_DIR/main.swift"
rmdir "$SOURCE_DIR" 2>/dev/null || true

"$OUT" "$DURATION"
