#!/usr/bin/env python3
"""Mock local chat endpoint for the executor tests (scripts/tests/test-executor.sh).

Serves POST /api/chat and replies with the next line of a scripted response file,
so a test can drive the executor's tool-calling loop deterministically without a
real model.

Knobs:
  MOCK_SCRIPT  path to a file of assistant replies, one per line (a JSON tool call
               or a done object, exactly as the executor expects to parse). When
               the script runs out the LAST line repeats — that is what lets the
               step-budget test drive an unbounded stream of tool calls.
  MOCK_RECORD  path to append each received request body to, one JSON per line, so
               a test can assert on what the executor actually sent (system prompt
               stability, where tool results were placed).
  MOCK_PORT    listen port (default 18435; different from mock-ollama.py's 18434 so
               both can run at once).
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = os.environ.get("MOCK_SCRIPT", "")
RECORD = os.environ.get("MOCK_RECORD", "")
PORT = int(os.environ.get("MOCK_PORT", "18435"))

with open(SCRIPT) as fh:
    REPLIES = [ln.rstrip("\n") for ln in fh if ln.strip()]

STATE = {"turn": 0}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) or b"{}"
        if self.path != "/api/chat":
            # Readiness probes hit another path; recording them would put junk
            # lines in front of the real turns a test indexes by position.
            self._send({"error": "not found"}, 404)
            return
        if RECORD:
            with open(RECORD, "a") as fh:
                fh.write(raw.decode("utf-8", "replace").replace("\n", " ") + "\n")
        i = min(STATE["turn"], len(REPLIES) - 1)
        STATE["turn"] += 1
        self._send({"message": {"role": "assistant", "content": REPLIES[i]}, "done": True})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
