#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
fill_bytes="${2:-4}"
case "$xlen" in 32|64) ;; *) echo 'XLEN must be 32 or 64' >&2; exit 2;; esac
case "$fill_bytes" in 4|8) ;; *) echo 'I-cache installation bytes must be 4 or 8' >&2; exit 2;; esac
source scripts/verilator/p2_core_config.sh
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
tag="icache-install-rv${xlen}-f${fill_bytes}-${p2_core_build_tag}"
log_root="${ICACHE_INSTALL_LOG_ROOT:-logs/$tag}"
out="${ICACHE_INSTALL_BUILD_ROOT:-build/verilator/$tag}"
mkdir -p "$out" "$log_root" "$CCACHE_TEMPDIR" "$CCACHE_DIR"
sources=(vsrc/pkg/core_config_pkg.sv vsrc/pkg/riscv_unpriv_pkg.sv vsrc/pkg/riscv_priv_pkg.sv
    vsrc/pkg/core_types_pkg.sv vsrc/pkg/soc_config_pkg.sv vsrc/pkg/soc_addr_pkg.sv
    vsrc/pkg/bus_types_pkg.sv vsrc/pkg/block_types_pkg.sv
    vsrc/soc/bus/address_decode.sv vsrc/soc/cache/cache_data_array.sv
    vsrc/soc/cache/cache_meta_array.sv vsrc/soc/cache/cache_refill.sv
    vsrc/soc/cache/icache_native.sv tb/cache/tb_icache_install_width.sv)
build=(verilator -Wall -Wno-fatal --assert --timing --binary -j 1
    "-DCORE_XLEN=$xlen" "-DSOC_ICACHE_FILL_BYTES=$fill_bytes" "${p2_core_flags[@]}"
    -Mdir "$out" "${sources[@]}" --top-module tb_icache_install_width)
printf '%q ' "${build[@]}" > "$log_root/commands.txt"
printf '\n%q\n' "$out/Vtb_icache_install_width" >> "$log_root/commands.txt"
sha256sum "${sources[@]}" scripts/verilator/{run_icache_install_width,p2_core_config,core_build_config}.sh > "$log_root/sources.sha256"
"${build[@]}" > "$log_root/build.log" 2>&1 || { tail -n 60 "$log_root/build.log"; exit 1; }
if rg -n '(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER|%Error)' "$log_root/build.log"; then exit 1; fi
sha256sum "$out/Vtb_icache_install_width" > "$log_root/binary.sha256"
"$out/Vtb_icache_install_width" > "$log_root/run.log" 2>&1 || { tail -n 40 "$log_root/run.log"; exit 1; }
if rg -q '(%Fatal|%Error|Assertion failed)' "$log_root/run.log"; then cat "$log_root/run.log"; exit 1; fi
[[ "$(rg -c '^PASS ICACHE_INSTALL_CASE ' "$log_root/run.log")" == 5 ]]
rg '^PASS tb_icache_install_width ' "$log_root/run.log"
sha256sum --check --quiet "$log_root/sources.sha256"
