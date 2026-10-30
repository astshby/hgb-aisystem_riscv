# YOLO 程序、模型与测试图片

完整 C 程序在本目录：`demo_main.c` 接收 UART 命令，`network.c` 执行完整图，
`conv_schedule.c` 调度 NPU，`network_service.c` 管理模型/图片，`video_service.c` 提交显示。
电脑串口客户端为 `scripts/yolo/host.py`。本分支不使用 RT-Thread。

`assets/yolox-tiny-320.bin` 和 `assets/yolox-tiny-416.bin` 是正式模型包，随 Git 提交；
每包含完整 83 Conv、266 节点和真实 INT8 权重。`assets/manifest.json` 固定文件长度和 SHA256。
它们分别与历史导出值 50fb5df5…、48138514…完全一致。原 FP32 checkpoint 单独按固定 URL/SHA 获取。
YOLOX 来源、九份原始源文件 SHA 和 checkpoint SHA 在 `model.lock.json`；
源文件及 Apache-2.0 许可证在 `vendor/YOLOX/`。独立上游 MAC/参数审计摘要为 `model-audit.json`。

```bash
make software-prepare
make software-build XLEN=32
make software-build XLEN=64
make software-test
# 从官方 checkpoint 重新导出两个包，并与已发布完整二进制 SHA 比较。
make yolo-assets-rebuild
```

重新导出不需要安装 PyTorch，不需要旧 YOLO-accelerate 目录。下载缓存为本目录 `.cache/`，
模型与测试图片是 Git 文件；删除 build 不影响它们。Python 依赖见 `software/requirements.txt`。
`software-prepare` 首次下载约 39 MiB 官方 checkpoint 并导出到 `.cache/`，逐包比较已发布 SHA；
它不覆盖 Git 保存的模型或报告。已有同一 checkpoint 时可设置 `YOLO_CHECKPOINT` 指向本地文件，仍检查完整 SHA。
RV64 的纯 IM 数学库从随库保存的源文件重建，不链接带 C/F/D 指令的默认库。
固件仍保存在 build/yolo/demo-rv32 或 demo-rv64，manifest 记录源码、配置和 ELF/HEX 哈希。

## 固定测试集

`tb/assets/yolo/` 保存原始 dog.jpg、192×144 UART 图片、320/416 的 RGB888 输入、
全黑输入和测试用例清单。每份输入有 SHA256。`make yolo-dataset-test` 对两个模型各运行
有目标/空白图片，检查 83 次卷积、266 个节点和类别集合。使用电脑执行完整整数 C 图；
程序不把该结果记为 NPU 或 FPGA 整网结果。这是固定回归图片集，没有执行完整 COCO 精度评测。
`expected-native.json` 保存原 C 算法在固定输入上的回归输出。该预处理下 INT8 的有目标图片
类别为 1/2/16，原 FP32 图片参考为 1/2/15；回归一致不代表量化后的分类精度与 FP32 相同。

```bash
# 实际 RV32 驱动、UART/总线/显示分别有显式 RTL 入口。
make yolo-driver-test XLEN=32
make yolo-video-test XLEN=32
make yolo-io-test XLEN=32
make yolo-demo-cosim-full \
  YOLO_IO_LIBRARY=build/yolo/io-rv32/model/libyolo_demo_io.so \
  YOLO_MODEL=software/yolo/assets/yolox-tiny-320.bin \
  YOLO_IMAGE=tb/assets/yolo/dog-192x144.rgb YOLO_WIDTH=192 YOLO_HEIGHT=144
```

最后一个入口先运行上一步生成的真实 UART/NPU/总线/显示模型，C 图调度在电脑执行，
整网协同仿真可能数小时。真实 RV32 板端整网、Flash 启动和板上 HDMI 仍需上板验证。
板端收发命令从 `python3 scripts/yolo/host.py --help` 开始；波特率默认 115200。
