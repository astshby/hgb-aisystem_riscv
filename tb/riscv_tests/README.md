# A4 + B riscv-tests Validation

This flow compiles the fixed upstream snapshot under
`tb/riscv_tests/vendor/riscv-tests/`. A local M-mode environment supplies reset,
linking, memory-image generation, trap entry, and tohost PASS/FAIL reporting so
the tests match the A4 core boundary plus the implemented RV32M/RV64M extension.

The optional root `riscv-tests/` clone is ignored and used only for reading or
comparison. A fresh clone of this repository already contains everything needed
for the regression. Put every CPU-specific environment or test-list change in
this directory or `scripts/verilator/`; do not patch vendored upstream files.

Run from the repository root:

```bash
make riscv-tests XLEN=32
make riscv-tests XLEN=64
```

The selected MI set covers Zicsr operations, machine CSR identification,
ECALL/EBREAK, illegal instructions, `mret`, counter writes, and all implemented
misalignment traps. The UI set covers applicable RV32I/RV64I arithmetic,
control-flow, memory, and bypass cases. All 8 RV32UM and 13 RV64UM tests cover
M arithmetic, signedness, division edge cases, and W forms. The runner uses
`rv32im_zicsr/ilp32` or `rv64im_zicsr/lp64`. Generated ELF files, dumps, memory
images, and logs stay under ignored `build/` and `logs/` directories.

Tests requiring features beyond A4 are intentionally excluded: debug triggers
(`breakpoint`), writable `misa`/C (`ma_fetch`), PMP, U/S modes, and Zicntr user
aliases (`cycle`/`instret`). RV32 `instret_overflow` is not yet selected by the
runner; RV64 is included. A5 did add `minstreth`, so the earlier missing-high-CSR
explanation no longer describes the hardware boundary.

The formal regression passes RV32 58/58 (MI 10 + UI 40 + UM 8) and RV64 78/78
(MI 13 + UI 52 + UM 13). It explicitly skips `fence_i` and `ma_data`, which remain outside the
present Zifencei/Harvard and misaligned-completion policy. See the root
`docs/understand/SOFTWARE_TEST_STACK_GUIDE.md` for the full software-to-hardware path and why
these cases do not block CoreMark.

A4 currently handles synchronous machine-mode exceptions only. `mie`/`mip` and
external, timer, or software interrupt delivery remain reserved for the later
interrupt stage even though their architectural encodings already exist in
`riscv_priv_pkg`.

All runners explicitly enable Verilator assertions and reject fatal-error logs,
even when a simulator process exits successfully. Test completion breaks the
sampling loop before `$finish`, preventing fall-through into the timeout path.
