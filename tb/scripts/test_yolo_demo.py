"""Exercise the real C receiver through the Python serial client, without RTL or model loading."""
import ctypes as C
import importlib.util
import os
from pathlib import Path
import random
import struct
import subprocess
import sys
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("yolo_demo_host", ROOT / "scripts/yolo/host.py")
host = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = host
SPEC.loader.exec_module(host)
PLAN_SPEC = importlib.util.spec_from_file_location("yolo_model_plan", ROOT / "scripts/yolo/model_plan.py")
model_plan = importlib.util.module_from_spec(PLAN_SPEC)
PLAN_SPEC.loader.exec_module(model_plan)

GET = C.CFUNCTYPE(C.c_int, C.c_void_p, C.POINTER(C.c_uint8))
PUT = C.CFUNCTYPE(None, C.c_void_p, C.c_uint8)
STORE = C.CFUNCTYPE(None, C.c_void_p, C.c_uint32, C.c_uint8)
LOAD = C.CFUNCTYPE(C.c_uint8, C.c_void_p, C.c_uint32)
ACTION = C.CFUNCTYPE(C.c_int, C.c_void_p)
NREAD = C.CFUNCTYPE(C.c_uint32, C.c_void_p, C.c_uint32)
NWRITE = C.CFUNCTYPE(None, C.c_void_p, C.c_uint32, C.c_uint32)


def compile_library():
    output = Path(os.environ.get("YDM_TEST_OUT", ROOT / "build/yolo/demo-native"))
    output.mkdir(parents=True, exist_ok=True)
    library = output / "protocol.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                    str(ROOT / "software/yolo/demo_protocol.c"),
                    str(ROOT / "software/yolo/conv_schedule.c"), "-o", str(library)], check=True)
    return C.CDLL(str(library))


class Conv(C.Structure):
    _fields_ = [("input", C.POINTER(C.c_int8)), ("weight", C.POINTER(C.c_int8)),
                ("bias", C.POINTER(C.c_int32)), ("output", C.POINTER(C.c_int32))] + [
                    (name, C.c_uint32) for name in ("width", "height", "cin", "cout", "kernel", "stride", "pad")]


class NpuIO(C.Structure):
    _fields_ = [("read", NREAD), ("write", NWRITE), ("context", C.c_void_p)]


class NpuModel:
    """Scalar register-device substitute checks the driver's actual CSR writes and results."""
    def __init__(self):
        self.regs, self.activations, self.weights = {}, {}, {}
        self.results, self.index, self.started, self.resets = [], 0, 0, 0
        self.bad_meta = self.timeout = self.device_error = False
        self.bad_id = False
        self.violations = []
        self.io = NpuIO(NREAD(self.read), NWRITE(self.write), None)

    def read(self, _, offset):
        if offset == 0:
            return 0 if self.bad_id else 0x4E505531
        if offset == 4:
            return 0x10000
        if offset == 0x14:
            return 24576
        if offset == 0x18:
            return 864
        if offset == 0x10:
            return 8 if self.device_error else 0
        if offset == 0x0C:
            if self.device_error:
                return 8
            return 1 if self.timeout else 3 if self.index < len(self.results) else 4
        if offset == 0x1C:
            return self.index
        if self.index < len(self.results):
            x, y, values, mask = self.results[self.index]
            if offset == 0x58:
                return (mask | x << 16 | y << 24) ^ int(self.bad_meta)
            if offset == 0x5C:
                return 8 | (4 if self.index == len(self.results) - 1 else 0)
            if 0x200 <= offset < 0x240:
                return values[(offset - 0x200) // 4] & 0xFFFFFFFF
        return self.regs.get(offset, 0)

    def write(self, _, offset, value):
        self.regs[offset] = value
        if offset == 8 and value == 2:
            self.activations.clear()
            self.weights.clear()
            self.results, self.index = [], 0
            self.resets += 1
        elif offset == 0x38:
            index = self.regs[0x28]
            if index >= 24576:
                self.violations.append("activation bank/address overflow")
            self.activations[index] = struct.pack("<2I", self.regs[0x60], self.regs[0x64])
        elif offset == 0x3C:
            index = self.regs[0x2C]
            if index >= 864:
                self.violations.append("weight address overflow")
            self.weights[index] = struct.pack("<32I", *(self.regs[0x100 + i * 4] for i in range(32)))
        elif offset == 0x44:
            self.index += 1
        elif offset == 8 and value == 1:
            self.started += 1
            self.calculate()

    def calculate(self):
        shape, options = self.regs[0x20], self.regs[0x24]
        width, height, ci, co = shape & 255, shape >> 8 & 255, shape >> 16, options & 31
        kernel, stride = (3 if options & 32 else 1), (2 if options & 64 else 1)
        if not (1 <= width <= 16 and 1 <= height <= 16 and 1 <= ci <= 768 and 1 <= co <= 16):
            self.violations.append("invalid NPU command shape")
        if options & 0x780:
            self.violations.append("software halo requires pad=0/raw/bank0")
        groups = (ci + 7) // 8
        ow, oh = (width - kernel) // stride + 1, (height - kernel) // stride + 1
        for y in range(oh):
            for x in range(ow):
                values = [0] * 16
                for oc in range(co):
                    value = C.c_int32(self.regs[0x80 + oc * 4]).value
                    for ky in range(kernel):
                        for kx in range(kernel):
                            for ic in range(ci):
                                a = self.activations[((y * stride + ky) * width + x * stride + kx) * groups + ic // 8][ic % 8]
                                w = self.weights[(ky * kernel + kx) * groups + ic // 8][oc * 8 + ic % 8]
                                value += C.c_int8(a).value * C.c_int8(w).value
                    values[oc] = value
                self.results.append((x, y, values, (1 << co) - 1))


class ConvScheduleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = compile_library()
        cls.lib.yolo_conv_s8.argtypes = [C.POINTER(Conv), NpuIO]
        cls.lib.yolo_conv_s8.restype = C.c_int

    def run_case(self, width, height, ci, co, kernel, stride, pad, model=None, expected_error=0):
        model = model or NpuModel()
        image = [((i * 7 + 9) % 17) - 8 for i in range(width * height * ci)]
        weights = [((i * 11 + 5) % 13) - 6 for i in range(co * ci * kernel * kernel)]
        bias = [i - 9 for i in range(co)]
        ow, oh = (width + 2 * pad - kernel) // stride + 1, (height + 2 * pad - kernel) // stride + 1
        ia, wa, ba = (C.c_int8 * len(image))(*image), (C.c_int8 * len(weights))(*weights), (C.c_int32 * co)(*bias)
        output = (C.c_int32 * (ow * oh * co + 2))(*([-0x123456] * (ow * oh * co + 2)))
        conv = Conv(ia, wa, ba, C.cast(C.byref(output, 4), C.POINTER(C.c_int32)),
                    width, height, ci, co, kernel, stride, pad)
        self.assertEqual(self.lib.yolo_conv_s8(C.byref(conv), model.io), expected_error)
        self.assertEqual(output[0], -0x123456)
        self.assertEqual(output[-1], -0x123456)
        self.assertFalse(model.violations)
        if expected_error:
            return model
        expected = []
        for oc in range(co):
            for y in range(oh):
                for x in range(ow):
                    value = bias[oc]
                    for ic in range(ci):
                        for ky in range(kernel):
                            for kx in range(kernel):
                                sx, sy = x * stride + kx - pad, y * stride + ky - pad
                                if 0 <= sx < width and 0 <= sy < height:
                                    value += image[(ic * height + sy) * width + sx] * weights[((oc * ci + ic) * kernel + ky) * kernel + kx]
                    expected.append(value)
        self.assertEqual(list(output)[1:-1], expected)
        return model

    def test_spatial_halo_and_both_channel_tails(self):
        model = self.run_case(19, 17, 9, 17, 3, 1, 1)
        self.assertEqual(model.started, 8)

    def test_stride_two_global_boundaries(self):
        self.run_case(19, 17, 9, 17, 3, 2, 1)

    def test_pointwise_crosses_sixteen_spatial_boundary(self):
        model = self.run_case(19, 17, 3, 17, 1, 1, 0)
        self.assertEqual(model.started, 8)

    def test_maximum_input_channels_weight_address_limit(self):
        model = self.run_case(3, 3, 768, 1, 3, 1, 0)
        self.assertIn(863, model.weights)

    def test_invalid_descriptor_never_starts(self):
        model = NpuModel()
        one, out = (C.c_int8 * 1)(1), (C.c_int32 * 1)(0)
        conv = Conv(one, one, None, out, 1, 1, 769, 1, 1, 1, 0)
        self.assertEqual(self.lib.yolo_conv_s8(C.byref(conv), model.io), 1)
        self.assertEqual(model.started, 0)

    def test_bad_device_id_never_starts(self):
        model = NpuModel()
        model.bad_id = True
        self.run_case(1, 1, 1, 1, 1, 1, 0, model, 2)
        self.assertEqual(model.started, 0)

    def test_bad_result_meta_resets_device(self):
        model = NpuModel()
        model.bad_meta = True
        self.run_case(1, 1, 1, 1, 1, 1, 0, model, 4)
        self.assertEqual(model.resets, 2)

    def test_device_error_and_timeout_reset(self):
        for flag, error in (("device_error", 2), ("timeout", 3)):
            model = NpuModel()
            setattr(model, flag, True)
            self.run_case(1, 1, 1, 1, 1, 1, 0, model, error)
            self.assertEqual(model.resets, 2)


class ModelPlanTests(unittest.TestCase):
    def row(self, **changes):
        row = dict(name="test.conv", input=[1, 9, 19, 17], output=[1, 17, 19, 17],
                   groups=1, kernel=[3, 3], stride=[1, 1], weight_elements=17 * 9 * 9)
        row.update(changes)
        return row

    def test_halo_and_channel_tiles(self):
        row = model_plan.conv_plan(self.row())
        self.assertEqual((row["pad"], row["spatial_tiles"], row["tile_commands"]), (1, [2, 2], 8))
        self.assertEqual((row["input_channel_groups"], row["output_channel_blocks"]), (2, 2))

    def test_max_weight_and_activation_address(self):
        row = model_plan.conv_plan(self.row(input=[1, 768, 3, 3], output=[1, 1, 1, 1],
                                             weight_elements=768 * 9))
        self.assertEqual((row["max_weight_index"], row["max_activation_index"]), (863, 24575))

    def test_unsupported_or_inconsistent_shapes(self):
        for changes in (dict(groups=9), dict(kernel=[5, 5]), dict(stride=[3, 3]),
                        dict(input=[1, 769, 19, 17]), dict(output=[1, 17, 11, 12]),
                        dict(weight_elements=1)):
            with self.assertRaises(ValueError):
                model_plan.conv_plan(self.row(**changes))

    def test_pinned_model_mismatch(self):
        audit = dict(commit="a", model="yolox-tiny", source_sha256={})
        lock = dict(commit="b", model="YOLOX-Tiny", source_sha256={})
        with self.assertRaisesRegex(ValueError, "pinned"):
            model_plan.make_plan(audit, lock, 416)


class IO(C.Structure):
    _fields_ = [("get", GET), ("put", PUT), ("store", STORE), ("load", LOAD),
                ("flush", ACTION), ("selftest", ACTION), ("context", C.c_void_p)]


class Demo(C.Structure):
    _fields_ = [("io", IO)] + [(name, C.c_uint32) for name in
                ("width", "height", "bytes", "received", "expected_crc", "running_crc",
                 "valid", "receiving", "frame_id")] + [("payload", C.c_uint8 * 1028)]


class FirmwareSerial:
    """Only MMIO byte IO, DDR byte storage and maintenance/NPU return values are mocked."""
    def __init__(self, library):
        self.library = library
        self.incoming, self.outgoing = bytearray(), bytearray()
        self.memory = bytearray(1920 * 1080 * 3)
        self.writes = self.maintenance = self.operator_calls = 0
        self.maintenance_error = self.operator_error = 0

        def get(_, pointer):
            if not self.incoming:
                return 0
            pointer[0] = self.incoming.pop(0)
            return 1

        def put(_, byte):
            self.outgoing.append(byte)

        def store(_, offset, byte):
            assert offset < len(self.memory)
            self.memory[offset] = byte
            self.writes += 1

        def load(_, offset):
            assert offset < len(self.memory)
            return self.memory[offset]

        def flush(_):
            self.maintenance += 1
            return self.maintenance_error

        def selftest(_):
            self.operator_calls += 1
            return self.operator_error

        self.io = IO(GET(get), PUT(put), STORE(store), LOAD(load), ACTION(flush), ACTION(selftest), None)
        self.demo = Demo()
        library.ydm_init(C.byref(self.demo), self.io)
        library.ydm_ready(C.byref(self.demo))

    def write(self, data):
        self.incoming.extend(data)
        self.library.ydm_receive_one(C.byref(self.demo))
        return len(data)

    def read(self, count):
        data = bytes(self.outgoing[:count])
        del self.outgoing[:count]
        return data


class YoloDemoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = compile_library()
        cls.lib.ydm_init.argtypes = [C.POINTER(Demo), IO]
        cls.lib.ydm_ready.argtypes = [C.POINTER(Demo)]
        cls.lib.ydm_receive_one.argtypes = [C.POINTER(Demo)]
        cls.lib.ydm_receive_one.restype = C.c_int

    def setUp(self):
        self.serial = FirmwareSerial(self.lib)
        self.client = host.Client(self.serial, timeout=0.005)

    def tearDown(self):
        # ctypes 回调闭包会持有设备替身，显式解除引用以释放每例6MiB帧缓冲。
        self.serial.demo = Demo()
        self.serial.io = IO()
        self.serial.memory.clear()

    def upload(self, width=37, height=17):
        rgb = bytes((i * 37 + 19) & 255 for i in range(width * height * 3))
        return rgb, self.client.upload(rgb, width, height)

    def test_status_and_initial_ready(self):
        initial = self.client.ready()
        self.assertEqual(initial.valid, 0)
        self.assertEqual(initial.capabilities, 7)
        self.assertEqual(initial.detector_status, 6)
        self.assertEqual(self.client.status(), initial)

    def test_chunked_upload_readback(self):
        rgb, result = self.upload()
        self.assertTrue(result.valid)
        self.assertEqual(result.frame_id, 1)
        self.assertEqual(self.serial.maintenance, 1)
        read, status = self.client.read_frame()
        self.assertEqual(read, rgb)
        self.assertEqual(status.crc32, zlib.crc32(rgb))

    def test_repeated_images_and_selftest_ready(self):
        for number in range(1, 5):
            rgb, status = self.upload(19 + number, 13)
            self.assertEqual(status.frame_id, number)
            ready = self.client.selftest()
            self.assertEqual(ready.frame_id, number)
            self.assertEqual(self.client.read_frame()[0], rgb)
        self.assertEqual(self.serial.operator_calls, 4)

    def test_whole_frame_crc_failure_then_retry(self):
        self.client.request(host.BEGIN, struct.pack("<4I", 2, 1, 1, 0xBAD))
        self.client.request(host.DATA, struct.pack("<I", 0) + b"abcdef")
        with self.assertRaisesRegex(host.ProtocolError, "CRC"):
            self.client.request(host.END)
        self.assertEqual(self.client.status().valid, 0)
        self.upload(2, 1)
        self.assertEqual(self.client.status().valid, 1)

    def test_cache_flush_failure_not_published(self):
        self.serial.maintenance_error = 1
        with self.assertRaisesRegex(host.ProtocolError, "MEMORY"):
            self.upload(2, 1)
        self.assertEqual(self.client.status().valid, 0)
        self.serial.maintenance_error = 0
        self.upload(2, 1)
        self.assertEqual(self.client.status().frame_id, 1)

    def test_payload_crc_failure_no_ddr_write(self):
        self.client.ready()
        frame = bytearray(host.packet(host.DATA, 1, struct.pack("<I", 0) + b"abcdef"))
        frame[-1] ^= 1
        self.serial.write(frame)
        kind, seq, payload = self.client.receive()
        self.assertEqual((kind, seq), (0x8003, 1))
        self.assertEqual(struct.unpack("<2I", payload)[0], 2)
        self.assertEqual(self.serial.writes, 0)

    def test_header_crc_failure_no_write(self):
        self.client.ready()
        frame = bytearray(host.packet(host.BEGIN, 22, b"\0" * 16))
        frame[8] ^= 1
        self.serial.write(frame)
        kind, seq, payload = self.client.receive()
        self.assertEqual((kind, seq), (0x8000, 0))
        self.assertEqual(struct.unpack("<2I", payload)[0], 1)
        self.assertEqual(self.serial.writes, 0)

    def test_offset_and_overrun_rejected(self):
        self.client.request(host.BEGIN, struct.pack("<4I", 2, 1, 1, 0))
        for offset, data in ((1, b"a"), (0, b"abcdefg")):
            with self.assertRaisesRegex(host.ProtocolError, "RANGE"):
                self.client.request(host.DATA, struct.pack("<I", offset) + data)
        self.assertEqual(self.serial.writes, 0)
        self.assertEqual(self.serial.demo.received, 0)

    def test_selftest_refused_during_upload(self):
        self.client.request(host.BEGIN, struct.pack("<4I", 2, 1, 1, 0))
        with self.assertRaisesRegex(host.ProtocolError, "STATE"):
            self.client.selftest()
        self.assertEqual(self.serial.operator_calls, 0)

    def test_selftest_failure_then_ready_and_status(self):
        self.serial.operator_error = 51
        with self.assertRaisesRegex(host.ProtocolError, "OPERATOR"):
            self.client.selftest()
        self.assertEqual(self.client.ready().valid, 0)
        self.serial.operator_error = 0
        self.assertEqual(self.client.selftest().valid, 0)

    def test_no_fake_detection_or_hdmi(self):
        self.upload(2, 1)
        with self.assertRaisesRegex(host.ProtocolError, "NOT_READY"):
            self.client.detect()
        with self.assertRaisesRegex(host.ProtocolError, "NOT_READY"):
            self.client.request(host.DETECT)
        self.assertEqual(self.client.ready().capabilities & (host.CAP_DETECT | host.CAP_HDMI), 0)

    def test_cancel_discards_partial_image(self):
        self.upload(2, 1)
        self.client.request(host.BEGIN, struct.pack("<4I", 2, 1, 1, 0))
        self.assertEqual(self.client.cancel().valid, 0)
        with self.assertRaisesRegex(host.ProtocolError, "STATE"):
            self.client.request(host.END)
        self.upload(2, 1)
        self.assertEqual(self.client.status().frame_id, 2)

    def test_control_lengths_rejected(self):
        for kind in (host.STATUS, host.END, host.DETECT, host.SELFTEST, host.CANCEL):
            with self.assertRaisesRegex(host.ProtocolError, "LENGTH"):
                self.client.request(kind, b"a")
        self.assertEqual(self.serial.operator_calls, 0)

    def test_read_limits_and_crc(self):
        self.upload(2, 1)
        for offset, count in ((0, 0), (0, 1025), (7, 1), (5, 2), (0xFFFFFFFF, 1)):
            with self.assertRaisesRegex(host.ProtocolError, "RANGE"):
                self.client.request(host.READ, struct.pack("<2I", offset, count))
        self.serial.memory[1] ^= 1
        with self.assertRaisesRegex(host.ProtocolError, "readback CRC"):
            self.client.read_frame()

    def test_bad_dimensions_and_format(self):
        for width, height, fmt in ((0, 1, 1), (1921, 1, 1), (1, 1081, 1),
                                   (0xFFFFFFFF, 0xFFFFFFFF, 1), (2, 2, 0)):
            with self.assertRaisesRegex(host.ProtocolError, "RANGE"):
                self.client.request(host.BEGIN, struct.pack("<4I", width, height, fmt, 0))
        self.assertEqual(self.serial.writes, 0)

    def test_unknown_command(self):
        with self.assertRaisesRegex(host.ProtocolError, "UNKNOWN"):
            self.client.request(0x7FFF)

    def test_packet_encoder_and_decoder_crc(self):
        for count in (0, 1, 1024, 1028):
            payload = bytes(i & 255 for i in range(count))
            frame = host.packet(0x8007, 0xFFFFFFFF, payload)
            self.assertEqual(host.decode_packet(frame), (0x8007, 0xFFFFFFFF, payload))
        for frame in (b"", b"a" * 24, host.packet(1, 1) + b"a"):
            with self.assertRaises(host.ProtocolError):
                host.decode_packet(frame)
        with self.assertRaises(ValueError):
            host.packet(1, 0, b"a" * 1029)

    def test_noise_and_random_bad_payloads_no_write(self):
        self.client.ready()
        rng = random.Random(0x59444D31)
        for seq in range(64):
            payload = rng.randbytes(rng.randrange(1, 33))
            frame = bytearray(host.packet(host.DATA, seq, payload))
            frame[-1] ^= 0x80
            self.serial.write(b"\x55\x00garbage" + frame)
            kind, reply_seq, body = self.client.receive()
            self.assertEqual((kind, reply_seq, struct.unpack_from("<I", body)[0]), (0x8003, seq, 2))
        self.assertEqual(self.serial.writes, 0)

    def test_host_checks_raw_rgb_length_and_range(self):
        for data, width, height in ((b"a", 1, 1), (b"", 0, 1), (b"", 1921, 1)):
            with self.assertRaises(ValueError):
                self.client.upload(data, width, height)

    def test_empty_link_times_out(self):
        self.client.ready()
        with self.assertRaises(TimeoutError):
            self.client.receive()


if __name__ == "__main__":
    unittest.main()
