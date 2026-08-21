#!/usr/bin/env python3
"""Drive the wineios.drv framebuffer protocol for a deterministic text smoke.

This runs on the development iOS device.  It provides the same display/input
socket used by the UIKit host, focuses the Win32 EDIT control, sends UTF-16
text, and preserves before/after PNG frames without requiring a person to tap.
"""

from __future__ import annotations

import argparse
import binascii
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import zlib


JUICE_MAGIC = 0x4A554943
MSG_HELLO = 1
MSG_WINDOW = 3
MSG_FRAME = 5
MSG_INPUT = 100
MSG_TEXT = 101
MSG_HARDWARE_KEY = 103
INPUT_LEFT_DOWN = 1
INPUT_LEFT_UP = 2
HARDWARE_KEY_DOWN = 1
HARDWARE_KEY_UP = 2
HEADER = struct.Struct("<III4xQiiiiII")
GAMEPAD_STATE = struct.Struct("<IHHIIIHBBhhhhIIQ16s")


def read_exact(connection: socket.socket, size: int) -> bytes | None:
    chunks = bytearray()
    while len(chunks) < size:
        try:
            chunk = connection.recv(size - len(chunks))
        except InterruptedError:
            continue
        except OSError:
            return None
        if not chunk:
            return None
        chunks.extend(chunk)
    return bytes(chunks)


def png_chunk(kind: bytes, data: bytes) -> bytes:
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", binascii.crc32(body) & 0xFFFFFFFF)


def write_bgra_png(path: Path, width: int, height: int, stride: int, pixels: bytes) -> None:
    rows = bytearray()
    for y in range(height):
        source = memoryview(pixels)[y * stride : y * stride + width * 4]
        rgba = bytearray(width * 4)
        rgba[0::4] = source[2::4]
        rgba[1::4] = source[1::4]
        rgba[2::4] = source[0::4]
        rgba[3::4] = source[3::4]
        rows.append(0)
        rows.extend(rgba)
    payload = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(bytes(rows), 6))
        + png_chunk(b"IEND", b"")
    )
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(payload)
    temporary.replace(path)


class DisplayHost:
    def __init__(
        self,
        socket_path: Path,
        output_dir: Path,
        text: str,
        inject_input: bool,
        min_width: int,
        max_width: int,
        min_height: int,
        max_height: int,
        click_points: list[tuple[int, int]],
        input_delay: float,
        send_text: bool,
        hardware_key: bool,
        input_gate: Path | None,
        expected_window: tuple[int, int] | None,
    ) -> None:
        self.socket_path = socket_path
        self.output_dir = output_dir
        self.text = text
        self.inject_input = inject_input
        self.min_width = min_width
        self.max_width = max_width
        self.min_height = min_height
        self.max_height = max_height
        self.click_points = click_points
        self.input_delay = input_delay
        self.send_text = send_text
        self.hardware_key = hardware_key
        self.input_gate = input_gate
        self.expected_window = expected_window
        self.listener: socket.socket | None = None
        self.stop_event = threading.Event()
        self.input_sent = threading.Event()
        self.expected_window_seen = threading.Event()
        self.lock = threading.Lock()
        self.latest_frame: tuple[int, int, int, bytes] | None = None
        self.latest_expected_frame: tuple[int, int, int, bytes] | None = None
        self.first_frame_time: float | None = None
        self.expected_window_hwnds: set[int] = set()
        self.first_frame_written = False
        self.client_threads: list[threading.Thread] = []

    def start(self) -> None:
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(self.socket_path))
        listener.listen(8)
        listener.settimeout(0.25)
        self.listener = listener
        threading.Thread(target=self._accept_loop, name="juice-display-accept", daemon=True).start()
        print(f"JUICE_TEXT_HOST_LISTENING socket={self.socket_path}", flush=True)

    def close(self) -> None:
        self.stop_event.set()
        if self.listener is not None:
            try:
                self.listener.close()
            except OSError:
                pass
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass

    def _accept_loop(self) -> None:
        assert self.listener is not None
        while not self.stop_event.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            thread = threading.Thread(
                target=self._read_client,
                args=(connection,),
                name="juice-display-client",
                daemon=True,
            )
            self.client_threads.append(thread)
            thread.start()

    @staticmethod
    def _send_message(
        connection: socket.socket,
        message_type: int,
        hwnd: int,
        *,
        x: int = 0,
        y: int = 0,
        flags: int = 0,
        payload: bytes = b"",
    ) -> None:
        header = HEADER.pack(
            JUICE_MAGIC,
            message_type,
            len(payload),
            hwnd,
            x,
            y,
            0,
            0,
            0,
            flags,
        )
        connection.sendall(header + payload)

    def _inject_input(self, connection: socket.socket, hwnd: int) -> None:
        if self.input_sent.is_set():
            return
        self.input_sent.set()
        try:
            for index, (click_x, click_y) in enumerate(self.click_points):
                self._send_message(
                    connection,
                    MSG_INPUT,
                    hwnd,
                    x=click_x,
                    y=click_y,
                    flags=INPUT_LEFT_DOWN,
                )
                self._send_message(
                    connection,
                    MSG_INPUT,
                    hwnd,
                    x=click_x,
                    y=click_y,
                    flags=INPUT_LEFT_UP,
                )
                print(
                    f"JUICE_TEXT_HOST_CLICK_SENT index={index + 1} hwnd=0x{hwnd:x} "
                    f"point={click_x},{click_y}",
                    flush=True,
                )
                if index + 1 < len(self.click_points):
                    time.sleep(self.input_delay)
            if self.send_text:
                self._send_message(
                    connection, MSG_TEXT, hwnd, payload=self.text.encode("utf-16-le")
                )
            if self.hardware_key:
                self._send_message(
                    connection,
                    MSG_HARDWARE_KEY,
                    hwnd,
                    x=0x41,
                    y=0x1E,
                    flags=HARDWARE_KEY_DOWN,
                )
                self._send_message(
                    connection,
                    MSG_HARDWARE_KEY,
                    hwnd,
                    x=0x41,
                    y=0x1E,
                    flags=HARDWARE_KEY_UP,
                )
                print(
                    f"JUICE_HARDWARE_KEY_HOST_SENT hwnd=0x{hwnd:x} "
                    "vk=0x41 scan=0x1e down=1 up=1",
                    flush=True,
                )
            print(
                f"JUICE_TEXT_HOST_INPUT_SENT hwnd=0x{hwnd:x} "
                f"clicks={len(self.click_points)} "
                f"utf16_units={len(self.text) if self.send_text else 0}",
                flush=True,
            )
        except OSError as error:
            print(f"JUICE_TEXT_HOST_INPUT_ERROR error={error}", flush=True)

    def _record_frame(
        self,
        connection: socket.socket,
        hwnd: int,
        width: int,
        height: int,
        stride: int,
        pixels: bytes,
    ) -> None:
        with self.lock:
            if hwnd in self.expected_window_hwnds:
                self.latest_expected_frame = (width, height, stride, pixels)

        # Exclude explorer's 1024x768 desktop and tiny service windows.  The
        # smoke's 780x520 window currently receives an 896x640 backing surface.
        if not (
            self.min_width <= width <= self.max_width
            and self.min_height <= height <= self.max_height
        ):
            return
        with self.lock:
            self.latest_frame = (width, height, stride, pixels)
            write_first = not self.first_frame_written
            if write_first:
                self.first_frame_written = True
                self.first_frame_time = time.monotonic()
        if write_first:
            path = self.output_dir / "frame-before-input.png"
            write_bgra_png(path, width, height, stride, pixels)
            print(
                f"JUICE_TEXT_HOST_FRAME hwnd=0x{hwnd:x} size={width}x{height} path={path}",
                flush=True,
            )
        if self.inject_input and (self.input_gate is None or self.input_gate.is_file()):
            self._inject_input(connection, hwnd)

    def has_frame(self) -> bool:
        with self.lock:
            return self.latest_frame is not None

    def frame_age(self) -> float | None:
        with self.lock:
            first_frame_time = self.first_frame_time
        if first_frame_time is None:
            return None
        return time.monotonic() - first_frame_time

    def save_latest(self, name: str) -> Path | None:
        with self.lock:
            frame = self.latest_frame
        if frame is None:
            return None
        width, height, stride, pixels = frame
        path = self.output_dir / name
        write_bgra_png(path, width, height, stride, pixels)
        return path

    def save_expected(self, name: str) -> Path | None:
        with self.lock:
            frame = self.latest_expected_frame
        if frame is None:
            return None
        width, height, stride, pixels = frame
        path = self.output_dir / name
        write_bgra_png(path, width, height, stride, pixels)
        return path

    def _read_client(self, connection: socket.socket) -> None:
        peer_pid = 0
        try:
            while not self.stop_event.is_set():
                raw_header = read_exact(connection, HEADER.size)
                if raw_header is None:
                    break
                (
                    magic,
                    message_type,
                    size,
                    hwnd,
                    x,
                    y,
                    width,
                    height,
                    stride,
                    flags,
                ) = HEADER.unpack(raw_header)
                if magic != JUICE_MAGIC or size > 64 * 1024 * 1024:
                    print(
                        f"JUICE_TEXT_HOST_PROTOCOL_ERROR magic=0x{magic:x} size={size}",
                        flush=True,
                    )
                    break
                payload = read_exact(connection, size) if size else b""
                if payload is None:
                    break
                if message_type == MSG_HELLO:
                    peer_pid = flags
                    print(
                        f"JUICE_TEXT_HOST_HELLO pid={peer_pid} desktop={width}x{height} dpi={stride}",
                        flush=True,
                    )
                elif message_type == MSG_WINDOW:
                    if width >= 600 and height >= 400:
                        print(
                            f"JUICE_TEXT_HOST_WINDOW pid={peer_pid} hwnd=0x{hwnd:x} "
                            f"rect={x},{y} {width}x{height} visible={flags}",
                            flush=True,
                        )
                    if self.expected_window == (width, height):
                        with self.lock:
                            self.expected_window_hwnds.add(hwnd)
                        self.expected_window_seen.set()
                        print(
                            f"JUICE_GUI_HOST_EXPECTED_WINDOW pid={peer_pid} "
                            f"hwnd=0x{hwnd:x} size={width}x{height}",
                            flush=True,
                        )
                elif message_type == MSG_FRAME and payload:
                    expected = stride * height
                    if expected <= len(payload) and width > 0 and height > 0:
                        self._record_frame(
                            connection, hwnd, width, height, stride, payload[:expected]
                        )
        finally:
            connection.close()
            print(f"JUICE_TEXT_HOST_CLIENT_CLOSED pid={peer_pid}", flush=True)


def terminate_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            process.kill()
        process.wait(timeout=5)


def main() -> int:
    def pair(value: str) -> tuple[int, int]:
        separator = "x" if "x" in value.lower() else ","
        left, right = value.lower().split(separator, 1)
        return int(left), int(right)

    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--marker", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--text", default="Juice input works 42")
    parser.add_argument("--no-input", action="store_true")
    parser.add_argument("--no-text", action="store_true")
    parser.add_argument("--hardware-key", action="store_true")
    parser.add_argument("--gamepad-state", type=Path)
    parser.add_argument("--click", type=pair, action="append")
    parser.add_argument("--input-delay", type=float, default=0.25)
    parser.add_argument("--inject-after-marker", action="store_true")
    parser.add_argument("--input-gate", type=Path)
    parser.add_argument("--expect-window", type=pair)
    parser.add_argument("--min-width", type=int, default=600)
    parser.add_argument("--max-width", type=int, default=999)
    parser.add_argument("--min-height", type=int, default=400)
    parser.add_argument("--max-height", type=int, default=749)
    parser.add_argument("--timeout", type=float, default=35.0)
    parser.add_argument("--settle", type=float, default=1.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    if args.marker.exists():
        print(f"Refusing stale marker: {args.marker}", file=sys.stderr)
        return 2
    click_points = args.click or [(120, 358)]
    input_gate = args.input_gate
    if input_gate is None and args.inject_after_marker:
        input_gate = args.marker

    host = DisplayHost(
        args.socket,
        args.output_dir,
        args.text,
        not args.no_input,
        args.min_width,
        args.max_width,
        args.min_height,
        args.max_height,
        click_points,
        args.input_delay,
        not args.no_text,
        args.hardware_key,
        input_gate,
        args.expect_window,
    )
    host.start()
    if args.gamepad_state:
        args.gamepad_state.parent.mkdir(parents=True, exist_ok=True)
        args.gamepad_state.write_bytes(
            GAMEPAD_STATE.pack(
                0x3147504A,
                1,
                GAMEPAD_STATE.size,
                2,
                1,
                42,
                0x1000,
                96,
                0,
                12345,
                0,
                0,
                -23456,
                0,
                0xFFFFFFFF,
                time.monotonic_ns(),
                bytes(16),
            )
        )
        print(
            f"JUICE_GAMECONTROLLER_HOST_STATE_READY path={args.gamepad_state} "
            "packet=42 buttons=0x1000 lt=96 lx=12345 ry=-23456",
            flush=True,
        )
    environment = os.environ.copy()
    environment["JUICE_IOS_SOCKET"] = str(args.socket)
    if args.gamepad_state:
        environment["JUICE_GAMEPAD_STATE"] = "Z:" + str(args.gamepad_state).replace("/", "\\")
    process = subprocess.Popen(command, env=environment, start_new_session=True)
    deadline = time.monotonic() + args.timeout
    success = False
    marker_time: float | None = None
    try:
        while time.monotonic() < deadline:
            if args.marker.is_file():
                if marker_time is None:
                    marker_time = time.monotonic()
                expectation_met = (
                    args.expect_window is None or host.expected_window_seen.is_set()
                )
                frame_age = host.frame_age()
                if frame_age is not None and expectation_met and frame_age >= args.settle:
                    success = True
                    break
            if process.poll() is not None:
                break
            time.sleep(0.1)
        frame = host.save_latest("frame-after-input.png")
        expected_frame = host.save_expected("expected-window-frame.png")
        print(
            f"JUICE_TEXT_HOST_RESULT success={int(success)} marker={args.marker} "
            f"frame={frame or 'missing'} expected_frame={expected_frame or 'missing'} "
            f"child_rc={process.poll()}",
            flush=True,
        )
    finally:
        terminate_process(process)
        host.close()
        if args.gamepad_state:
            disconnected = GAMEPAD_STATE.pack(
                0x3147504A,
                1,
                GAMEPAD_STATE.size,
                4,
                0,
                43,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0xFFFFFFFF,
                time.monotonic_ns(),
                bytes(16),
            )
            args.gamepad_state.write_bytes(disconnected)
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
