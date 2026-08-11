#!/usr/bin/env python3
"""Deterministic device-side peer for the versioned Juice/UIKit control bridge.

The real peer lives in app/main.m.  This test peer lets repository smoke tests
exercise JuiceGUI and wineios.drv without automating private UIKit APIs.  It can
return a preselected installer path or verify a host launch action and start a
test command, while preserving protocol markers suitable for release evidence.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import threading
import time


JUICE_CONTROL_MAGIC = 0x4A554354
JUICE_CONTROL_VERSION = 1
JUICE_CONTROL_IMPORT_REQUEST = 1
JUICE_CONTROL_IMPORT_RESPONSE = 2
JUICE_CONTROL_HOST_ACTION = 3
JUICE_CONTROL_STATUS_COMPLETE = 2
JUICE_CONTROL_ACTION_LAUNCH_PATH = 2
PATH_MAX = 2048
DETAIL_MAX = 512
MESSAGE = struct.Struct(f"<IHHIIiI{PATH_MAX}s{DETAIL_MAX}s")


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


def wire_string(value: str, capacity: int) -> bytes:
    encoded = value.encode("utf-8")[: capacity - 1]
    return encoded + bytes(capacity - len(encoded))


def parse_string(value: bytes) -> str:
    return value.split(b"\0", 1)[0].decode("utf-8", errors="replace")


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


class ControlPeer:
    def __init__(
        self,
        socket_path: Path,
        marker: Path,
        import_path: str,
        expected_action: int,
        expected_path: str,
        command: list[str],
    ) -> None:
        self.socket_path = socket_path
        self.marker = marker
        self.import_path = import_path
        self.expected_action = expected_action
        self.expected_path = expected_path
        self.command = command
        self.listener: socket.socket | None = None
        self.stop_event = threading.Event()
        self.success_event = threading.Event()
        self.processes: list[subprocess.Popen[bytes]] = []
        self.lock = threading.Lock()

    def start(self) -> None:
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        self.marker.parent.mkdir(parents=True, exist_ok=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(self.socket_path))
        listener.listen(4)
        listener.settimeout(0.25)
        self.listener = listener
        threading.Thread(target=self._accept_loop, daemon=True).start()
        print(f"JUICE_CONTROL_TEST_LISTENING socket={self.socket_path}", flush=True)

    def close(self) -> None:
        self.stop_event.set()
        if self.listener is not None:
            try:
                self.listener.close()
            except OSError:
                pass
        with self.lock:
            processes = list(self.processes)
        for process in processes:
            terminate_process(process)
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
                return
            threading.Thread(
                target=self._handle_connection, args=(connection,), daemon=True
            ).start()

    def _write_marker(self, kind: str, request_id: int, flags: int, path: str) -> None:
        self.marker.write_text(
            f"JUICE_CONTROL_{kind}_OK\n"
            f"version={JUICE_CONTROL_VERSION}\n"
            f"request={request_id}\n"
            f"flags={flags}\n"
            f"path={path}\n",
            encoding="utf-8",
        )
        self.success_event.set()

    def _launch_command(self, requested_path: str) -> None:
        if not self.command:
            return
        environment = os.environ.copy()
        environment["JUICE_CONTROL_ACTION_PATH"] = requested_path
        process = subprocess.Popen(
            self.command, env=environment, start_new_session=True
        )
        with self.lock:
            self.processes.append(process)
        print(
            f"JUICE_CONTROL_TEST_COMMAND_STARTED pid={process.pid} "
            f"path={requested_path}",
            flush=True,
        )

    def _handle_connection(self, connection: socket.socket) -> None:
        try:
            wire = read_exact(connection, MESSAGE.size)
            if wire is None:
                print("JUICE_CONTROL_TEST_PROTOCOL_ERROR reason=short-message", flush=True)
                return
            (
                magic,
                version,
                message_type,
                size,
                request_id,
                status,
                flags,
                raw_path,
                _raw_detail,
            ) = MESSAGE.unpack(wire)
            path = parse_string(raw_path)
            if (
                magic != JUICE_CONTROL_MAGIC
                or version != JUICE_CONTROL_VERSION
                or size != MESSAGE.size
            ):
                print(
                    f"JUICE_CONTROL_TEST_PROTOCOL_ERROR magic=0x{magic:x} "
                    f"version={version} size={size}",
                    flush=True,
                )
                return
            print(
                f"JUICE_CONTROL_TEST_REQUEST type={message_type} request={request_id} "
                f"status={status} flags={flags} path={path}",
                flush=True,
            )
            if message_type == JUICE_CONTROL_IMPORT_REQUEST and self.import_path:
                response = MESSAGE.pack(
                    JUICE_CONTROL_MAGIC,
                    JUICE_CONTROL_VERSION,
                    JUICE_CONTROL_IMPORT_RESPONSE,
                    MESSAGE.size,
                    request_id,
                    JUICE_CONTROL_STATUS_COMPLETE,
                    flags,
                    wire_string(self.import_path, PATH_MAX),
                    wire_string("Imported by deterministic control smoke.", DETAIL_MAX),
                )
                connection.sendall(response)
                self._write_marker("IMPORT", request_id, flags, self.import_path)
                print(
                    f"JUICE_CONTROL_TEST_IMPORT_RESPONSE request={request_id} "
                    f"path={self.import_path}",
                    flush=True,
                )
                return
            if message_type == JUICE_CONTROL_HOST_ACTION:
                path_matches = not self.expected_path or path.casefold() == self.expected_path.casefold()
                if flags != self.expected_action or not path_matches:
                    print(
                        f"JUICE_CONTROL_TEST_ACTION_REJECTED action={flags} path={path}",
                        flush=True,
                    )
                    return
                self._write_marker("ACTION", request_id, flags, path)
                self._launch_command(path)
                return
            print(
                f"JUICE_CONTROL_TEST_REQUEST_UNHANDLED type={message_type}", flush=True
            )
        finally:
            connection.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--marker", required=True, type=Path)
    parser.add_argument("--completion-marker", type=Path)
    parser.add_argument("--import-path", default="")
    parser.add_argument(
        "--expect-action", type=int, default=JUICE_CONTROL_ACTION_LAUNCH_PATH
    )
    parser.add_argument("--expect-path", default="")
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--settle", type=float, default=0.5)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.marker.exists():
        print(f"Refusing stale marker: {args.marker}", file=sys.stderr)
        return 2
    if args.completion_marker and args.completion_marker.exists():
        print(f"Refusing stale completion marker: {args.completion_marker}", file=sys.stderr)
        return 2

    peer = ControlPeer(
        args.socket,
        args.marker,
        args.import_path,
        args.expect_action,
        args.expect_path,
        command,
    )
    peer.start()
    deadline = time.monotonic() + args.timeout
    success = False
    ready_time: float | None = None
    try:
        while time.monotonic() < deadline:
            complete = args.completion_marker is None or args.completion_marker.is_file()
            if peer.success_event.is_set() and complete:
                if ready_time is None:
                    ready_time = time.monotonic()
                if time.monotonic() - ready_time >= args.settle:
                    success = True
                    break
            else:
                ready_time = None
            time.sleep(0.1)
        print(
            f"JUICE_CONTROL_TEST_RESULT success={int(success)} marker={args.marker} "
            f"completion={args.completion_marker or 'not-required'}",
            flush=True,
        )
    finally:
        peer.close()
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
