# RT-Thread 程序

本目录保存四域完整 SoC 的 BSP、UART/GPIO 驱动、时钟/中断移植、smoke 和交互 demo。
内核源码在 `third_party/rt-thread/`，来自 v5.2.2 提交
ddf52e2cdd977f14fc04035c88672ac204aec713，保留 Apache-2.0 许可证和逐文件 SHA 清单。
内核与 BSP 都随 Git 提交，无需恢复 build/rt-thread-v5.2.2，也不需要额外子模块。

```bash
make software-prepare SOFTWARE_APP=rt-thread
make software-build SOFTWARE_APP=rt-thread XLEN=both
make software-test SOFTWARE_APP=rt-thread
# 独立 RT-Thread 整机 RTL smoke，会编译模拟器并运行 CPU。
make rt-thread XLEN=32
make rt-thread XLEN=64
```

`software-build` 编译常驻 UART demo；`scripts/rt-thread/build.sh 32|64` 默认编译 smoke，
`RTTHREAD_APP=demo` 选择交互程序。输出为 build/rt-thread/system-rv32-O3-demo 等目录，
其中 manifest 记录应用、源码/内核版本、编译器及 ELF/HEX 哈希。
交互命令包含 STATUS、PING、ECHO、DEMO，每轮结束返回 READY；协议测试直接编译同一份 C 解析器。

RT-Thread 在 all 保存一份，仿真使用无 NPU 的完整 SoC。它不参与裸机分层 CoreMark，
没有把 RT 终端吞吐换算为 CoreMark/MHz。DDR 仍须预装程序，Flash/TF 启动尚未实现。
本轮交付不把软件解析测试写成内核调度或 FPGA 板测结果。
