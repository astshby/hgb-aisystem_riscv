# CoreMark Source Snapshot

The unmodified benchmark sources in `coremark/` come from the official EEMBC
repository at `https://github.com/eembc/coremark.git`.

- Tag: `v1.01`
- Commit: `cfa9ab377835911f23d9b0831c7be302ed1f58de`
- Benchmark-reported version: CoreMark 1.0
- Retrieved: 2026-09-13

The five `core_*.c` files and `coremark.h` are kept byte-for-byte unchanged.
`README.md` and `LICENSE.md` preserve the upstream run rules and license. The
local `port/ee_printf.c` is derived from upstream `barebones/ee_printf.c`; only
the character sink is connected to `benchmark_putchar()`.

Do not edit files under `vendor/coremark/`. Platform changes belong in
`benchmark/coremark/port/`, `benchmark/bsp/`, or the build scripts.
