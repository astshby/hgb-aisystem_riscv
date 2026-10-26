# YOLO-accelerate 128-MAC 固定依赖

来源为 [YOLO-accelerate `47ffb55`](https://github.com/astshby/YOLO-accelerate/tree/47ffb558bf35bbe017a136903a7464e93132ea2c)，
选用 RAM 压缩后的 128-MAC 计算通路和分级 MMIO。七份 RTL、C11 接口头文件与
Apache-2.0 许可证保持来源字节，身份见 [manifest.json](manifest.json)。
不包含上游 576-MAC 通路、UART 桥或独立板级 PLL。

hgb 的适配位于 `vsrc/soc/npu/npu_axi_target.sv`，通过系统 AXI、异步 FIFO 和
32 位寄存器访问连接本目录。新修改只进入适配层；更新依赖时重新固定提交、逐文件
哈希并运行 `make npu-test` 和双宽 SoC 卷积测试。
原许可证见 [LICENSE](third_party/adamgallas/LICENSE)，保留源码的 SPDX 与来源注释。

上游独立 100 MHz 布线和 UART 卷积通过；合体 SoC 重新做仿真、综合和物理验收。
该接口提供卷积分块，完整 YOLOX 定点图、板端图调度和 RT-Thread 推理仍需接续。
