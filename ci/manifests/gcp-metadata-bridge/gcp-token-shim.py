#!/usr/bin/env python3
"""Host-side GCP metadata-token shim for the kind NoETL stack — KIND-DEV ONLY.

Serves the GKE metadata token contract on the host:
  GET <any path>  ->  {"access_token": "...", "expires_in": N, "token_type": "Bearer"}
backed by the host's Application Default Credentials
(`gcloud auth application-default print-access-token`).

Two consumers reach this shim (see gcp-metadata-bridge.yaml + README.md):
  * The kind noetl-server pod points NOETL_GCP_METADATA_TOKEN_URL at
    http://host.containers.internal:48710/token so its GcpSecretManager /
    GcpKms / GcpIam providers mint tokens from the host ADC instead of a
    (nonexistent) in-cluster metadata server.
  * The worker in-python provider MCP playbooks read
    http://metadata.google.internal/.../token, which the in-cluster
    `gcp-metadata` socat relay forwards to host.containers.internal:48710.

No secret material is ever logged.  DO NOT run any equivalent on GKE —
there the real metadata server + Workload Identity provide the token.
"""
import json
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 48710
_cache = {"token": None, "exp": 0}
_TTL = 3000  # refresh well inside the ~3600s ADC token life


def _token():
    now = time.time()
    if _cache["token"] and _cache["exp"] > now:
        return _cache["token"]
    out = subprocess.run(
        ["gcloud", "auth", "application-default", "print-access-token"],
        capture_output=True, text=True, timeout=30,
    )
    if out.returncode != 0:
        raise RuntimeError("gcloud ADC token mint failed: " + out.stderr[:200])
    tok = out.stdout.strip()
    _cache["token"] = tok
    _cache["exp"] = now + _TTL
    return tok


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            tok = _token()
            body = json.dumps(
                {"access_token": tok, "expires_in": 3600, "token_type": "Bearer"}
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:  # noqa: BLE001
            msg = json.dumps({"error": str(e)[:200]}).encode()
            self.send_response(500)
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)

    def log_message(self, *a):  # silence access logs (never log tokens)
        pass


if __name__ == "__main__":
    print(f"gcp-token-shim listening on 0.0.0.0:{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
