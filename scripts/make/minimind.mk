.PHONY: minimind
minimind: mm3-accel-soc mm3-layer-soc

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

# 常驻交互软件单独编译、测试；这些入口不启动 RTL 仿真或 PDS。
MM3_DEMO_OUT ?= build/minimind-demo
export MM3_DEMO_OUT MM3_DEMO_ASSETS
.PHONY: minimind-demo-native minimind-demo-build minimind-demo-test
minimind-demo-native:
	bash scripts/demo/build_minimind.sh
minimind-demo-build:
	bash scripts/demo/build_minimind_board.sh $(XLEN)
minimind-demo-test:
	@test -n "$$MM3_DEMO_ASSETS" || { printf '%s\n' 'Set MM3_DEMO_ASSETS to the verified integer-model/tokenizer directory.' >&2; exit 2; }
	python3 -m unittest -v tb.scripts.test_minimind_demo

