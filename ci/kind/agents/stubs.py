"""In-cluster stubs for ci/kind/e2e_agents_mcp_runtimes.sh, one process, three ports.

  :8081  Anthropic Messages API: turn 1 calls every offered tool, turn 2 echoes the tool_results
  :8082  A2A JSON-RPC agent: message/send -> working task, tasks/get -> completed
  :8083  MCP server (stateless, JSON): one tool `site.lookup`; requires `Authorization: Bearer <MCP_TOKEN>`
"""
import json, os, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MCP_TOKEN = os.environ.get("MCP_TOKEN", "")
TASKS = {}


def handler(mode):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, code, body=None):
            data = b"" if body is None else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.reply(200, {"status": "ok"}) if self.path.endswith("healthz") else self.reply(404, {})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
            getattr(self, mode)(body)

        def model(self, body):
            last = body["messages"][-1]["content"]
            if isinstance(last, list) and last and last[0].get("type") == "tool_result":
                texts = [b.get("content", "") for b in last]
                return self.reply(200, {"content": [{"type": "text", "text": "model saw: " + " | ".join(texts)}],
                                        "stop_reason": "end_turn", "usage": {"input_tokens": 1, "output_tokens": 1}})
            calls = [{"type": "tool_use", "id": f"tu_{i}", "name": t["name"],
                      "input": {k: "from-model" for k in (t.get("input_schema") or {}).get("properties", {})}}
                     for i, t in enumerate(body.get("tools", []))]
            self.reply(200, {"content": calls or [{"type": "text", "text": "no tools offered"}],
                             "stop_reason": "tool_use" if calls else "end_turn",
                             "usage": {"input_tokens": 1, "output_tokens": 1}})

        def a2a(self, body):
            m, p, rid = body.get("method"), body.get("params", {}), body.get("id")
            if m == "message/send":
                tid = f"t-{len(TASKS) + 1}"
                TASKS[tid] = p["message"]["parts"][0]["text"]
                return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"kind": "task", "id": tid, "status": {"state": "working"}}})
            if m == "tasks/get":
                tid = p["id"]
                return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {
                    "kind": "task", "id": tid, "status": {"state": "completed"},
                    "artifacts": [{"parts": [{"kind": "text", "text": "a2a says: " + TASKS.get(tid, "?")}]}]}})
            self.reply(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unknown method"}})

        def mcp(self, body):
            if self.headers.get("authorization", "") != f"Bearer {MCP_TOKEN}":
                return self.reply(401, {"error": "bearer required"})
            m, rid = body.get("method"), body.get("id")
            if rid is None:
                return self.reply(202)
            if m == "initialize":
                res = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "kind-stub-mcp"}}
            elif m == "tools/list":
                res = {"tools": [{"name": "site.lookup", "description": "Look a site up.",
                                  "inputSchema": {"type": "object", "properties": {"site": {"type": "string"}}}}]}
            elif m == "tools/call":
                site = (body.get("params", {}).get("arguments") or {}).get("site", "?")
                res = {"content": [{"type": "text", "text": f"site {site}: 3 links up"}], "isError": False}
            else:
                return self.reply(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unknown method"}})
            self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": res})
    return H


for port, mode in [(8081, "model"), (8082, "a2a"), (8083, "mcp")]:
    srv = ThreadingHTTPServer(("0.0.0.0", port), handler(mode))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
threading.Event().wait()
