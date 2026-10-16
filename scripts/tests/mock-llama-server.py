#!/usr/bin/env python3
"""Mock llama-server (OpenAI-compatible) for fleet_call tests (SP1a story 1.3).

Serves the endpoints fleet_call uses: GET /health, GET /props,
POST /apply-template, POST /tokenize, POST /v1/chat/completions.

Behaviour is read from files in MOCK_STATE_DIR on every request, so a test can
switch modes without restarting the mock:
  mode     one of (default ok):
             ok            healthy; completion returns the content file
             loading       /health answers 503 (model still loading)
             health500     /health answers 500
             hang-health   /health sleeps 3 s (probe timeout)
             noctx         /props has no n_ctx
             template-fail /apply-template answers 500
             tokenize-fail /tokenize answers 500
             toolong       /tokenize reports n_ctx tokens (fit check fails)
             oversize      completion answers 400 exceed_context_size_error
             malformed     completion body is not JSON
             truncated     finish_reason "length" with a cut-off object
             timeout       completion sleeps 5 s
  content  the assistant message content (default {"verdict":"nonsensitive"})
  nctx     n_ctx reported by /props (default 4096)
  rules    optional, one "<marker>\t<content>" per line: a completion whose
           last message contains <marker> returns that content instead (the
           first matching rule wins); content MALFORMED returns a non-JSON body
           (eval harness tests score cases differently in one run)
Every request is appended to MOCK_STATE_DIR/requests.jsonl as
{"method", "path", "body"}.

Listens on MOCK_UNIX (a unix socket path) if set, else 127.0.0.1 on an
ephemeral port written to MOCK_STATE_DIR/port.
"""
import json
import os
import socketserver
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = os.environ["MOCK_STATE_DIR"]


def state(name, default):
    try:
        with open(os.path.join(STATE, name), encoding="utf-8") as f:
            return f.read().strip("\n")
    except OSError:
        return default


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def address_string(self):
        return "mock"

    def _log(self, body):
        with open(os.path.join(STATE, "requests.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "body": body}) + "\n")

    def _raw(self, code, body, ctype="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client gave up (timeout tests)

    def _send(self, obj, code=200):
        self._raw(code, json.dumps(obj))

    def do_GET(self):
        self._log("")
        mode = state("mode", "ok") or "ok"
        if self.path == "/health":
            if mode == "hang-health":
                time.sleep(3)
            if mode == "loading":
                self._send({"error": {"code": 503, "message": "Loading model",
                                      "type": "unavailable_error"}}, 503)
            elif mode == "health500":
                self._send({"error": "broken"}, 500)
            else:
                self._send({"status": "ok"})
            return
        if self.path == "/props":
            if mode == "noctx":
                self._send({"default_generation_settings": {}, "total_slots": 1})
            else:
                n_ctx = int(state("nctx", "4096") or "4096")
                self._send({"default_generation_settings": {"n_ctx": n_ctx},
                            "total_slots": 1})
            return
        self._send({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8", "replace")
        self._log(raw)
        mode = state("mode", "ok") or "ok"
        try:
            req = json.loads(raw or "{}")
        except ValueError:
            self._send({"error": "bad json"}, 400)
            return

        if self.path == "/apply-template":
            if mode == "template-fail":
                self._send({"error": "template"}, 500)
                return
            prompt = "".join("<|%s|>%s\n" % (m.get("role"), m.get("content"))
                             for m in req.get("messages", []))
            self._send({"prompt": prompt + "<|assistant|>"})
            return

        if self.path == "/tokenize":
            if mode == "tokenize-fail":
                self._send({"error": "tokenize"}, 500)
                return
            n = len(req.get("content", "").encode()) // 4 + 1
            if mode == "toolong":
                n = int(state("nctx", "4096") or "4096")
            self._send({"tokens": list(range(n))})
            return

        if self.path == "/v1/chat/completions":
            if mode == "timeout":
                time.sleep(5)
            if mode == "oversize":
                self._send({"error": {"code": 400, "type": "exceed_context_size_error",
                                      "message": "too long"}}, 400)
                return
            if mode == "malformed":
                self._raw(200, "{not json")
                return
            content = state("content", '{"verdict":"nonsensitive"}')
            msgs = req.get("messages") or [{}]
            user = str(msgs[-1].get("content", ""))
            for rule in state("rules", "").splitlines():
                marker, _, out = rule.partition("\t")
                if marker and marker in user:
                    if out == "MALFORMED":
                        self._raw(200, "{not json")
                        return
                    content = out
                    break
            finish = "stop"
            if mode == "truncated":
                content, finish = '{"verdict":"sens', "length"
            self._send({"object": "chat.completion",
                        "model": req.get("model"),
                        "choices": [{"index": 0, "finish_reason": finish,
                                     "message": {"role": "assistant",
                                                 "content": content}}]})
            return

        self._send({"error": "not found"}, 404)


class UnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


if __name__ == "__main__":
    sock = os.environ.get("MOCK_UNIX")
    if sock:
        UnixHTTPServer(sock, Handler).serve_forever()
    else:
        srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        with open(os.path.join(STATE, "port.tmp"), "w", encoding="utf-8") as f:
            f.write(str(srv.server_address[1]))
        os.replace(os.path.join(STATE, "port.tmp"), os.path.join(STATE, "port"))
        srv.serve_forever()
