#!/bin/bash
# NetScope 无界面自检：只编译纯逻辑层 + 一个 main.swift，绕开 GUI 与 AppKit。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/netscope-selfcheck"

swiftc -O -lsqlite3 -o "$OUT" \
  Sources/NetScope/Core/ProcCounters.swift \
  Sources/NetScope/Core/TrafficAggregator.swift \
  Sources/NetScope/Core/NettopPTY.swift \
  Sources/NetScope/Core/TunnelDetector.swift \
  Sources/NetScope/Core/HistoryStore.swift \
  Sources/NetScope/Core/AlertCenter.swift \
  Sources/NetScope/Support/Formatting.swift \
  Sources/NetScope/Support/MenuBarSparkline.swift \
  Scripts/selfcheck/main.swift

"$OUT"
