# 软件与复现入口

从仓库根目录运行命令。程序源码、启动文件、链接脚本、串口接收工具和测试都随 Git 提交；
`build/` 只存编译产物，删除后重新执行下列命令。依赖获取和模型导出不从其他人的旧 build 复制。

发布分支的范围如下：

| 分支 | 软件 | 测试与数据 |
|---|---|---|
| main | 分层 CoreMark、完整串口 CoreMark | 官方算法源码、串口协议与结果解析测试 |
| yolo | 完整 YOLO 图调度、NPU 驱动、UART/HDMI 服务 | 图算子、驱动、显示测试及固定图片/模型资产 |
| minimind | 原作者 FP32/整数 C 程序、常驻对话、裸机驱动 | 锁定模型、分词器、算子和八层软件测试 |
| all | 上述软件和唯一一份 RT-Thread BSP/应用 | 各应用测试与双加速器联合仿真 |

当前分支实际入口由 `make software-list` 列出。RT-Thread 仅在 all；它不参加裸机 CoreMark。

Linux/WSL 需要 Python 3.10 以上、Git、Make、C/C++ 编译器和完整 Verilator 安装。
交叉工具链必须支持 `rv32im_zicsr`/`ilp32` 和 `rv64im_zicsr`/`lp64`；不能使用仅含 Linux ABI 的编译器。
本机测量使用过 GCC 16.1.0、Verilator 5.044/5.045；更换工具后重新记录版本及结果。
先把 `RISCV_TOOL_ROOT` 设置为安装好的 `riscv64-unknown-elf-gcc` 所在目录：

```bash
export RISCV_TOOL_ROOT=/path/to/riscv/bin
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r software/requirements.txt
make software-list
make software-doctor
make software-prepare
make software-build XLEN=32
make software-test
```

`SOFTWARE_APP=coremark|yolo|minimind|rt-thread` 可选一个本分支已有的应用；
`software-build XLEN=both` 编译双宽。`software-test` 执行软件测试，完整 RTL 仿真使用各应用的显式入口。
模型准备首次可能访问网络；来源、版本、SHA256 和生成命令保存在对应应用目录。
上板、串口端口和 Windows PDS 许可证需要操作者本机配置，不会由上述命令自动烧录。

## CoreMark

官方 CoreMark v1.01 在 `benchmark/coremark/vendor/coremark/`，平台适配在
`benchmark/coremark/port/`，UART 常驻程序在 `software/coremark-board/`。
`scripts/coremark/host.py` 接收 P/V 原始周期及 CRC，计算 CoreMark/MHz。

```bash
make coremark-board XLEN=32
make coremark-board XLEN=64
make coremark-board-test
python3 scripts/coremark/host.py --help
# 以下会编译并执行真实 CPU/SoC RTL，耗时高于软件测试。
make coremark-board-uart XLEN=32
make coremark XLEN=32
make coremark-platforms XLEN=32 COREMARK_PLATFORM_OUT=build/score-O3 \
  COREMARK_PLATFORM_ARGS='--clocks main_margin2 --iterations 64 --jobs 1 --icache-bytes 16384 --dcache-bytes 8192 --dcache-bank-xor-mask 2'
```

M0 使用测试台一周期存储；`core_tcm` 使用真实 TCM；`soc_tcm` 加入 SoC；
`soc_ddr` 使用 Cache/DDR。CoreMark/MHz 均以 Core 周期计数，跨域时钟比例另记。
默认 O3，可用 `SOFTWARE_OPT=O2`、`SOFTWARE_OPT=Ofast` 对照。64 轮仿真是比较入口；
正式成绩还须检查计时至少十秒。上板固件默认自动标定，运行结束后再次 READY。

PDS/DDR IP 生成与时钟配置见根 README 和 `docs/fpga/FPGA_ADAPTATION.md`；
软件重建不需要已有 PDS 工作目录。
