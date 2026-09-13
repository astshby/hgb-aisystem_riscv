# Repository Guidelines

## Project Structure

Keep portable RTL in `vsrc/core/`, packages in `vsrc/pkg/`, simulation models in
`vsrc/sim_cpu/`, and the FPGA wrapper in `vsrc/cpu/`. Put unit tests in
`tb/unit/`, directed CPU tests in `tb/core/`, and the upstream ISA-test adapter
in `tb/riscv_tests/`. Source lists and runners belong in `scripts/`. Generated
files stay under ignored `build/`, `logs/`, or `vivado-workspace/`.

## RTL and Comment Style

Use SystemVerilog, four-space indentation, lowercase module/file names, explicit
ports, `logic`, `always_comb`, and `always_ff` with nonblocking assignments.
Prefer typed enums and packed structs to naked control values. Separate
unrelated combinational and sequential behavior into functional blocks.

Retain every module's `Module` and `Description` header. Preserve useful comments
during moves, renames, merges, and refactors; change them only with behavior.
Comments should explain boundaries, protocols, priority, or non-obvious timing.
Do not prefix RTL block comments with `1.`, `2.`, etc. Prefer Chinese for new
explanatory inline comments while retaining accurate headers.

## Review Before Modification

Treat `main` and reviewed stage branches as protected. Before changing a completed
stage, inspect it, explain the proposed behavior and affected files, and wait for
approval. Then change only that scope. Never discard, overwrite, or commit
unrelated user changes, delete comments silently, or restore an older
implementation over the reviewed version.

## Tests and Change Records

RTL changes require focused tests and regression. TBs declare
`timeunit 1ns` and `timeprecision 1ps`, use deterministic clock-edge stimulus,
and print `PASS`. Run both widths for shared RTL:

```bash
make test XLEN=32
make test XLEN=64
make riscv-tests XLEN=32
make riscv-tests XLEN=64
make benchmark-smoke XLEN=32
make benchmark-smoke XLEN=64
make coremark XLEN=32
make coremark XLEN=64
```

`make test` excludes riscv-tests and benchmarks. Run benchmark targets when C
runtime, CSR counters, ISA behavior, memory timing, or benchmark support changes.
Do not edit `benchmark/coremark/vendor/coremark/`; port changes belong outside the
vendor snapshot. Report exact PASS/SKIP counts and anything not run. Record stage
changes, architectural or timing effects, affected files, and results in
`docs/COMMIT.md`.

## Documentation Synchronization

Update the matching `docs/` file whenever a target, feature, module responsibility,
interface, directory, command, tool, or FPGA workflow changes. Keep `README.md`
current. Separate hardware and software plans into their roadmaps. Maintain only
this root `AGENTS.md`. Put explanatory learning notes under `docs/understand/`.

## Branches and Pull Requests

Contributors and agents use a purpose-specific branch; never push
directly to `main`. Keep commits reviewable and include tests. PRs describe
behavior, files, timing/protocol effects, and exact results; link issues and add
waveforms or FPGA reports when relevant. The project maintainer reviews and
merges; contributors do not self-merge. Delete a stage branch only after its
history is reachable from the reviewed target. Treat `riscv-tests/` as a
read-only clone: never stage or modify it. Keep local adapters and test lists
under `tb/riscv_tests/` or `scripts/`.
