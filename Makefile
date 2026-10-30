.DEFAULT_GOAL := help
VERILATOR ?= verilator
XLEN ?= 32
SOFTWARE_OPT ?= O3
export SOFTWARE_OPT
MUL_IMPL ?= 0
DIV_IMPL ?= 1
PREDICTOR_MODE ?= 1
RAS_ENABLE ?= 0
RETIRE_ENTRIES ?= 16
ISSUE_WIDTH ?= 2
CORE_BACKEND ?= scoreboard
SPLIT_ISSUE_QUEUE ?= 1
INTEGER_QUEUE_ENTRIES ?= 8
MEMORY_QUEUE_ENTRIES ?= 4
LIMITED_INTEGER_OOO ?= 0
SCHEDULER_FORWARD_MODE ?= 3
export MUL_IMPL DIV_IMPL PREDICTOR_MODE RAS_ENABLE RETIRE_ENTRIES ISSUE_WIDTH CORE_BACKEND
export SPLIT_ISSUE_QUEUE INTEGER_QUEUE_ENTRIES MEMORY_QUEUE_ENTRIES LIMITED_INTEGER_OOO SCHEDULER_FORWARD_MODE

# Four publication branches share one reviewed Core profile. Optional software
# targets exist only when that branch retains their make fragment and sources.
include scripts/make/checks.mk
include scripts/make/yolo.mk

.PHONY: help check
help:
	@printf '%s\n' 'make check XLEN=32|64' 'SOFTWARE_OPT=O2|O3|Ofast (default O3)'
ifneq ($(wildcard scripts/make/yolo.mk),)
	@printf '%s\n' 'make yolo (five domains, convolution + DMA overlap)'
	@printf '%s\n' 'make yolo-demo-build XLEN=32|64 (UART RGB/SELFTEST firmware)' 'make yolo-demo-test (lightweight software tests)'
endif
check: test scoreboard-test riscv-tests soc-test soc-riscv-tests soc-system-test soc-axi-test tcm-bram-test benchmark-smoke
