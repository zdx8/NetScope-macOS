#!/bin/bash
# CPU / 内存读数真机对照验证（受控负载 + vm_stat 基准）
#
# 原理：自造按构造已知的负载，验证探针读数——
#   1. 系统内存逐字段对照 vm_stat（wired / compressor）
#   2. 500 MB 分配子进程 → footprint 应 ≈ 500 MB
#   3. 忙等 2 s 子进程 → 累计 CPU 时间应 ≈ 2×10⁹ ns（验证 timebase 换算）
#   4. 单个满载子进程 → 单核口径应 ≈ 100%
#   5. 4 个纯用户态满载 → 系统 busy +40 个百分点左右、用户态 +40、系统态不动
#
# 说明：第 5 项在机器被实际使用时基线会漂移（25–42% 波动属正常），
# 判定以「用户态增量」为主，系统 busy 增量放宽到 25–55。
# 预计运行 20 秒左右。结束后自动 SIGKILL 全部子进程。
set -euo pipefail
cd "$(dirname "$0")"

PROJ_ROOT="$(cd ../.. && pwd)"
BUILD_DIR="$(mktemp -d /tmp/netscope-loadcheck.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "== 编译 =="
swiftc -O -o "$BUILD_DIR/memchild" memchild.swift
swiftc -O -o "$BUILD_DIR/spinchild" spinchild.swift
swiftc -O -o "$BUILD_DIR/loadcheck" main.swift \
    "$PROJ_ROOT/Sources/NetScope/Core/SystemLoadProbe.swift" \
    "$PROJ_ROOT/Sources/NetScope/Core/ProcessLoadProbe.swift"

echo "== 运行 =="
SPINCHILD="$BUILD_DIR/spinchild" MEMCHILD="$BUILD_DIR/memchild" "$BUILD_DIR/loadcheck"
