# Bare-metal CoreMark only; RT-Thread is a separate application.
.PHONY: score coremark soc-coremark coremark-snapshot-test
score: coremark coremark-platforms
coremark:
	bash scripts/verilator/run_coremark.sh $(XLEN)
soc-coremark:
	SOC=1 bash scripts/verilator/run_coremark.sh $(XLEN)
coremark-snapshot-test:
	python3 tb/scripts/test_coremark_snapshot.py

# 与综合共用 scripts/benchmark_platforms.json；旧 M0/M1 入口继续保留原定义。
.PHONY: coremark-platforms coremark-platforms-test
COREMARK_PLATFORM_OUT ?= build/unified-coremark/current
COREMARK_PLATFORM_ARGS ?=
coremark-platforms:
	python3 scripts/verilator/run_unified_coremark.py --xlen $(XLEN) --output $(COREMARK_PLATFORM_OUT) $(COREMARK_PLATFORM_ARGS)

coremark-platforms-test:
	python3 -m unittest tb.scripts.test_unified_coremark tb.scripts.test_p2_coremark tb.scripts.test_p2_build_config tb.tools.test_soc_clock_plan tb.tools.test_measurement_constraints

