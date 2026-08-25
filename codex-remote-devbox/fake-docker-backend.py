#!/usr/bin/python3
"""Deterministic dial-stdio fixture for the remote-devbox smoke suite."""

import json
import os
import re
import sys


EXPECTED_ARGS = [
    "--host=unix:///Users/imageyard/.docker/run/docker.sock",
    "system",
    "dial-stdio",
]
DAEMON_ID = "IMAGEYARD-R4-FAKE-DAEMON-ID"
VERSION_PREFIX = re.compile(br"^/v[0-9]+\.[0-9]+")


def write_bytes(data):
    try:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        raise SystemExit(0)


def response(status, body=b"", content_type=b"text/plain", extra_headers=()):
    headers = [
        b"HTTP/1.1 " + status,
        b"Api-Version: 1.52",
        b"Docker-Experimental: false",
        b"OSType: linux",
        b"Content-Type: " + content_type,
        b"Content-Length: " + str(len(body)).encode("ascii"),
        b"Connection: keep-alive",
    ]
    headers.extend(extra_headers)
    write_bytes(b"\r\n".join(headers) + b"\r\n\r\n" + body)


def read_request(buffer):
    while b"\r\n\r\n" not in buffer:
        chunk = sys.stdin.buffer.read1(65536)
        if not chunk:
            return None, b""
        buffer += chunk
    header, buffer = buffer.split(b"\r\n\r\n", 1)
    lines = header.split(b"\r\n")
    request = lines[0].split(b" ")
    if len(request) != 3:
        raise SystemExit(65)
    content_length = 0
    for line in lines[1:]:
        name, separator, value = line.partition(b":")
        if separator and name.lower() == b"content-length":
            content_length = int(value.strip())
    while len(buffer) < content_length:
        chunk = sys.stdin.buffer.read1(65536)
        if not chunk:
            raise SystemExit(65)
        buffer += chunk
    body = buffer[:content_length]
    buffer = buffer[content_length:]
    return (request[0], request[1], body), buffer


def main():
    if sys.argv[1:] != EXPECTED_ARGS:
        raise SystemExit(64)
    with open("/tmp/imageyard-fake-docker-argv.log", "ab", buffering=0) as log:
        log.write(b"\0".join(os.fsencode(argument) for argument in sys.argv) + b"\n")

    buffer = b""
    while True:
        request, buffer = read_request(buffer)
        if request is None:
            return
        method, request_path, body = request
        api_path = VERSION_PREFIX.sub(b"", request_path, count=1)

        if api_path == b"/_ping":
            response(b"200 OK", b"" if method == b"HEAD" else b"OK")
        elif api_path == b"/version":
            payload = json.dumps({
                "ApiVersion": "1.52",
                "Arch": "arm64",
                "BuildTime": "2026-08-24T00:00:00Z",
                "Experimental": False,
                "GitCommit": "imageyard-r4-fixture",
                "GoVersion": "go1.25.0",
                "KernelVersion": "fixture",
                "MinAPIVersion": "1.24",
                "Os": "linux",
                "Platform": {"Name": "ImageYard deterministic fixture"},
                "Version": "29.7.2",
            }, separators=(",", ":")).encode("ascii")
            response(b"200 OK", payload, b"application/json")
        elif api_path == b"/info":
            payload = json.dumps({
                "ID": DAEMON_ID,
                "Architecture": "arm64",
                "Containers": 0,
                "ContainersPaused": 0,
                "ContainersRunning": 0,
                "ContainersStopped": 0,
                "Driver": "imageyard-fixture",
                "DockerRootDir": "/var/lib/docker",
                "Images": 0,
                "IndexServerAddress": "https://index.docker.io/v1/",
                "KernelVersion": "fixture",
                "MemTotal": 1073741824,
                "NCPU": 1,
                "Name": "imageyard-r4-fixture",
                "OperatingSystem": "ImageYard deterministic fixture",
                "OSType": "linux",
                "ServerVersion": "29.7.2",
            }, separators=(",", ":")).encode("ascii")
            response(b"200 OK", payload, b"application/json")
        elif api_path == b"/hijack":
            write_bytes(
                b"HTTP/1.1 101 UPGRADED\r\n"
                b"Connection: Upgrade\r\n"
                b"Upgrade: tcp\r\n\r\n"
            )
            if buffer:
                write_bytes(buffer)
                buffer = b""
            while True:
                chunk = sys.stdin.buffer.read1(65536)
                if not chunk:
                    return
                write_bytes(chunk)
        elif api_path == b"/half-close":
            write_bytes(
                b"HTTP/1.1 101 UPGRADED\r\n"
                b"Connection: Upgrade\r\n"
                b"Upgrade: tcp\r\n\r\n"
            )
            payload = bytearray(buffer)
            buffer = b""
            while True:
                chunk = sys.stdin.buffer.read1(65536)
                if not chunk:
                    break
                payload.extend(chunk)
            write_bytes(b"HALF-CLOSE:" + bytes(payload))
            return
        elif api_path == b"/large":
            write_bytes(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                b"Content-Length: 8388608\r\nConnection: close\r\n\r\n"
            )
            for _ in range(128):
                write_bytes(b"x" * 65536)
            return
        else:
            payload = json.dumps({"message": "fixture endpoint not found"}).encode("ascii")
            response(b"404 Not Found", payload, b"application/json")


if __name__ == "__main__":
    main()
