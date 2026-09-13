# Benchmark Software

`bsp/` contains the shared bare-metal startup, linker layout, 64-bit cycle reader,
simulation console, and RV32I/RV64I software arithmetic helpers. `smoke/`
validates that C runtime before a long benchmark. `coremark/vendor/` is the fixed,
unmodified official EEMBC `v1.01` snapshot (benchmark version 1.0);
`coremark/port/` is the rhbyv platform adapter.

Run from the repository root:

```bash
make benchmark-smoke XLEN=32
make benchmark-smoke XLEN=64
make coremark XLEN=32
make coremark XLEN=64
```

Generated ELF files, maps, disassemblies, memory images, and logs stay under
`build/` and `logs/`. `make coremark` runs both performance and validation seeds,
checks the official CRC result, and reports the cycle-normalized CoreMark/MHz.
See `docs/understand/COREMARK_AND_PERFORMANCE.md` before comparing scores.
