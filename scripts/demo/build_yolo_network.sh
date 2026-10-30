#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${YOLO_NETWORK_OUT:?set YOLO_NETWORK_OUT to a generated build directory}"
mkdir -p "$out"
cc="${CC:-cc}"
flags=(-std=c11 -O3 -fno-fast-math -ffp-contract=off -Wall -Wextra -Werror -Isoftware/yolo -Itb/yolo)
"$cc" "${flags[@]}" software/yolo/network.c software/yolo/network_native.c -lm -ldl -o "$out/yolo-network-native"
python3 - "$out" software/yolo/{network.c,network.h,network_native.c,conv_schedule.h} tb/yolo/npu_rtl_cosim.h scripts/demo/build_yolo_network.sh <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
out=Path(sys.argv[1]);sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
receipt=dict(commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),source_sha256={p:sha(p) for p in sys.argv[2:]},binary_sha256=sha(out/'yolo-network-native'),backend='native scalar INT8, no RTL',optimization='O3 -fno-fast-math -ffp-contract=off')
(out/'network-native-build.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
printf 'PASS YOLO network native build: %s\n' "$out/yolo-network-native"
