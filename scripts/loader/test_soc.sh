#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
source scripts/verilator/core_build_config.sh
source scripts/soc_profile.sh
local_tcm="${SOC_LOCAL_TCM_ENABLE:-0}"
[[ "$local_tcm" =~ ^[01]$ ]] || { echo 'SOC_LOCAL_TCM_ENABLE must be 0 or 1' >&2; exit 2; }
out="build/loader/sim-rv$xlen"
mkdir -p logs "$out"
# 同位宽的下载测试共用镜像/模型目录，整段加锁，避免并行回归覆盖 wire。
exec {loader_test_lock}>"$out/.test.lock"
flock "$loader_test_lock"
LOADER_BAUD=500000 LOADER_QUIET_MS=1 bash scripts/loader/build.sh "$xlen"
python3 -B - "$xlen" "${LOADER_PACKET:-}" <<'PY'
import sys,struct
from pathlib import Path
sys.path.insert(0,'scripts/loader')
from host import packet,crc
xlen=int(sys.argv[1])
# LUI t0,0x01100; ADDI t1,zero,1; SW t1,0(t0); JAL zero,0.
code=struct.pack('<4I',0x011002b7,0x00100313,0x0062a023,0x0000006f)
h,blocks=packet(xlen,0x80000000,[(0x80000000,1,code),(0x0110c000,0,b'hot-code')])
wire=h+b''.join(b+struct.pack('<I',crc(b)) for b in blocks)
if sys.argv[2]: wire=Path(sys.argv[2]).read_bytes()
root=Path(f'build/loader/sim-rv{xlen}')
(root/'wire.hex').write_text(''.join(f'{b:02x}\n' for b in wire))
(root/'wire.size').write_text(str(len(wire)))
PY
sim="build/verilator/uart-loader-rv$xlen-${core_build_tag}-p$soc_profile-ltcm$local_tcm"
mkdir -p "$sim" build/ccache-tmp build/ccache
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary --output-split-cfuncs 500 \
    -CFLAGS "${LOADER_HOST_OPT:--O0}" \
    -DCORE_XLEN="$xlen" -DCORE_MUL_IMPL=0 -DCORE_DIV_IMPL=1 -Mdir "$sim" \
    -f scripts/soc_files.f tb/common/store_result_monitor.sv tb/soc/axi_memory_model.sv tb/soc/axi_block_memory_model.sv \
    tb/soc/axi_system_memory_model.sv tb/soc/spi_flash_model.sv \
    tb/soc/tb_soc_system.sv tb/loader/tb_uart_loader.sv \
    -GLOCAL_TCM_ENABLE="$local_tcm" -GSOC_PROFILE="$soc_profile_id" --top-module tb_uart_loader \
    > "logs/uart-loader-build-rv$xlen-${core_build_tag}-p$soc_profile-ltcm$local_tcm.log" 2>&1 || { tail -n 40 "logs/uart-loader-build-rv$xlen-${core_build_tag}-p$soc_profile-ltcm$local_tcm.log"; exit 1; }
extra_args=()
log="logs/uart-loader-rv$xlen-${core_build_tag}-p$soc_profile-ltcm$local_tcm.log"
max_cycles=4000000
"$sim/Vtb_uart_loader" +IMEM="$out/imem.hex" +DMEM="$out/dmem.hex" \
    +TOHOST="${LOADER_TOHOST:-01100000}" +CONSOLE="${LOADER_CONSOLE:-01100008}" \
    +TEST=uart-loader +MAX_CYCLES="$max_cycles" \
    "${extra_args[@]}" \
    +WIRE="$out/wire.hex" +WIRE_BYTES="$(cat "$out/wire.size")" \
    > "$log" 2>&1 || { tail -n 40 "$log"; exit 1; }
grep 'PASS' "$log"
