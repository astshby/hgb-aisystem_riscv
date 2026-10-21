#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
width="${1:-32}"
mkdir -p build/p1-reference
# 参考源码从已合入的 P0 提交只读提取，保持测试数据与待测实现分开。
git show 094443ec714efe0083affe5a0c8c1ae4d58adbd5:vsrc/core/lsu/load_store_queue.sv |
    sed 's/^module load_store_queue #(/module load_store_queue_reference #(/' \
    > build/p1-reference/load_store_queue_reference.sv
LSQ_EQUIVALENCE=1 bash scripts/verilator/run_scoreboard.sh "$width" lsu lsu_slots lsu_forward core events
