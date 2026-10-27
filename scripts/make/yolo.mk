.PHONY: yolo
yolo:
	python3 scripts/verilator/run_yolo.py --xlen $(XLEN)

.PHONY: npu-test
NPU_TEST_OUT ?= build/npu-axi/run-rv$(XLEN)
npu-test:
	python3 scripts/verilator/run_npu_tests.py --output $(NPU_TEST_OUT) --xlen $(XLEN)

