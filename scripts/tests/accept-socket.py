#!/usr/bin/env python3
"""Test helper: serve a unix socket the way systemd Accept=yes does (SP1a 2.3).

    accept-socket.py <socket path> <command> [args...]

Listens on <socket path>; for each connection, forks and runs <command> with the
connected socket as its stdin and stdout, so the handler sees a real socket
(SO_PEERCRED works) exactly as under gate-hub.socket. Test-only; never installed.
"""
import os
import signal
import socket
import sys

path, cmd = sys.argv[1], sys.argv[2:]
signal.signal(signal.SIGCHLD, signal.SIG_IGN)   # no zombies
try:
    os.unlink(path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
os.chmod(path, 0o666)
srv.listen(16)
while True:
    conn, _ = srv.accept()
    if os.fork() == 0:
        srv.close()
        fd = conn.fileno()
        os.dup2(fd, 0)
        os.dup2(fd, 1)
        conn.close()
        os.execvp(cmd[0], cmd)
    conn.close()
