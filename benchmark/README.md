# Benchmark Software

> 写作约束：见工作区根目录的 `skills/regulation.md`。

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
```

Generated ELF files, maps, disassemblies, memory images, and logs stay under
`build/` and `logs/`. `make coremark` runs both performance and validation seeds,
checks the official CRC result, and reports the cycle-normalized CoreMark/MHz.
RV64 currently runs functional/ISA/SoC tests; performance tuning uses RV32.
See [项目介绍](../docs/PROJECT_INTRO.md) before comparing hardware configurations.

`performance` 使用种子 `0, 0, 0x66`，`validation` 使用
`0x3415, 0x3415, 0x66`。两者执行相同算法并检查对应 CRC；输入数据不同会改变分支
和访存过程，因此周期数可以不同。性能目标取 performance 成绩，同时要求两组 CRC
检查通过，并保留 validation 的周期与分数。正式成绩还需满足至少十秒的运行规则；
短仿真仅用于硬件对照。
