#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
case "$xlen" in 32|64) ;; *) echo 'XLEN must be 32 or 64' >&2; exit 2;; esac
source scripts/verilator/p2_core_config.sh
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
tag="icache-install-regression-rv${xlen}-${p2_core_build_tag}"
log_root="${ICACHE_INSTALL_LOG_ROOT:-logs/$tag}"
out_root="${ICACHE_INSTALL_BUILD_ROOT:-build/verilator/$tag}"
mkdir -p "$out_root" "$log_root" "$CCACHE_TEMPDIR" "$CCACHE_DIR"
sources=(vsrc/pkg/core_config_pkg.sv vsrc/pkg/riscv_unpriv_pkg.sv vsrc/pkg/riscv_priv_pkg.sv
    vsrc/pkg/core_types_pkg.sv vsrc/pkg/soc_config_pkg.sv vsrc/pkg/soc_addr_pkg.sv
    vsrc/pkg/bus_types_pkg.sv vsrc/pkg/block_types_pkg.sv vsrc/pkg/cache_pkg.sv
    vsrc/soc/bus/address_decode.sv vsrc/soc/cache/cache_port.sv
    vsrc/soc/cache/cache_data_array.sv vsrc/soc/cache/cache_meta_array.sv
    vsrc/soc/cache/cache_refill.sv vsrc/soc/cache/cache_writeback.sv
    vsrc/soc/cache/dcache_meta_array.sv vsrc/soc/cache/icache.sv
    vsrc/soc/cache/icache_native.sv vsrc/soc/cache/dcache.sv vsrc/soc/cache/dcache_wt.sv)
tests=(tb/unit/scoreboard/tb_scoreboard_icache.sv tb/cache/tb_cache_block.sv
    tb/cache/tb_cache_block_protocol.sv tb/cache/tb_icache.sv tb/cache/tb_dcache.sv
    tb/cache/tb_dcache_wb.sv)
sha256sum "${sources[@]}" "${tests[@]}" scripts/verilator/{run_icache_install_regression,p2_core_config,core_build_config}.sh > "$log_root/sources.sha256"
: > "$log_root/commands.txt"
: > "$log_root/binaries.sha256"
passes=0
run_case() {
    local name="$1" fill="$2" source="$3" top="$4"
    shift 4
    local out="$out_root/$name"
    mkdir -p "$out"
    local build=(verilator -Wall -Wno-fatal --assert --timing --binary -j 1
        "-DCORE_XLEN=$xlen" "-DSOC_ICACHE_FILL_BYTES=$fill" "${p2_core_flags[@]}"
        -Mdir "$out" "${sources[@]}" "$source" --top-module "$top" "$@")
    printf '%q ' "${build[@]}" >> "$log_root/commands.txt"
    printf '\n%q\n' "$out/V$top" >> "$log_root/commands.txt"
    "${build[@]}" > "$log_root/$name.build.log" 2>&1 || { tail -n 60 "$log_root/$name.build.log"; exit 1; }
    if rg -n '(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER|%Error)' "$log_root/$name.build.log"; then exit 1; fi
    sha256sum "$out/V$top" >> "$log_root/binaries.sha256"
    "$out/V$top" > "$log_root/$name.run.log" 2>&1 || { tail -n 40 "$log_root/$name.run.log"; exit 1; }
    if rg -q '(%Fatal|%Error|Assertion failed)' "$log_root/$name.run.log"; then cat "$log_root/$name.run.log"; exit 1; fi
    rg "^PASS $top " "$log_root/$name.run.log"
    passes=$((passes+1))
}
for fill in 4 8; do
    run_case "native-f$fill" "$fill" tb/unit/scoreboard/tb_scoreboard_icache.sv tb_scoreboard_icache
done
# 共享refill的旧I$/WT/WB实例保持默认安装宽度；打开I$宏8不能改变它们。
for line in 32 64 128; do
    for block in 0 1; do
        for instruction in 0 1; do
            run_case "block-l$line-b$block-i$instruction" 8 tb/cache/tb_cache_block.sv tb_cache_block \
                "-GLINE_BYTES=$line" "-GBLOCK_ENABLE=$block" "-GINSTRUCTION=$instruction"
        done
    done
    run_case "protocol-l$line-w4" 8 tb/cache/tb_cache_block_protocol.sv tb_cache_block_protocol "-GLINE_BYTES=$line"
    if [[ "$xlen" == 64 ]]; then
        run_case "protocol-l$line-w8" 8 tb/cache/tb_cache_block_protocol.sv tb_cache_block_protocol \
            "-GLINE_BYTES=$line" -GWORD_BYTES=8
    fi
done
for top in tb_icache tb_dcache tb_dcache_wb; do
    for config in small default disabled absent; do
        parameters=()
        case "$config" in
            default) parameters+=(-GCACHE_BYTES=4096);;
            disabled) parameters+=(-GENABLE=0);;
            absent) parameters+=(-GDDR_BYTES=0);;
        esac
        run_case "$top-$config" 8 "tb/cache/$top.sv" "$top" "${parameters[@]}"
    done
done
sha256sum --check --quiet "$log_root/sources.sha256"
echo "PASS icache-install-regression RV$xlen: $passes configurations, 0 SKIP"
