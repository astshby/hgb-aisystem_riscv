# Repository Guidelines

## Project Structure

Keep portable RTL in `vsrc/core/`, packages in `vsrc/pkg/`, simulation models in
`vsrc/sim_cpu/`, and the FPGA wrapper in `vsrc/cpu/`. Put unit tests in
`tb/unit/`, directed CPU tests in `tb/core/`, and the upstream ISA-test adapter in
`tb/riscv_tests/`. Source lists and runners belong in `scripts/`. Generated files
stay under ignored `build/`, `logs/`, or `vivado-workspace/`.

Run Pango synthesis and place-and-route with Windows PDS. Keep generated IP,
native projects, netlists, implementation logs, and raw tool reports under
`$PDS_WORK_ROOT`; use a fresh directory for each run. Treat
`$PDS_WORK_ROOT/reference` as read-only. Review
documented placement-memory failures and current Windows memory before
implementation; do not change paging, terminate unrelated processes, or program a
board without explicit approval.

## RTL and Comment Style

Use SystemVerilog, four-space indentation, lowercase module/file names, explicit
ports, `logic`, `always_comb`, and `always_ff` with nonblocking assignments.
Prefer typed enums and packed structs to naked control values. Separate unrelated
combinational and sequential behavior into functional blocks.

Use `if`/`else` when conditions can overlap and behavior requires precedence.
Use `unique case` for proven mutually exclusive selections, with explicit default
behavior. Validate exclusivity; syntax alone does not guarantee better timing.
Name every `for`-generate block using `genvar` with `begin : g_<purpose>`,
including nested generate loops. Leave other blocks unnamed while retaining their
required `begin`/`end`. Group declarations and combinational/sequential blocks by
function; annotate state ownership, meaning, and handshake updates.

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

## One Working Tree, Many Branches

This repository keeps one working tree. Historical checkpoints live as branches,
not as `hgb-work-*` directories or extra worktrees. Start every new task from the
latest reviewed branch and create a new purpose-specific branch; delete a
temporary worktree after its history is reachable. Do not create a permanent
directory per stage.

Each optimization is committed on its own branch with tests and measured results.
Do not mix unrelated optimizations in one commit. Never push directly to `main`;
the maintainer reviews and merges. Contributors do not self-merge.

Hardware snapshots from `../rhbyv-cpu-forlinux` arrive on purpose-specific hgb
branches and require a PR before entering `main`. Preserve collaborators' later
hardware, software, and documents. Software-focused hgb changes remain here and
are not copied back to rhbyv unless explicitly requested.

## Tests and Change Records

RTL changes require focused tests and regression. TBs declare `timeunit 1ns` and
`timeprecision 1ps`, use deterministic clock-edge stimulus, and print `PASS`.
Run both widths for shared RTL:

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
vendor snapshot. Report exact PASS/SKIP counts and anything not run. Record purpose,
behavior, timing/protocol effects, affected files, and results in the workspace
`ITERATIONS.md` and `OPTIMIZATION_PLAN.md`, or in the matching learning document.

## Documentation

All Markdown follows `../skills/regulation.md`. Word/report layout follows
`../skills/typesetting.md` when a Word deliverable is requested.

## Paths and Reproducibility

Tracked files use repository-relative paths. Do not commit user-specific home or
profile paths. Use environment variables for external tools and work roots:

- `RISCV_TOOL_ROOT` for the RISC-V toolchain bin directory.
- `PDS_HOME` for the PDS installation directory.
- `PDS_WORK_ROOT` for generated PDS projects and reports.
- `RTTHREAD_ROOT` for a verified RT-Thread dependency tree.
- `COREMARK_REPLAY_DIR` for a frozen CoreMark snapshot.

Every measured result records the source branch/commit, build parameters, ELF/HEX
identity or hash, exact command, and log location. If fixed images, logs, or
dependencies are missing, say so; do not present a result as exactly replayable
when it is not. New tasks use a new branch.

Keep the documentation set small and current:

| Path | Content |
|---|---|
| `docs/PROJECT_INTRO.md` | project directory, parameters, environment, simulation performance, FPGA performance, features |
| `docs/understand/` | five learning summaries: SoC system, dual issue, DDR/AXI, FPGA, optimization |
| `docs/fpga/` | FPGA adaptation, PDS flow, constraints, timing/resource results |
| `docs/README.md` | index |

Do not create `docs/COMMIT.md`, `post-plan/`, or a per-stage diary. Historical
commit detail is available through `git log`/`git show`. Update the matching
document when a target, feature, module responsibility, interface, directory,
command, tool, or FPGA workflow changes. Keep `README.md` current with the hardware
snapshot and collaboration/software goals. Do not copy these publication documents
back into `rhbyv-cpu-forlinux`.
