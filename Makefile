VERILATOR ?= verilator
XLEN ?= 32

VFLAGS := -Wall -Wno-fatal --timing -DCORE_XLEN=$(XLEN)

.PHONY: lint unit directed riscv-tests benchmark-smoke coremark test clean vivado-project

lint:
	$(VERILATOR) $(VFLAGS) --lint-only -f scripts/rtl_files.f --top-module core
	$(VERILATOR) $(VFLAGS) --lint-only -f scripts/sim_files.f --top-module sim_cpu_top
	$(VERILATOR) $(VFLAGS) --lint-only -f scripts/cpu_files.f --top-module cpu_top

unit:
	bash scripts/verilator/run_unit.sh $(XLEN)

directed:
	bash scripts/verilator/run_directed.sh $(XLEN)

riscv-tests:
	bash scripts/verilator/run_riscv_tests.sh $(XLEN)

benchmark-smoke:
	bash scripts/verilator/run_benchmark_smoke.sh $(XLEN)

coremark:
	bash scripts/verilator/run_coremark.sh $(XLEN)

test: lint unit directed

vivado-project:
	mkdir -p vivado-workspace
	cd vivado-workspace && vivado -mode batch -source ../scripts/vivado/create_project.tcl -tclargs $(XLEN)

clean:
	rm -rf build logs vivado-workspace
