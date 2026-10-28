.PHONY: yolo
YOLO_OUT ?=
yolo:
	python3 scripts/verilator/run_yolo.py --xlen $(XLEN) $(if $(strip $(YOLO_OUT)),--output "$(YOLO_OUT)")

.PHONY: npu-test
NPU_TEST_OUT ?= build/npu-axi/run-rv$(XLEN)
npu-test:
	python3 scripts/verilator/run_npu_tests.py --output $(NPU_TEST_OUT) --xlen $(XLEN)

