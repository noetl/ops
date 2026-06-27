"""Local MLX serving endpoint for a trained SLM — RFC Option A.

A thin stdlib ``http.server`` over ``slm_infer.SlmRunner``.  It loads a model
artifact (the v3 LoRA adapter for travel) once at boot and exposes the two
inference passes the planner's shadow branch calls, returning the SAME shapes
``extract_turn`` / ``render_widget_chat`` produce so a shadow step compares
field-for-field:

  * ``POST /extract``  {turn}              -> {extract, latency_ms, schema_valid}
  * ``POST /render``   {turn, extraction}  -> {render,  latency_ms, schema_valid, widget_types}
  * ``GET  /healthz``                       -> {ok, backend, model, constrained}

``extract`` is ``{slot_updates, tool_requests, render_intent}`` (the contract
object); ``render`` is ``{bot_message, widgets}``.  ``schema_valid`` is computed
here with ``slm_common`` against the same contract + widget schemas the eval
engine uses, so the worker shadow step stays thin (it doesn't need the schemas).

Serving stance (RFC §5 Option A): a single-host Apple-Silicon pilot.  This is
NOT a prod path — there is no auth, it binds to a dev host, and the planner
reaches it over a tunnel / the kind host gateway.  It mutates nothing; it only
runs the model and returns JSON.

Run (needs the mlx venv — mlx_lm + lm-format-enforcer):

    .slm-venv/bin/python lib/slm_serve.py \
        --config <slm.config.yaml> \
        --model-artifact <.../v3/models/travel_slm_multitask-mlx> \
        --host 0.0.0.0 --port 8099 --constrained-decode
"""

import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_common as C  # noqa: E402


# ── runner setup (mirrors slm_eval.evaluate's candidate=slm wiring) ──────────

def build_runner(config_path, *, model_artifact=None, model_ref=None,
                 tenant=None, project=None, constrained_decode=None):
    import slm_infer as INFER
    cfg, cfg_dir = C.load_config(config_path)
    dom = cfg["slm_domain"]
    roles = dom.get("roles", [])

    def _role(role_id):
        for r in roles:
            if r.get("id") == role_id:
                return r
        return {}

    extract_role = _role("extract")
    render_role = _role("render")
    extract_schema = C.resolve(cfg_dir, extract_role.get("output_schema"))
    render_schema = C.resolve(cfg_dir, render_role.get("output_schema"))
    widget_dir = C.resolve(cfg_dir, render_role.get("widget_schema_dir"))

    oracle_ref = extract_role.get("deterministic_oracle", {})
    oracle = C.import_module_from_path(C.resolve(cfg_dir, oracle_ref.get("module")))
    tool_vocab = set(getattr(oracle, "TOOL_VOCAB", []))
    intent_vocab = set(getattr(oracle, "RENDER_INTENT_VOCAB", []))

    artifact = model_artifact
    meta = {}
    if not artifact:
        import slm_eval as EVAL
        artifact, meta = EVAL._resolve_model_artifact(dom, model_ref, tenant, project)

    runner = INFER.SlmRunner(
        artifact, extract_schema=extract_schema, widget_dir=widget_dir,
        tool_vocab=tool_vocab, intent_vocab=intent_vocab,
        render_schema=render_schema, constrained_decode=constrained_decode)
    return runner, {
        "extract_schema": extract_schema, "widget_dir": widget_dir,
        "domain": dom.get("name"), "meta": meta,
    }


def _extract_schema_valid(extract, extract_schema):
    if not extract_schema:
        return True
    return len(C.validate_against_schema(extract, extract_schema)) == 0


def _render_schema_valid(render, widget_dir):
    if not widget_dir:
        return True
    widgets = (render or {}).get("widgets") or []
    return all(len(C.validate_envelope(w, widget_dir)) == 0 for w in widgets)


# ── http handler ─────────────────────────────────────────────────────────────

class _Handler(BaseHTTPRequestHandler):
    runner = None
    ctx = None

    def log_message(self, fmt, *args):  # quieter than the default stderr spam
        sys.stderr.write("slm_serve %s\n" % (fmt % args))

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        return json.loads(raw.decode("utf-8") or "{}")

    def do_GET(self):
        if self.path.rstrip("/") == "/healthz":
            self._send(200, {
                "ok": True,
                "backend": self.runner.backend,
                "model": self.runner.manifest.get("base_model"),
                "constrained": self.runner.constrained,
                "domain": self.ctx.get("domain"),
            })
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        route = self.path.rstrip("/")
        try:
            payload = self._read_json()
        except Exception as exc:
            self._send(400, {"error": "bad json: %s" % exc})
            return
        try:
            if route == "/extract":
                turn = payload.get("turn") or {}
                t0 = time.perf_counter()
                extract = self.runner.run_extract(turn)
                lat = round((time.perf_counter() - t0) * 1000.0, 1)
                self._send(200, {
                    "extract": extract,
                    "latency_ms": lat,
                    "schema_valid": _extract_schema_valid(extract, self.ctx["extract_schema"]),
                })
            elif route == "/render":
                turn = payload.get("turn") or {}
                extraction = payload.get("extraction") or {}
                t0 = time.perf_counter()
                render = self.runner.run_render(turn, extraction)
                lat = round((time.perf_counter() - t0) * 1000.0, 1)
                self._send(200, {
                    "render": render,
                    "latency_ms": lat,
                    "schema_valid": _render_schema_valid(render, self.ctx["widget_dir"]),
                    "widget_types": [w.get("widget_type") for w in render.get("widgets", [])],
                })
            else:
                self._send(404, {"error": "unknown route %r" % route})
        except Exception as exc:  # serving must never 500 the model into the planner
            self._send(500, {"error": "%s: %s" % (type(exc).__name__, exc)})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--model-artifact", default=None, help="local artifact dir/.tar.gz (Option A pilot)")
    ap.add_argument("--model-ref", default=None, help="registry:// URN or 'latest'")
    ap.add_argument("--tenant", default=None)
    ap.add_argument("--project", default=None)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--constrained-decode", dest="constrained_decode", action="store_true", default=None)
    ap.add_argument("--no-constrained-decode", dest="constrained_decode", action="store_false")
    args = ap.parse_args()

    print("loading runner (this pulls base weights + fuses the LoRA adapter)…", file=sys.stderr)
    runner, ctx = build_runner(
        args.config, model_artifact=args.model_artifact, model_ref=args.model_ref,
        tenant=args.tenant, project=args.project, constrained_decode=args.constrained_decode)
    _Handler.runner = runner
    _Handler.ctx = ctx
    httpd = ThreadingHTTPServer((args.host, args.port), _Handler)
    print("slm_serve ready: backend=%s model=%s constrained=%s on http://%s:%d"
          % (runner.backend, runner.manifest.get("base_model"), runner.constrained,
             args.host, args.port), file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
