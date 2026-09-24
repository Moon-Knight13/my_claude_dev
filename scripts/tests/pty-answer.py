#!/usr/bin/env python3
"""Run a command on a pseudo-terminal and answer its [y/N] prompts (test helper).

The split runner and the executor ask the owner at the controlling terminal and
refuse outright without one. That is the control, so the tests cannot switch it
off; they give the command a real terminal instead and play the owner.

Usage:  ANSWERS="y,y,n" pty-answer.py <command> [args...]

Each time the output shows "[y/N]" the next answer is typed; once the list runs
out every further prompt gets "n" — an unexpected extra prompt fails safe rather
than being approved. Everything the command wrote to the terminal is copied to
stdout; the exit status is the command's.
"""
import os
import pty
import sys

answers = [a for a in os.environ.get("ANSWERS", "").split(",") if a != ""]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])

seen = b""
out = sys.stdout.buffer
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out.write(chunk)
    out.flush()
    seen += chunk
    while b"[y/N]" in seen:
        seen = seen.split(b"[y/N]", 1)[1]
        ans = answers.pop(0) if answers else "n"
        os.write(fd, (ans + "\n").encode())

_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
