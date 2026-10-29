#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${MM3_DEMO_OUT:?set MM3_DEMO_OUT to a generated output directory}"
mkdir -p "$out"
cc="${CC:-cc}"
flags=(-std=c11 -O3 -fno-fast-math -ffp-contract=off -Wall -Wextra -DMAX_SEQ_LEN=64
    -Isoftware/minimind3/c_runtime/include -Isoftware/minimind3/demo)
sources=(software/minimind3/demo/{session,protocol,native}.c
    software/minimind3/c_runtime/src/{integer_io,tokenizer,integer_math,integer_ops,integer_model}.c)
"$cc" "${flags[@]}" "${sources[@]}" -o "$out/minimind-interactive"
python3 - "$out" "${sources[@]}" software/minimind3/demo/demo.h software/minimind3/c_runtime/include/{integer,mm3}.h scripts/demo/build_minimind.sh <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
out=Path(sys.argv[1]);sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
receipt=dict(branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),source_sha256={p:sha(p) for p in sys.argv[2:]},binary_sha256=sha(out/'minimind-interactive'),context=64,layers=8,backend='native CPU',optimization='O3',rtl_simulation='NOT_RUN')
(out/'native-build.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
printf 'PASS MiniMind interactive native build: %s\n' "$out/minimind-interactive"
