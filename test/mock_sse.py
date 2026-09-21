#!/usr/bin/env python3
"""
Minimal OpenAI-compatible SSE server used to exercise goose's stream timeouts.

    mock_sse.py <mode> <port> <delay>

modes:
  slow-prefill     send nothing for <delay> seconds, then a normal completion
                   (simulates a model thinking hard over a large prompt)
  slow-headers     wait <delay> seconds BEFORE sending the response headers,
                   then complete normally (simulates a provider that computes
                   the first token before it starts responding at all)
  dead-midstream   send one chunk, then send nothing, forever
  dead-from-start  accept the request and never send a single byte
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = sys.argv[1]
PORT = int(sys.argv[2])
DELAY = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0

FOREVER = 600.0


def sse(obj) -> bytes:
    return b"data: " + json.dumps(obj).encode() + b"\n\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the test output readable
        pass

    def _headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

    def _chunk(self, payload: bytes):
        try:
            self.wfile.write(b"%X\r\n" % len(payload) + payload + b"\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # the client hung up — exactly what the dead-* modes provoke
            raise

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        self.rfile.read(length)

        # A provider may compute before it answers at all: the delay then sits
        # in front of the response headers, not in front of the first body line.
        if MODE == "slow-headers":
            time.sleep(DELAY)

        self._headers()

        if MODE == "dead-from-start":
            time.sleep(FOREVER)
            return

        if MODE == "slow-prefill":
            time.sleep(DELAY)

        self._chunk(sse({"id": "1", "object": "chat.completion.chunk", "choices": [
            {"index": 0, "delta": {"role": "assistant", "content": "hello"}}]}))

        if MODE == "dead-midstream":
            time.sleep(FOREVER)
            return

        self._chunk(sse({"id": "1", "object": "chat.completion.chunk", "choices": [
            {"index": 0, "delta": {"content": " world"}}]}))
        self._chunk(sse({"id": "1", "object": "chat.completion.chunk", "choices": [
            {"index": 0, "delta": {}, "finish_reason": "stop"}]}))
        self._chunk(b"data: [DONE]\n\n")
        # terminating zero-length chunk, or the client reports a decode error
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


if __name__ == "__main__":
    class Server(ThreadingHTTPServer):
        daemon_threads = True

        def handle_error(self, request, client_address):
            # A client that disconnects mid-stream is the point of the dead-*
            # modes, not an error worth printing a traceback for.
            exc = sys.exc_info()[1]
            if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
                return
            super().handle_error(request, client_address)

    print(f"mock_sse: mode={MODE} port={PORT} delay={DELAY}", file=sys.stderr, flush=True)
    Server(("127.0.0.1", PORT), Handler).serve_forever()
