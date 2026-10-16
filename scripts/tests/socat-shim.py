#!/usr/bin/env python3
"""Test helper: the one socat form gate_client uses, for machines without socat.

    socat -t <s> -T <s> - UNIX-CONNECT:<path>

Copies stdin to the socket, half-closes on stdin EOF, copies the socket to
stdout until the peer closes or <s> seconds pass with nothing read. CI installs
the real socat; this stands in only where it is missing. Test-only.
"""
import os
import select
import socket
import sys
import threading

args = sys.argv[1:]
timeout = 5.0
path = None
i = 0
while i < len(args):
    a = args[i]
    if a in ("-t", "-T"):
        timeout = float(args[i + 1]); i += 2; continue
    if a.startswith("UNIX-CONNECT:"):
        path = a.split(":", 1)[1]
    i += 1
if not path:
    sys.exit(2)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(path)
except OSError:
    sys.exit(1)


def pump_in():
    try:
        while True:
            b = os.read(0, 65536)
            if not b:
                break
            s.sendall(b)
    except OSError:
        pass
    try:
        s.shutdown(socket.SHUT_WR)
    except OSError:
        pass


threading.Thread(target=pump_in, daemon=True).start()
out = sys.stdout.buffer
while True:
    r, _, _ = select.select([s], [], [], timeout)
    if not r:
        break
    b = s.recv(65536)
    if not b:
        break
    out.write(b)
    out.flush()
