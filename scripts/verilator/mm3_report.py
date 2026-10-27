#!/usr/bin/env python3
"""Compare raw DUT results; only simulated RISC-V cycles enter the speedup."""
import hashlib
import json
import pathlib
import struct
import subprocess
import sys
build, logs = map(pathlib.Path, sys.argv[1:3])
mode, case, trace = map(int, sys.argv[3:6])
def fail(reason, **details):
    path=logs / f"report-m{mode}-c{case}-t{trace}-failure.json"
    path.write_text(json.dumps({"correctness":"fail","reason":reason,**details},ensure_ascii=False,indent=2)+"\n")
    raise SystemExit(f"FAIL {reason}; {path}")
records = []
for backend in (0, 1):
    path = build / f"m{mode}-c{case}-t{trace}-b{backend}.bin"
    words = struct.unpack("<128I", path.read_bytes())
    if words[0] != 0x4D335253 or words[1:4] != (backend, mode, case) or words[121]:
        fail("malformed result", file=str(path))
    records.append(words)
a, b = records
reference = struct.unpack("<128I", (build / f"m{mode}-c{case}-reference.bin").read_bytes())
if (a[4:11],a[12:80]) != (reference[4:11],reference[12:80]) or a[112:120] != reference[112:120]:
    fail("RTL software differs from independent host C reference", cpu=list(a[4:16]), reference=list(reference[4:16]), cpu_ids=list(a[16:16+a[6]]), reference_ids=list(reference[16:16+reference[6]]))
if (a[4:11],a[12:80]) != (b[4:11],b[12:80]) or a[112:120] != b[112:120]:
    fail("CPU/accelerator state, token or statistic mismatch", cpu=list(a[4:16]), accel=list(b[4:16]), cpu_ids=list(a[16:16+a[6]]), accel_ids=list(b[16:16+b[6]]))
if a[15]>=3:
    vectors=[(build / f"m{mode}-c{case}-t{trace}-b{backend}.bin.values").read_bytes() for backend in (0,1)]
    expected=(build / f"m{mode}-c{case}-reference.bin.values").read_bytes()
    if vectors[0]!=expected or vectors[1]!=expected:
        fail("exact output integers/scales differ from host reference", sizes=[len(v) for v in vectors]+[len(expected)])
input_ids=None
if trace:
    x = (build / f"m{mode}-c{case}-t1-b0.bin.trace").read_bytes()
    y = (build / f"m{mode}-c{case}-t1-b1.bin.trace").read_bytes()
    z = (build / f"m{mode}-c{case}-reference.trace").read_bytes()
    if mode==3 and len(x)>=32 and x[:8]==b"MM3ITR01":
        node,n,bits,groups=struct.unpack_from('<4I',x,8)
        if node==195 and bits==32 and groups==1 and n==a[5]:
            input_ids=list(struct.unpack_from(f'<{n}I',x,32))
    if x != y or x != z:
        left,right=(x,y) if x!=y else (x,z)
        pos = next((i for i,(u,v) in enumerate(zip(left,right)) if u!=v),min(len(left),len(right)))
        fail("node trace mismatch", first_byte=pos, sizes=[len(x),len(y),len(z)])
def u64(w, i):
    return w[i] | (w[i + 1] << 32)
report = {
    "mode": mode, "case": case, "workload": {0:"smoke_gemv",1:"real_matrix",2:"single_layer",3:"full_model",4:"concurrent_dma_smoke"}[mode], "diagnostic_trace": bool(trace),
    "metadata": json.loads((build / "metadata.json").read_text()),
    "elf_sha256": hashlib.sha256((build / "program.elf").read_bytes()).hexdigest(),
    "state_hash": a[4], "input_tokens": a[5], "generated_ids": list(a[16:16+a[6]]),
    "decode_steps": a[7], "cpu_prefill_cycles": u64(a, 80), "accel_prefill_cycles": u64(b, 80),
    "cpu_decode_cycles": u64(a, 82), "accel_decode_cycles": u64(b, 82),
    "driver_cycles": u64(b, 84), "cache_cycles": u64(b, 86), "submission_cycles": u64(b, 88),
    "polling_cycles": u64(b, 90), "buffer_copy_cycles": u64(b, 92),
    "hardware_cycles": [u64(b, i) for i in range(96, 112, 2)],
    "cpu_first_token_cycles": u64(a,122) if a[15]>=2 else None, "accel_first_token_cycles": u64(b,122) if b[15]>=2 else None,
    "cpu_startup_cycles": u64(a,124) if a[15]>=2 else None, "accel_startup_cycles": u64(b,124) if b[15]>=2 else None,
    "cpu_forced_step_cycles": u64(a,126) if a[15]>=2 else None, "accel_forced_step_cycles": u64(b,126) if b[15]>=2 else None,
    "trace_bytes": a[120], "correctness": "pass", "output_values_exact": a[15]>=3,
    "max_abs_output_error": 0 if a[15]>=3 else None, "output_rmse": 0 if a[15]>=3 else None,
    "node_trace_exact": True if trace else None, "input_ids": input_ids,
    "input_ids_exact": True if input_ids is not None else None,
    "counter_overlap": "DDR stall counts overlap load/write phases",
    "timing_scope": "matrix/model execution including driver/cache/DMA; consult frozen source for prefill loop timing; load/tokenization/console excluded",
}
cpu, accel = u64(a,80)+u64(a,82), u64(b,80)+u64(b,82)
if mode==3 and a[15]>=2:
    report["cpu_generation_phase_cycles"]=report["cpu_decode_cycles"]
    report["accel_generation_phase_cycles"]=report["accel_decode_cycles"]
    report["cpu_decode_cycles"]=max(0,u64(a,82)-(u64(a,122)-u64(a,80)))
    report["accel_decode_cycles"]=max(0,u64(b,82)-(u64(b,122)-u64(b,80)))
    report["cpu_decode_cycles_per_step"]=report["cpu_decode_cycles"]/a[7] if a[7] else None
    report["accel_decode_cycles_per_step"]=report["accel_decode_cycles"]/b[7] if b[7] else None
report["speedup"] = None if trace else cpu / accel
report["acceleration_achieved"] = None if trace else cpu > accel
path = logs / f"report-m{mode}-c{case}-t{trace}.json"
path.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")
print(f"PASS MM3_COMPARE mode={mode} case={case} trace={trace} speedup={report['speedup']} report={path}")
