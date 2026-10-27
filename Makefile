VERILATOR ?= verilator
XLEN ?= 32
MUL_IMPL ?= 0
DIV_IMPL ?= 0
PREDICTOR_MODE ?= 0
RAS_ENABLE ?= 0
RETIRE_ENTRIES ?= 4
ISSUE_WIDTH ?= 1
CORE_BACKEND ?= legacy
SPLIT_ISSUE_QUEUE ?= 0
INTEGER_QUEUE_ENTRIES ?= 8
MEMORY_QUEUE_ENTRIES ?= 4
LIMITED_INTEGER_OOO ?= 0
SCHEDULER_FORWARD_MODE ?= 0
export MUL_IMPL DIV_IMPL PREDICTOR_MODE RAS_ENABLE RETIRE_ENTRIES ISSUE_WIDTH CORE_BACKEND
export SPLIT_ISSUE_QUEUE INTEGER_QUEUE_ENTRIES MEMORY_QUEUE_ENTRIES LIMITED_INTEGER_OOO SCHEDULER_FORWARD_MODE

VFLAGS := -Wall -Wno-fatal --assert --timing -DCORE_XLEN=$(XLEN) -DCORE_MUL_IMPL=$(MUL_IMPL) -DCORE_DIV_IMPL=$(DIV_IMPL) -DCORE_PREDICTOR_MODE=$(PREDICTOR_MODE) -DCORE_RAS_ENABLE=$(RAS_ENABLE) -DCORE_RETIRE_ENTRIES=$(RETIRE_ENTRIES) -DCORE_ISSUE_WIDTH=$(ISSUE_WIDTH)
ifeq ($(CORE_BACKEND),scoreboard)
VFLAGS += -DCORE_SCOREBOARD
VFLAGS += -DCORE_SPLIT_ISSUE_QUEUE=$(SPLIT_ISSUE_QUEUE) -DCORE_ISSUE_QUEUE_ENTRIES=$(INTEGER_QUEUE_ENTRIES) -DCORE_MEMORY_QUEUE_ENTRIES=$(MEMORY_QUEUE_ENTRIES) -DCORE_LIMITED_INTEGER_OOO=$(LIMITED_INTEGER_OOO) -DCORE_SCHEDULER_FORWARD_MODE=$(SCHEDULER_FORWARD_MODE)
endif

.PHONY: lint unit directed riscv-tests benchmark-smoke coremark mdu-backends test clean vivado-project soc-test soc-decode-test soc-smoke soc-coremark soc-lint soc-software soc-dma-software soc-riscv-tests

lint:
	$(VERILATOR) $(VFLAGS) --lint-only -f scripts/rtl_files.f --top-module core
	$(VERILATOR) $(VFLAGS) --lint-only -f scripts/sim_files.f --top-module sim_cpu_top
	$(VERILATOR) $(VFLAGS) --lint-only -f scripts/cpu_files.f --top-module cpu_top

unit:
	bash scripts/verilator/run_unit.sh $(XLEN)

directed:
	bash scripts/verilator/run_directed.sh $(XLEN)

.PHONY: retire-queue-test
retire-queue-test:
	bash scripts/verilator/run_retire_queue.sh $(XLEN)

.PHONY: c5-core-test
c5-core-test:
	bash scripts/verilator/run_dual_issue.sh $(XLEN)

.PHONY: scoreboard-test
scoreboard-test:
	bash scripts/verilator/run_scoreboard.sh $(XLEN)

.PHONY: retire-integration-test
retire-integration-test:
	bash scripts/verilator/run_retire_integration.sh $(XLEN)

.PHONY: retire-operands-test
retire-operands-test:
	bash scripts/verilator/run_retire_operands.sh $(XLEN)

.PHONY: predictor-units-test
predictor-units-test:
	bash scripts/verilator/run_predictor_units.sh $(XLEN)

.PHONY: completion-channels-test
completion-channels-test:
	bash scripts/verilator/run_completion_channels.sh $(XLEN)

.PHONY: nonblocking-core-test
nonblocking-core-test:
	bash scripts/verilator/run_nonblocking_core.sh $(XLEN)

.PHONY: lsu-transaction-test
lsu-transaction-test:
	bash scripts/verilator/run_lsu_transaction.sh $(XLEN)

.PHONY: lsu-ownership-test
lsu-ownership-test:
	bash scripts/verilator/run_lsu_ownership.sh $(XLEN) unit
	bash scripts/verilator/run_lsu_ownership.sh $(XLEN) core


.PHONY: predictor-retire-test
predictor-retire-test:
	bash scripts/verilator/run_predictor_retire.sh $(XLEN) unit
	bash scripts/verilator/run_predictor_retire.sh $(XLEN) core

.PHONY: nonblocking-lsu-test
nonblocking-lsu-test:
	bash scripts/verilator/run_nonblocking_lsu.sh $(XLEN)

.PHONY: timing-boundary-random-test
timing-boundary-random-test:
	bash scripts/verilator/run_timing_boundary_random.sh $(XLEN)

.PHONY: pango-handoff-test
pango-handoff-test:
	python3 -B tb/tools/test_pango_handoff.py
	python3 -B tb/tools/test_pango_timing_summary.py
	python3 -B tb/tools/test_pango_memory_flow.py

.PHONY: store-result-monitor-test
store-result-monitor-test:
	bash scripts/verilator/run_store_result_monitor.sh $(XLEN)

riscv-tests:
	bash scripts/verilator/run_riscv_tests.sh $(XLEN)

benchmark-smoke:
	bash scripts/verilator/run_benchmark_smoke.sh $(XLEN)

coremark:
	bash scripts/verilator/run_coremark.sh $(XLEN)

.PHONY: coremark-snapshot-test soc-throughput-test
coremark-snapshot-test:
	python3 tb/scripts/test_coremark_snapshot.py

soc-throughput-test:
	bash scripts/verilator/run_soc_throughput.sh $(XLEN)

.PHONY: bus-locked-grant-test
bus-locked-grant-test:
	bash scripts/verilator/run_bus_locked_grant.sh $(XLEN)

.PHONY: soc-local-tcm-test
soc-local-tcm-test:
	bash scripts/verilator/run_soc_local_tcm.sh $(XLEN)

# SoC 基础设施单独验证；暂不改变既有 Core-only 回归入口。
soc-riscv-tests:
	SOC=1 bash scripts/verilator/run_riscv_tests.sh $(XLEN)

soc-software:
	bash scripts/verilator/run_soc_software.sh $(XLEN)

soc-dma-software:
	bash scripts/verilator/run_dma_software.sh $(XLEN)

.PHONY: soc-dma-wide-test
soc-dma-wide-test:
	bash scripts/verilator/run_dma_wide.sh $(XLEN)

.PHONY: soc-block-test
soc-block-test:
	bash scripts/verilator/run_block_backends.sh $(XLEN)
	bash scripts/verilator/run_block_arbiter.sh $(XLEN)
	bash scripts/verilator/run_ddr_block_adapter.sh $(XLEN)
	bash scripts/verilator/run_cache_block.sh $(XLEN)
	bash scripts/verilator/run_cache_block_axi.sh $(XLEN)

soc-smoke:
	SOC=1 bash scripts/verilator/run_benchmark_smoke.sh $(XLEN)

soc-coremark:
	SOC=1 bash scripts/verilator/run_coremark.sh $(XLEN)

# 与综合共用 scripts/benchmark_platforms.json；旧 M0/M1 入口继续保留原定义。
.PHONY: coremark-platforms coremark-platforms-test
COREMARK_PLATFORM_OUT ?= build/unified-coremark/current
COREMARK_PLATFORM_ARGS ?=
coremark-platforms:
	python3 scripts/verilator/run_unified_coremark.py --xlen $(XLEN) --output $(COREMARK_PLATFORM_OUT) $(COREMARK_PLATFORM_ARGS)

coremark-platforms-test:
	python3 -m unittest tb.scripts.test_unified_coremark tb.scripts.test_p2_coremark tb.scripts.test_p2_build_config tb.tools.test_soc_clock_plan tb.tools.test_measurement_constraints

soc-lint:
	$(VERILATOR) $(VFLAGS) --lint-only -f scripts/soc_files.f --top-module soc_top

soc-test:
	bash scripts/verilator/run_soc.sh $(XLEN)

soc-decode-test:
	bash scripts/verilator/run_address_decode.sh $(XLEN)

.PHONY: soc-profile-test soc-profile-structure-test
soc-profile-test:
	bash scripts/verilator/run_soc_profile.sh $(XLEN)

soc-profile-structure-test:
	bash scripts/verilator/run_soc_profile_structure.sh $(XLEN)

.PHONY: cache-test
cache-test:
	bash scripts/verilator/run_cache.sh $(XLEN)

test: lint unit directed

# 先生成并验证正式 ISA 镜像，矩阵再复用 UM 镜像验证全部后端组合。
mdu-backends: riscv-tests
	bash scripts/verilator/run_mdu_backends.sh $(XLEN)

vivado-project:
	mkdir -p vivado-workspace
	cd vivado-workspace && vivado -mode batch -source ../scripts/vivado/create_project.tcl -tclargs $(XLEN)

clean:
	rm -rf build logs vivado-workspace

.PHONY: rt-thread-fetch rt-thread rt-thread-coremark
rt-thread-fetch:
	bash scripts/rt-thread/fetch.sh

rt-thread:
	bash scripts/rt-thread/run.sh $(XLEN)

rt-thread-coremark:
	bash scripts/rt-thread/run_coremark.sh $(XLEN)

.PHONY: loader loader-host-test loader-soc-test uart-rt-thread-test
loader:
	bash scripts/loader/build.sh $(XLEN)
loader-host-test:
	bash scripts/loader/test_host.sh
loader-soc-test:
	bash scripts/loader/test_soc.sh $(XLEN)
uart-rt-thread-test:
	bash scripts/loader/test_rt_thread.sh $(XLEN)

# MiniMind uses real RTL CPU cycles for both backends, with a shared ELF.
.PHONY: mm3-accel-unit mm3-accel-soc mm3-benchmark mm3-model-compare
mm3-accel-unit:
	VERILATOR="$(VERILATOR)" bash scripts/verilator/run_mm3.sh unit $(XLEN)
mm3-accel-soc:
	VERILATOR="$(VERILATOR)" bash scripts/verilator/run_mm3.sh soc $(XLEN)
mm3-benchmark:
	VERILATOR="$(VERILATOR)" bash scripts/verilator/run_mm3.sh benchmark $(XLEN)
mm3-model-compare:
	VERILATOR="$(VERILATOR)" bash scripts/verilator/run_mm3.sh model $(XLEN)

# Integer operators: only the explicit simulation targets below execute a DUT.
.PHONY: mm3-config mm3-static-check mm3-ref mm3-op-test mm3-attn-test mm3-layer-test mm3-layer-soc
mm3-config:
	python3 scripts/verilator/mm3_config.py
mm3-static-check:
	VERILATOR="$(VERILATOR)" bash scripts/verilator/run_mm3_ops.sh static $(XLEN)
mm3-ref:
	bash scripts/verilator/run_mm3_ops.sh ref $(XLEN)
mm3-op-test:
	VERILATOR="$(VERILATOR)" bash scripts/verilator/run_mm3_ops.sh op $(XLEN)
mm3-attn-test:
	VERILATOR="$(VERILATOR)" bash scripts/verilator/run_mm3_ops.sh attn $(XLEN)
mm3-layer-test:
	VERILATOR="$(VERILATOR)" bash scripts/verilator/run_mm3_ops.sh layer $(XLEN)
mm3-layer-soc:
	VERILATOR="$(VERILATOR)" bash scripts/verilator/run_mm3_ops.sh soc $(XLEN)
mm3-accel-unit mm3-accel-soc mm3-benchmark mm3-model-compare: mm3-config

.PHONY: soc-system-test soc-axi-test soc-irq-cdc-test
# P2 入口只替换本 Makefile 的通用默认值；环境和命令行选择仍优先。
ifeq ($(origin CORE_BACKEND),file)
soc-system-test soc-axi-test soc-irq-cdc-test: CORE_BACKEND = scoreboard
endif
ifeq ($(origin ISSUE_WIDTH),file)
soc-system-test soc-axi-test soc-irq-cdc-test: ISSUE_WIDTH = 2
endif
ifeq ($(origin RETIRE_ENTRIES),file)
soc-system-test soc-axi-test soc-irq-cdc-test: RETIRE_ENTRIES = 16
endif
ifeq ($(origin DIV_IMPL),file)
soc-system-test soc-axi-test soc-irq-cdc-test: DIV_IMPL = 1
endif
soc-system-test:
	bash scripts/verilator/run_soc_system.sh $(XLEN)

soc-axi-test:
	bash scripts/verilator/run_axi_system.sh $(XLEN)

soc-irq-cdc-test:
	bash scripts/verilator/run_soc_irq_cdc.sh $(XLEN)
