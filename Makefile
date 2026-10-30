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

# Main exposes shared checks, layered CoreMark and the board UART application.
include scripts/make/checks.mk
include scripts/make/software.mk
-include scripts/make/coremark.mk

.PHONY: help check
help:
	@printf '%s\n' 'make software-list|software-doctor|software-prepare|software-build|software-test [XLEN=32|64|both]'
	@printf '%s\n' 'make check XLEN=32|64' 'SOFTWARE_OPT=O2|O3|Ofast (default O3)'
ifneq ($(wildcard scripts/make/coremark.mk),)
	@printf '%s\n' 'make score (M0 + runnable CoreMark platforms)'
	@printf '%s\n' 'make coremark-board (persistent UART firmware; RV32|64)' 'make coremark-board-test (software tests)' 'make coremark-board-uart (short RTL UART test; builds a model)'
endif
check: test scoreboard-test riscv-tests soc-test soc-riscv-tests soc-system-test soc-axi-test tcm-bram-test benchmark-smoke
