#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
source scripts/verilator/p2_core_config.sh
expect_turnover="${EXPECT_TURNOVER:-0}"
expect_block="${EXPECT_BLOCK:--1}"
bank_mask="${BANK_XOR_MASK:-0}"
cache_bytes="${DCACHE_BYTES:-256}"
[[ "$bank_mask" =~ ^[0-3]$ && "$cache_bytes" =~ ^[0-9]+$ ]] || exit 2
[[ "$xlen" =~ ^(32|64)$ && "$expect_turnover" =~ ^[01]$ && "$expect_block" =~ ^(-1|0|1)$ ]] || {
    echo "usage: EXPECT_TURNOVER=0|1 EXPECT_BLOCK=-1|0|1 bash scripts/verilator/run_dcache_turnover.sh 32|64" >&2
    exit 2
}
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/p2/measure-optimize-20261022/review/dcache-turnover-$p2_core_build_tag}"
out="build/verilator/p2-dcache-turnover-rv${xlen}-$p2_core_build_tag-c${cache_bytes}-h${bank_mask}"
prefix="$log_root/rv${xlen}-expect${expect_turnover}-block${expect_block}-c${cache_bytes}-h${bank_mask}"
mkdir -p "$out" "$log_root" "$CCACHE_TEMPDIR" "$CCACHE_DIR"
sources=(vsrc/pkg/core_config_pkg.sv vsrc/pkg/riscv_unpriv_pkg.sv vsrc/pkg/riscv_priv_pkg.sv
    vsrc/pkg/core_types_pkg.sv vsrc/pkg/soc_config_pkg.sv vsrc/pkg/soc_addr_pkg.sv
    vsrc/pkg/bus_types_pkg.sv vsrc/pkg/block_types_pkg.sv vsrc/pkg/cache_pkg.sv
    vsrc/soc/bus/address_decode.sv vsrc/soc/bus/bus_pair_arbiter.sv vsrc/soc/bus/block_arbiter.sv
    vsrc/soc/cache/cache_port.sv vsrc/soc/cache/cache_data_array.sv vsrc/soc/cache/cache_refill.sv
    vsrc/soc/cache/cache_writeback.sv vsrc/soc/cache/dcache_meta_array.sv
    vsrc/soc/cache/dcache.sv vsrc/soc/cache/dcache_banked.sv tb/cache/tb_dcache_turnover.sv)
sha256sum "${sources[@]}" scripts/verilator/run_dcache_turnover.sh >"$prefix.sources.sha256"
{
    git branch --show-current
    git rev-parse HEAD
    printf 'EXPECT_TURNOVER=%s EXPECT_BLOCK=%s bash scripts/verilator/run_dcache_turnover.sh %s\n' "$expect_turnover" "$expect_block" "$xlen"
    verilator --version
} >"$prefix.context.txt"
verilator -Wall -Wno-fatal --assert --timing --binary -j 2 -CFLAGS -O1 \
    -DCORE_XLEN="$xlen" -DSOC_DCACHE_BANK_XOR_MASK="$bank_mask" -GCACHE_BYTES="$cache_bytes" "${p2_core_flags[@]}" -Mdir "$out" "${sources[@]}" --top-module tb_dcache_turnover \
    >"$prefix.build.log" 2>&1 || { tail -n 45 "$prefix.build.log"; exit 1; }
if rg -n '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$prefix.build.log"; then exit 1; fi
# 严格模式的断言失败保留非零退出码；旧 RTL 的预期失败由外层审查记录判定。
ulimit -c 0
"$out/Vtb_dcache_turnover" "+EXPECT_TURNOVER=$expect_turnover" "+EXPECT_BLOCK=$expect_block" >"$prefix.run.log" 2>&1 || {
    tail -n 25 "$prefix.run.log"
    exit 1
}
rg '^PASS tb_dcache_turnover ' "$prefix.run.log"
