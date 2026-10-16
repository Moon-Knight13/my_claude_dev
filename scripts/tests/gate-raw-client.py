#!/usr/bin/env python3
"""Test helper: raw gate connections for framing cases the real client cannot make.

    gate-raw-client.py <socket> twice < request
        send the request, half-close, read the answer, then try a second request
        on the same connection; print the first answer, then "closed" if the
        connection carried nothing more.
    gate-raw-client.py <socket> raw < bytes
        send the bytes as-is, half-close, print whatever comes back.
Test-only.
"""
import socket
import sys

path, mode = sys.argv[1], sys.argv[2]
req = sys.stdin.buffer.read()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(path)
s.sendall(req)
s.shutdown(socket.SHUT_WR)
buf = b""
while True:
    b = s.recv(65536)
    if not b:
        break
    buf += b
sys.stdout.buffer.write(buf)
if mode == "twice":
    try:
        s.sendall(req)
        more = s.recv(65536)
        print("closed" if not more else "SECOND-ANSWER")
    except OSError:
        print("closed")
