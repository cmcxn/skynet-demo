"""Deterministic model/transport fixtures. No credentials or external traffic."""
import base64
import json
import os
import ssl
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

COUNTS = {}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass  # Never log Authorization, request bodies or URLs.

    def response(self, status, body, headers=None):
        raw = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", (headers or {}).get("Content-Type", "application/json"))
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.send_header("X-Request-ID", "fixture-request")
        for k, v in (headers or {}).items():
            if k.lower() != "content-type":
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)
        self.close_connection = True

    def sse(self, events, *, truncate=False):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        wire = b""
        for event in events:
            if isinstance(event, str):
                wire += ("data: " + event + "\r\n\r\n").encode()
            else:
                raw = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
                if "type" in event:
                    wire += ("event: " + event["type"] + "\r\n").encode()
                wire += ("data: " + raw + "\r\n\r\n").encode()
        # Small unrelated HTTP chunks split SSE fields, UTF8 and JSON tokens.
        for start in range(0, len(wire), 7):
            chunk = wire[start:start + 7]
            self.wfile.write(("%x\r\n" % len(chunk)).encode() + chunk + b"\r\n")
        if not truncate:
            self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        self.response(200, {"ok": True})

    def do_POST(self):
        try:
            size = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(size) or b"{}")
            path = self.path
            model = body.get("model", "fixture")
            local_options = {"timeout_ms", "queue_timeout_ms", "connect_timeout_ms", "idle_timeout_ms",
                             "priority", "request_id", "expected_dimensions", "retry", "cancel_token"}
            if local_options.intersection(body):
                return self.response(400, {"error": {"message": "local options leaked into model body"}})
            if model == "echo-auth-error":
                return self.response(401, {"error": {"message": self.headers.get("Authorization", "")}})
            if path.endswith("/transport/json"):
                return self.response(200, {"ok": True})
            if path.endswith("/transport/chunked") or path.endswith("/transport/idle-callback"):
                return self.sse([{"text": "你好"}, "[DONE]"])
            if path.endswith("/transport/wrong-content-type"):
                return self.response(200, b"data: x\n\n", {"Content-Type": "text/event-stream-invalid"})
            if path.endswith("/transport/huge-chunk"):
                self.send_response(200)
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                self.wfile.write(b"2000001\r\n")
                self.close_connection = True
                return
            if path.endswith("/transport/bad-framing"):
                self.send_response(200)
                self.send_header("Transfer-Encoding", "chunked")
                self.send_header("Content-Length", "5")
                self.end_headers()
                self.wfile.write(b"0\r\n\r\n")
                self.close_connection = True
                return
            if path.endswith("/transport/compressed"):
                return self.response(200, b"gzip", {"Content-Encoding": "gzip"})
            if path.endswith("/transport/huge-header"):
                return self.response(200, {}, {"X-Huge": "x" * 40000})
            if path.endswith("/transport/terminal-tail"):
                return self.response(200, b"data: [DONE]\n\ndata: \xff\n\n", {"Content-Type": "text/event-stream"})
            if path.endswith("/transport/redirect"):
                return self.response(302, {}, {"Location": "/v1/transport/json"})
            if path.endswith("/transport/truncated"):
                self.send_response(200)
                self.send_header("Content-Length", "100")
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(b"{}")
                self.close_connection = True
                return
            if path.endswith("/transport/slow-header"):
                time.sleep(2)
                return self.response(200, {"ok": True})
            if path.endswith("/transport/slow-body"):
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.flush()
                time.sleep(2)
                self.wfile.write(b"{}")
                self.close_connection = True
                return
            if path.startswith("/delay/") or str(model).startswith("delay:"):
                delay = int(str(model).split(":", 1)[1]) if ":" in str(model) else 200
                time.sleep(min(delay, 3000) / 1000)
            if path.startswith("/retry/") or str(model).startswith("retry:"):
                key = (path, model)
                with LOCK:
                    count = COUNTS.get(key, 0)
                    COUNTS[key] = count + 1
                if count == 0:
                    return self.response(503, {"error": {"message": "temporary"}}, {"Retry-After": "0"})
            if path.startswith("/error/"):
                return self.response(401, {"error": {"message": "not authorized"}})
            if path.startswith("/malformed/"):
                return self.response(200, b"{broken")
            if path.endswith("/embeddings"):
                inp = body.get("input", "")
                batch = inp if isinstance(inp, list) and (not inp or isinstance(inp[0], (str, list))) else [inp]
                dims = body.get("dimensions", 3)
                vectors = []
                for i, _ in enumerate(batch):
                    vec = [float(i + j + 1) / 10 for j in range(dims)]
                    if body.get("encoding_format") == "base64":
                        vec = base64.b64encode(struct.pack("<" + "f" * dims, *vec)).decode()
                    vectors.append({"object": "embedding", "index": i, "embedding": vec})
                return self.response(200, {"object": "list", "data": list(reversed(vectors)), "model": model,
                                           "usage": {"prompt_tokens": len(batch), "total_tokens": len(batch)}})
            if path.endswith("/chat/completions"):
                tools = body.get("tools")
                tool_done = any(m.get("role") == "tool" for m in body.get("messages", []))
                msg = {"role": "assistant", "content": "hello"}
                reason = "stop"
                if tools and not tool_done:
                    name = tools[0].get("function", tools[0]).get("name", "get_order")
                    msg = {"role": "assistant", "content": None, "tool_calls": [{"id": "call_123", "type": "function",
                           "function": {"name": name, "arguments": '{"order_id":"A123"}'}}]}
                    reason = "tool_calls"
                usage = {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5}
                res = {"id": "chatcmpl-fixture", "object": "chat.completion", "created": 1, "model": model,
                       "choices": [{"index": 0, "message": msg, "finish_reason": reason}], "usage": usage}
                if not body.get("stream"):
                    return self.response(200, res)
                base = {"id": res["id"], "object": "chat.completion.chunk", "created": 1, "model": model}
                if reason == "tool_calls":
                    delta = {"role": "assistant", "tool_calls": [{"index": 0, **msg["tool_calls"][0]}]}
                else:
                    delta = {"role": "assistant", "content": "hello"}
                first = {**base, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
                events = [first]
                if model == "cut-stream":
                    return self.sse(events, truncate=True)
                if model == "many-events":
                    events += [{**base, "choices": [{"index": 0, "delta": {"content": "x"}, "finish_reason": None}]} for _ in range(80)]
                events += [{**base, "choices": [{"index": 0, "delta": {}, "finish_reason": reason}]},
                           {**base, "choices": [], "usage": usage}, "[DONE]"]
                return self.sse(events)
            if path.endswith("/responses"):
                inp = body.get("input", [])
                has_result = isinstance(inp, list) and any(isinstance(i, dict) and i.get("type") == "function_call_output" for i in inp)
                output = [{"id": "msg_1", "type": "message", "role": "assistant", "status": "completed",
                           "content": [{"type": "output_text", "text": "hello", "annotations": []}]}]
                if body.get("tools") and not has_result and not body.get("previous_response_id"):
                    output = [{"id": "fc_1", "type": "function_call", "call_id": "call_123", "status": "completed",
                               "name": body["tools"][0]["name"], "arguments": '{"order_id":"A123"}'}]
                res = {"id": "resp_fixture", "object": "response", "status": "completed", "model": model,
                       "store": body.get("store", False), "output": output,
                       "usage": {"input_tokens": 2, "output_tokens": 3, "total_tokens": 5}}
                if not body.get("stream"):
                    return self.response(200, res)
                return self.sse([{"type": "response.created", "response": {**res, "status": "in_progress", "output": []}},
                                 {"type": "response.output_item.added", "output_index": 0, "item": output[0]},
                                 {"type": "response.output_item.done", "output_index": 0, "item": output[0]},
                                 {"type": "response.completed", "response": res}])
            self.response(404, {"error": {"message": "unknown fixture route"}})
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            self.close_connection = True
        except Exception:
            self.response(500, {"error": {"message": "fixture input error"}})


def serve(port, cert=None, key=None):
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.daemon_threads = True
    if cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def blackhole():
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", 18081))
    listener.listen()
    def hold(conn):
        with conn:
            time.sleep(2)
    while True:
        conn, _ = listener.accept()
        threading.Thread(target=hold, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    certs = Path(os.getenv("FIXTURE_CERT_DIR", "/fixtures"))
    serve(18080)
    serve(18443, str(certs / "server.pem"), str(certs / "server.key"))
    serve(18444, str(certs / "expired.pem"), str(certs / "server.key"))
    threading.Thread(target=blackhole, daemon=True).start()
    print("mock model HTTP/TLS fixtures ready", flush=True)
    threading.Event().wait()
