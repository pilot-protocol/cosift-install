#!/usr/bin/env python3
"""Fake cosift-auth + cosift-mcp on one port. Python 3 stdlib only.

Scenario comes from COSIFT_MOCK_SCENARIO; every request is appended as one JSON
object per line to COSIFT_MOCK_LOG so tests can assert on what the installer sent.
"""

import json
import os
import random
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCENARIO = os.environ.get("COSIFT_MOCK_SCENARIO", "ok")
LOG_PATH = os.environ.get("COSIFT_MOCK_LOG", "/tmp/cosift-mock/requests.jsonl")
PORT = int(os.environ.get("COSIFT_MOCK_PORT", "8787"))
CODE = os.environ.get("COSIFT_MOCK_CODE", "123456")
START_DELAY_MS = int(os.environ.get("COSIFT_MOCK_START_DELAY_MS", "800"))
FAIL_N = int(os.environ.get("COSIFT_MOCK_FAIL_N", "2"))

MINTED_TOKEN = os.environ.get(
    "COSIFT_MOCK_TOKEN", "ck_k1a_ABCDEFGHIJKLMNOPQRSTUVWXYZ234567ABCDEFG"
)
ACCOUNT_UID = os.environ.get("COSIFT_MOCK_ACCOUNT_UID", "deadbeefdeadbeef")
VALID_TOKENS = {MINTED_TOKEN}
VALID_TOKENS.update(
    t for t in os.environ.get("COSIFT_MOCK_VALID_TOKENS", "").split(",") if t
)

ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

_lock = threading.Lock()
_state = {"issued": set(), "verify_calls": 0, "mcp_calls": 0}


def _now_rfc3339():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ulid():
    return "".join(random.choice(ULID_ALPHABET) for _ in range(26))


def _log(record):
    with _lock:
        os.makedirs(os.path.dirname(LOG_PATH) or ".", exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, sort_keys=True) + "\n")
            fh.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "cosift-mock/0"

    def log_message(self, fmt, *args):  # silence stderr chatter
        pass

    # ---- plumbing -------------------------------------------------------
    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, status, payload, extra_headers=None, raw=False):
        if raw:
            body = payload if isinstance(payload, bytes) else payload.encode()
            ctype = "text/html; charset=utf-8"
        else:
            body = json.dumps(payload).encode()
            ctype = "application/json"
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)
        return status

    def _record(self, method, body, status):
        _log(
            {
                "ts": _now_rfc3339(),
                "scenario": SCENARIO,
                "method": method,
                "path": self.path,
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": body.decode("utf-8", "replace"),
                "status": status,
            }
        )

    def do_GET(self):
        self._dispatch("GET", b"")

    def do_POST(self):
        self._dispatch("POST", self._read_body())

    def do_PUT(self):
        self._dispatch("PUT", self._read_body())

    def do_DELETE(self):
        self._dispatch("DELETE", b"")

    def _dispatch(self, method, body):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        try:
            status = self._route(method, path, body)
        except Exception as exc:  # pragma: no cover - mock must never wedge
            status = self._send(500, {"detail": "mock error: %s" % exc})
        self._record(method, body, status)

    # ---- routes ---------------------------------------------------------
    def _route(self, method, path, body):
        if path == "/health" and method == "GET":
            return self._send(200, {"status": "ok"})
        # Google's frontend answers /healthz and never forwards; mimicking that
        # here makes a wrong probe path look healthy, and tests assert nobody hit it.
        if path == "/healthz":
            return self._send(
                200, "<html><title>Google</title><body>ok</body></html>", raw=True
            )
        if path == "/auth/start":
            return self._auth_start(method, body)
        if path == "/auth/verify":
            return self._auth_verify(method, body)
        if path == "/v1/mcp":
            return self._mcp(method, body)
        return self._send(404, {"detail": "no such route"})

    def _auth_start(self, method, body):
        if method != "POST":
            return self._send(405, {"detail": "method not allowed"})
        if SCENARIO == "ratelimited":
            return self._send(429, {"detail": "rate limited"})
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        if ctype != "application/json":
            return self._send(415, {"detail": "expected application/json"})
        time.sleep(START_DELAY_MS / 1000.0)
        rid = _ulid()
        with _lock:
            _state["issued"].add(rid)
        return self._send(200, {"request_id": rid, "expires_at": _now_rfc3339()})

    def _auth_verify(self, method, body):
        if method != "POST":
            return self._send(405, {"detail": "method not allowed"})
        with _lock:
            _state["verify_calls"] += 1
            n = _state["verify_calls"]
        if SCENARIO == "ratelimited":
            return self._send(429, {"detail": "rate limited"})
        if SCENARIO == "banned":
            return self._send(
                403,
                {
                    "error": "Forbidden",
                    "status": 403,
                    "detail": "account is banned; a new token will not help",
                },
            )
        if SCENARIO == "unavailable" and n <= FAIL_N:
            return self._send(503, {"detail": "temporarily unavailable"})
        if SCENARIO == "wrongcode":
            return self._unauthorized()
        try:
            payload = json.loads(body or b"{}")
        except ValueError:
            return self._unauthorized()
        rid = payload.get("request_id")
        code = str(payload.get("code", ""))
        with _lock:
            known = rid in _state["issued"]
        if not known or code != CODE:
            return self._unauthorized()
        return self._send(200, {"token": MINTED_TOKEN, "account_uid": ACCOUNT_UID})

    def _unauthorized(self):
        return self._send(
            401,
            {
                "error": "Unauthorized",
                "status": 401,
                "detail": "invalid or expired code",
            },
        )

    def _mcp(self, method, body):
        if method != "POST":
            return self._send(405, {"detail": "method not allowed"})
        with _lock:
            _state["mcp_calls"] += 1
        if SCENARIO == "mcp421":
            return self._send(421, {"detail": "host not allowed"})
        accept = (self.headers.get("Accept") or "").lower()
        if "application/json" not in accept or "text/event-stream" not in accept:
            return self._send(
                406,
                {
                    "detail": "client must accept both application/json and "
                    "text/event-stream"
                },
            )
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        if ctype != "application/json":
            return self._send(415, {"detail": "expected application/json"})
        auth = self.headers.get("Authorization") or ""
        token = auth[7:] if auth.startswith("Bearer ") else ""
        if SCENARIO == "mcp401" or not token or token not in VALID_TOKENS:
            return self._send(401, {"error": "invalid_token"})
        try:
            rpc = json.loads(body or b"{}")
        except ValueError:
            return self._send(400, {"detail": "bad json-rpc body"})
        if rpc.get("method") != "initialize":
            return self._send(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": rpc.get("id"),
                    "error": {"code": -32601, "message": "method not found"},
                },
            )
        return self._send(
            200,
            {
                "jsonrpc": "2.0",
                "id": rpc.get("id", 1),
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "cosift-mock", "version": "0"},
                },
            },
            extra_headers={"Mcp-Session-Id": "mock-session"},
        )


def main():
    known = {
        "ok",
        "wrongcode",
        "banned",
        "unavailable",
        "ratelimited",
        "mcp401",
        "mcp421",
    }
    if SCENARIO not in known:
        sys.stderr.write("unknown COSIFT_MOCK_SCENARIO=%s\n" % SCENARIO)
        return 2
    os.makedirs(os.path.dirname(LOG_PATH) or ".", exist_ok=True)
    open(LOG_PATH, "a", encoding="utf-8").close()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    sys.stderr.write("cosift-mock scenario=%s port=%d\n" % (SCENARIO, PORT))
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
