#!/usr/bin/env python3
"""YDM1 serial image transport. RGB readback and operator tests are independently callable.

Examples:
  python3 scripts/yolo/host.py --port COM5 status
  python3 scripts/yolo/host.py --port COM5 upload image.rgb --width 640 --height 640
  python3 scripts/yolo/host.py --port COM5 read --output received.rgb
  python3 scripts/yolo/host.py --port COM5 selftest
"""
import argparse
import dataclasses
import hashlib
import json
import math
from pathlib import Path
import struct
import time
import zlib

MAGIC = 0x314D4459
VERSION = 1
CHUNK = 1024
MAX_WIDTH, MAX_HEIGHT = 1920, 1080
READY = 0x9000
STATUS, BEGIN, DATA, END, DETECT, READ, SELFTEST, CANCEL = range(1, 9)
MODEL_BEGIN, MODEL_DATA, MODEL_END = range(9, 12)
MAX_MODEL_BYTES = 16 * 1024 * 1024
CAP_DETECT, CAP_HDMI, CAP_MODEL = 8, 16, 32
ERRORS = {0: "OK", 1: "HEADER", 2: "CRC", 3: "LENGTH", 4: "STATE",
          5: "RANGE", 6: "NOT_READY", 7: "MEMORY", 8: "OPERATOR", 9: "UNKNOWN", 10: "MODEL"}


class ProtocolError(RuntimeError):
    pass


def packet(kind, sequence, payload=b""):
    if not 0 <= kind <= 0xFFFF or not 0 <= sequence <= 0xFFFFFFFF:
        raise ValueError("packet kind/sequence out of range")
    if len(payload) > CHUNK + 4:
        raise ValueError("payload exceeds protocol bound")
    head = struct.pack("<5I", MAGIC, VERSION | (kind << 16), sequence,
                       len(payload), zlib.crc32(payload))
    return head + struct.pack("<I", zlib.crc32(head)) + payload


def decode_packet(data):
    if len(data) < 24:
        raise ProtocolError("truncated header")
    magic, word, seq, count, crc, hcrc = struct.unpack("<6I", data[:24])
    if magic != MAGIC or word & 0xFFFF != VERSION or zlib.crc32(data[:20]) != hcrc:
        raise ProtocolError("invalid packet header")
    if count > CHUNK + 4 or len(data) != 24 + count:
        raise ProtocolError("invalid packet length")
    payload = data[24:]
    if zlib.crc32(payload) != crc:
        raise ProtocolError("payload CRC mismatch")
    return word >> 16, seq, payload


@dataclasses.dataclass
class FrameStatus:
    error: int
    capabilities: int
    valid: int
    width: int
    height: int
    bytes: int
    frame_id: int
    address: int
    crc32: int
    chunk_bytes: int
    detector_status: int

    @classmethod
    def parse(cls, payload):
        if len(payload) != 44:
            raise ProtocolError("STATUS/READY must carry 44 bytes")
        result = cls(*struct.unpack("<11I", payload))
        if result.error or result.chunk_bytes != CHUNK:
            raise ProtocolError("incompatible READY response")
        if result.valid and (not 0 < result.width <= MAX_WIDTH or
                             not 0 < result.height <= MAX_HEIGHT or
                             result.bytes != result.width * result.height * 3):
            raise ProtocolError("invalid framebuffer metadata")
        return result


class Client:
    def __init__(self, serial, timeout=5.0):
        self.serial, self.timeout, self.sequence = serial, timeout, 0

    def _read(self, n):
        data = bytearray()
        deadline = time.monotonic() + self.timeout
        while len(data) < n:
            part = self.serial.read(n - len(data))
            if part:
                data.extend(part)
            elif time.monotonic() >= deadline:
                raise TimeoutError("UART response timed out")
        return bytes(data)

    def receive(self):
        magic = struct.pack("<I", MAGIC)
        window = bytearray(self._read(4))
        deadline = time.monotonic() + self.timeout
        while bytes(window) != magic:
            if time.monotonic() >= deadline:
                raise TimeoutError("UART packet header timed out")
            window[:] = window[1:] + self._read(1)
        header = bytes(window) + self._read(20)
        count = struct.unpack_from("<I", header, 12)[0]
        if count > CHUNK + 4:
            raise ProtocolError("response exceeds protocol bound")
        return decode_packet(header + self._read(count))

    def request(self, kind, payload=b""):
        self.sequence = (self.sequence + 1) & 0xFFFFFFFF
        self.serial.write(packet(kind, self.sequence, payload))
        while True:
            response, seq, body = self.receive()
            if response == READY:
                FrameStatus.parse(body)
                continue
            if response != (kind | 0x8000) or seq != self.sequence:
                raise ProtocolError("response command/sequence mismatch")
            if len(body) < 4:
                raise ProtocolError("missing response status")
            error = struct.unpack_from("<I", body)[0]
            if error:
                raise ProtocolError(f"device {ERRORS.get(error, str(error))}, detail={body[4:].hex()}")
            return body

    def ready(self):
        kind, seq, body = self.receive()
        if kind != READY or seq:
            raise ProtocolError("expected READY after completion")
        return FrameStatus.parse(body)

    def status(self):
        return FrameStatus.parse(self.request(STATUS))

    def upload(self, rgb, width, height):
        if not 0 < width <= MAX_WIDTH or not 0 < height <= MAX_HEIGHT:
            raise ValueError("RGB frame dimensions out of range")
        if len(rgb) != width * height * 3:
            raise ValueError("raw RGB888 length must equal width*height*3")
        crc = zlib.crc32(rgb)
        self.request(BEGIN, struct.pack("<4I", width, height, 1, crc))
        for offset in range(0, len(rgb), CHUNK):
            payload = struct.pack("<I", offset) + rgb[offset:offset + CHUNK]
            body = self.request(DATA, payload)
            if len(body) != 8 or struct.unpack_from("<I", body, 4)[0] != offset + len(payload) - 4:
                raise ProtocolError("unexpected upload offset ACK")
        body = self.request(END)
        if len(body) != 8 or struct.unpack_from("<I", body, 4)[0] != crc:
            raise ProtocolError("unexpected whole-frame CRC ACK")
        result = self.status()
        if not result.valid or (result.width, result.height, result.crc32) != (width, height, crc):
            raise ProtocolError("frame not published after upload")
        return result

    def read_frame(self):
        status = self.status()
        if not status.valid:
            raise ProtocolError("no complete uploaded frame")
        output = bytearray()
        for offset in range(0, status.bytes, CHUNK):
            count = min(CHUNK, status.bytes - offset)
            body = self.request(READ, struct.pack("<2I", offset, count))
            if len(body) != count + 4:
                raise ProtocolError("truncated frame readback")
            output.extend(body[4:])
        if zlib.crc32(output) != status.crc32:
            raise ProtocolError("whole-frame readback CRC mismatch")
        return bytes(output), status

    def selftest(self):
        body = self.request(SELFTEST)
        if len(body) != 8 or struct.unpack_from("<I", body, 4)[0]:
            raise ProtocolError("operator selftest failed")
        return self.ready()

    def detect(self):
        current = self.status()
        if not current.capabilities & CAP_DETECT:
            raise ProtocolError("NOT_READY: complete YOLOX model backend is not installed")
        payload = self.request(DETECT)
        if len(payload) < 8:
            raise ProtocolError("missing detection count")
        count = struct.unpack_from("<I", payload, 4)[0]
        if count > 32 or len(payload) != 8 + count * 24:
            raise ProtocolError("invalid detection record length")
        detections = []
        for index in range(count):
            category, score, x1, y1, x2, y2 = struct.unpack_from("<I5f", payload, 8 + index * 24)
            if (category >= 80 or not all(math.isfinite(v) for v in (score, x1, y1, x2, y2)) or
                    not 0 <= score <= 1 or x2 < x1 or y2 < y1):
                raise ProtocolError("invalid detection values")
            detections.append(dict(class_id=category, score=score, xyxy=[x1, y1, x2, y2]))
        return dict(detections=detections, status=dataclasses.asdict(self.ready()))

    def upload_model(self, model):
        if not 0 < len(model) <= MAX_MODEL_BYTES:
            raise ValueError("model must fit the 16 MiB reserved DDR region")
        crc = zlib.crc32(model)
        self.request(MODEL_BEGIN, struct.pack("<2I", len(model), crc))
        for offset in range(0, len(model), CHUNK):
            data = model[offset:offset + CHUNK]
            reply = self.request(MODEL_DATA, struct.pack("<I", offset) + data)
            if len(reply) != 8 or struct.unpack_from("<I", reply, 4)[0] != offset + len(data):
                raise ProtocolError("unexpected model offset ACK")
        reply = self.request(MODEL_END)
        if len(reply) != 8 or struct.unpack_from("<I", reply, 4)[0] != crc:
            raise ProtocolError("unexpected whole-model CRC ACK")
        status = self.ready()
        if not status.capabilities & CAP_DETECT:
            raise ProtocolError("model was not published to detector")
        return status

    def cancel(self):
        self.request(CANCEL)
        return self.ready()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=1800.0,
                        help="response timeout in seconds; full software-float graph execution can be slow")
    parser.add_argument("--report", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("status", "selftest", "detect", "cancel"):
        sub.add_parser(name)
    upload = sub.add_parser("upload")
    upload.add_argument("rgb", type=Path)
    upload.add_argument("--width", type=int, required=True)
    upload.add_argument("--height", type=int, required=True)
    model = sub.add_parser("model")
    model.add_argument("model", type=Path)
    read = sub.add_parser("read")
    read.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        import serial
    except ImportError as error:
        parser.error(f"serial access requires pyserial: {error}")
    with serial.Serial(args.port, args.baud, timeout=min(args.timeout, 0.2)) as port:
        client = Client(port, args.timeout)
        if args.command == "upload":
            image = args.rgb.read_bytes()
            result = client.upload(image, args.width, args.height)
        elif args.command == "model":
            model = args.model.read_bytes()
            result = client.upload_model(model)
        elif args.command == "read":
            image, result = client.read_frame()
            args.output.write_bytes(image)
        else:
            result = getattr(client, args.command)()
        status = result['status'] if isinstance(result, dict) else dataclasses.asdict(result)
        report = dict(command=args.command, status=status,
                      hdmi_available=bool(status['capabilities'] & CAP_HDMI),
                      model_loader_available=bool(status['capabilities'] & CAP_MODEL),
                      detector_available=bool(status['capabilities'] & CAP_DETECT))
        if args.command == 'detect':
            report['detections'] = result['detections']
        if args.command == 'model':
            report['model_sha256'] = hashlib.sha256(model).hexdigest()
        if args.command in ("upload", "read"):
            report["rgb_sha256"] = hashlib.sha256(image).hexdigest()
        text = json.dumps(report, indent=2)
        print(text)
        if args.report:
            args.report.write_text(text + "\n")


if __name__ == "__main__":
    main()
