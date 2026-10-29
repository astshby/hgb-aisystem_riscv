.PHONY: yolo
YOLO_OUT ?=
yolo:
	python3 scripts/verilator/run_yolo.py --xlen $(XLEN) $(if $(strip $(YOLO_OUT)),--output "$(YOLO_OUT)")

.PHONY: yolo-demo-build yolo-demo-test
yolo-demo-build:
	bash scripts/yolo/build_demo.sh $(XLEN) $(if $(strip $(YOLO_OUT)),"$(YOLO_OUT)","build/yolo/demo-rv$(XLEN)")

yolo-demo-test:
	python3 -m unittest discover -s tb/scripts -p 'test_yolo_demo.py' -v

.PHONY: npu-test
NPU_TEST_OUT ?= build/npu-axi/run-rv$(XLEN)
npu-test:
	python3 scripts/verilator/run_npu_tests.py --output $(NPU_TEST_OUT) --xlen $(XLEN)

