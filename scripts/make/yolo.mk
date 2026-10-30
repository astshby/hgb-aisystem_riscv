.PHONY: yolo
YOLO_OUT ?=
yolo:
	python3 scripts/verilator/run_yolo.py --xlen $(XLEN) $(if $(strip $(YOLO_OUT)),--output "$(YOLO_OUT)")

.PHONY: yolo-demo-build yolo-demo-test yolo-video-test yolo-driver-test yolo-io-test yolo-demo-cosim yolo-demo-cosim-full
YOLO_DEMO_TEST_OUT ?= build/yolo/demo-tests
YOLO_VIDEO_OUT ?= build/yolo/video-rv$(XLEN)
YOLO_VIDEO_LOG ?= logs/yolo/video-rv$(XLEN)
YOLO_DRIVER_OUT ?= build/yolo/driver-rv$(XLEN)
YOLO_DRIVER_LOG ?= logs/yolo/driver-rv$(XLEN)
YOLO_IO_OUT ?= build/yolo/io-rv$(XLEN)
YOLO_IO_LOG ?= logs/yolo/io-rv$(XLEN)
YOLO_IO_LIBRARY ?=
YOLO_MODEL ?=
YOLO_IMAGE ?=
YOLO_WIDTH ?=
YOLO_HEIGHT ?=
YOLO_REFERENCE ?=
YOLO_SOFTMATH_ARCHIVE ?=
YOLO_COSIM_BAUD ?= 3000000
YOLO_COSIM_OUT ?= build/yolo/app-tiny
YOLO_COSIM_LOG ?= logs/yolo/app-tiny
YOLO_FULL_OUT ?= build/yolo/app-full
YOLO_FULL_LOG ?= logs/yolo/app-full
yolo-demo-build:
	bash scripts/yolo/build_demo.sh $(XLEN) $(if $(strip $(YOLO_OUT)),"$(YOLO_OUT)","build/yolo/demo-rv$(XLEN)")

# 图算子只选短测方法，不因环境变量中已有模型而隐式执行两次完整网络。
yolo-demo-test:
	YDM_TEST_OUT="$(YOLO_DEMO_TEST_OUT)/protocol" python3 -m unittest discover -s tb/scripts -p 'test_yolo_demo.py' -v
	YDM_EXPORT_TEST_OUT="$(YOLO_DEMO_TEST_OUT)/export" python3 -m unittest discover -s tb/scripts -p 'test_yolo_export.py' -v
	YOLO_NETWORK_OUT="$(YOLO_DEMO_TEST_OUT)/network" python3 -m unittest tb.scripts.test_yolo_network.YoloNetworkTest.test_c_graph_operators -v
	YDM_SERVICE_TEST_OUT="$(YOLO_DEMO_TEST_OUT)/service" python3 -m unittest discover -s tb/scripts -p 'test_yolo_service.py' -v
	YDM_VIDEO_SERVICE_OUT="$(YOLO_DEMO_TEST_OUT)/video" python3 -m unittest discover -s tb/scripts -p 'test_yolo_video_service.py' -v

yolo-video-test:
	python3 scripts/yolo/run_video.py --xlen $(XLEN) --jobs 1 --output "$(YOLO_VIDEO_OUT)" --log-root "$(YOLO_VIDEO_LOG)"

yolo-driver-test:
	python3 scripts/demo/run_driver_smoke.py --xlen $(XLEN) --output "$(YOLO_DRIVER_OUT)" --logs "$(YOLO_DRIVER_LOG)" $(if $(strip $(YOLO_SOFTMATH_ARCHIVE)),--softmath "$(YOLO_SOFTMATH_ARCHIVE)")

yolo-io-test:
	python3 scripts/yolo/run_demo_io.py --xlen $(XLEN) --output "$(YOLO_IO_OUT)" --log-root "$(YOLO_IO_LOG)"

# 两项共同平台入口均由电脑执行 C；full 是显式数小时运行，短测不依赖它。
yolo-demo-cosim:
	python3 scripts/yolo/run_demo_cosim.py --mode tiny --io-library "$(YOLO_IO_LIBRARY)" --model "$(YOLO_MODEL)" --baud $(YOLO_COSIM_BAUD) --output "$(YOLO_COSIM_OUT)" --logs "$(YOLO_COSIM_LOG)"

yolo-demo-cosim-full:
	python3 scripts/yolo/run_demo_cosim.py --mode full --io-library "$(YOLO_IO_LIBRARY)" --model "$(YOLO_MODEL)" --image-rgb "$(YOLO_IMAGE)" --width $(YOLO_WIDTH) --height $(YOLO_HEIGHT) $(if $(strip $(YOLO_REFERENCE)),--reference "$(YOLO_REFERENCE)") --baud $(YOLO_COSIM_BAUD) --output "$(YOLO_FULL_OUT)" --logs "$(YOLO_FULL_LOG)"

.PHONY: npu-test
NPU_TEST_OUT ?= build/npu-axi/run-rv$(XLEN)
npu-test:
	python3 scripts/verilator/run_npu_tests.py --output $(NPU_TEST_OUT) --xlen $(XLEN)

