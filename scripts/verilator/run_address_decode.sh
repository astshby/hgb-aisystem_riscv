#!/usr/bin/env bash
set -euo pipefail
source scripts/verilator/core_build_config.sh

xlen="${1:-32}"
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"
mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" logs

# 零容量、二次幂和非二次幂 DDR 均与独立算术参考模型比较。
for ddr_bytes in 0 65536 24 13 536870912; do
    out_dir="build/verilator/decode-rv${xlen}-${core_build_tag}-ddr${ddr_bytes}"
    log="logs/tb_address_decode-rv${xlen}-${core_build_tag}-ddr${ddr_bytes}.log"
    mkdir -p "${out_dir}"
    verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary \
        -DCORE_XLEN="${xlen}" -GDDR_BYTES="${ddr_bytes}" -Mdir "${out_dir}" \
        vsrc/pkg/core_config_pkg.sv vsrc/pkg/riscv_unpriv_pkg.sv \
        vsrc/pkg/riscv_priv_pkg.sv vsrc/pkg/core_types_pkg.sv \
        vsrc/pkg/soc_config_pkg.sv vsrc/pkg/soc_addr_pkg.sv \
        vsrc/pkg/bus_types_pkg.sv vsrc/soc/bus/address_decode.sv \
        tb/soc/tb_address_decode.sv --top-module tb_address_decode >"${log}" 2>&1
    "${out_dir}/Vtb_address_decode" >>"${log}" 2>&1
    if rg -q '(%Fatal|%Error|Assertion failed)' "${log}"; then
        tail -n 15 "${log}"
        exit 1
    fi
    rg 'PASS tb_address_decode' "${log}" | tail -n 1
done
