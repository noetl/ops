"""Shadow comparison core — the engine behind the planner shadow branch.

Phase: shadow rollout (RFC ``docs/rfc/travel-slm-shadow-rollout.md``, Option A).
This module is the host-side / library form of the per-turn comparison the
planner's ``log_shadow_comparison`` step performs inline: given the LIVE
(oracle) extract+render a turn actually served and the SLM's shadow
extract+render for the same turn, it computes per-field agreement, schema
validity, and packages the comparison record that becomes the data-flywheel's
capture point.

Two deliberate properties:

  * **Same field shape as ``slm_eval``.**  The agreement extractors
    (``_first_tool`` / ``_intent`` / ``_widget_types`` …) are byte-identical to
    the eval engine's, so a captured shadow corpus is scored by the SAME metric
    code pointed at a real-traffic data source — no new metric to keep in sync
    (RFC §2.4).
  * **Pure stdlib.**  ``ShadowClient`` is a thin ``urllib`` wrapper over the
    ``slm_serve`` endpoint; nothing here imports torch / mlx.  The planner's
    worker step inlines the same urllib POST + equality checks; this module is
    the importable twin used by the host validation harness + the flywheel.

The SLM output **never** reaches a user response.  This module only reads the
live output and the SLM output and emits a comparison; it has no path back into
the served turn (RFC §2.2 invariant 1).
"""

import json
import time
import urllib.error
import urllib.request


# ── field extractors (identical to slm_eval — keep in lockstep) ──────────────

def first_tool(extract):
    reqs = (extract or {}).get("tool_requests") or []
    return reqs[0].get("tool", "") if reqs else ""


def first_args(extract):
    reqs = (extract or {}).get("tool_requests") or []
    return reqs[0].get("arguments", {}) if reqs else {}


def render_intent_kind(extract):
    return ((extract or {}).get("render_intent") or {}).get("kind")


def widget_types(render):
    return [w.get("widget_type") for w in (render or {}).get("widgets", [])]


# ── per-field agreement ──────────────────────────────────────────────────────

def compare_extract(live_extract, slm_extract):
    """Per-field agreement between a live and an SLM extract output.  Each value
    is a bool (the SLM matched the live path for that field).  Mirrors the
    ``slm_eval`` match metrics so shadow agreement == eval agreement."""
    return {
        "tool_match": first_tool(live_extract) == first_tool(slm_extract),
        "arg_match": first_args(live_extract) == first_args(slm_extract),
        "slot_match": (live_extract or {}).get("slot_updates") == (slm_extract or {}).get("slot_updates"),
        "render_intent_match": render_intent_kind(live_extract) == render_intent_kind(slm_extract),
    }


def compare_render(live_render, slm_render):
    """Per-field agreement between a live and an SLM render output."""
    return {
        "widget_type_match": widget_types(live_render) == widget_types(slm_render),
        "bot_message_match": (live_render or {}).get("bot_message") == (slm_render or {}).get("bot_message"),
    }


def agreement_summary(records):
    """Aggregate a list of shadow records into per-field agreement rates +
    schema-validity rates + latency p50 — the same headline numbers
    ``slm_eval`` reports, but measured on real shadow traffic."""
    n = len(records) or 1
    fields = ["tool_match", "arg_match", "slot_match", "render_intent_match",
              "widget_type_match", "bot_message_match"]
    agg = {f: 0 for f in fields}
    extract_valid = render_valid = 0
    ex_seen = rd_seen = 0
    ex_lat = []
    rd_lat = []
    fell_back = 0
    for r in records:
        a = r.get("agreement", {})
        for f in fields:
            if a.get(f):
                agg[f] += 1
        sv = r.get("schema_valid", {})
        if "extract" in sv:
            ex_seen += 1
            extract_valid += 1 if sv["extract"] else 0
        if "render" in sv:
            rd_seen += 1
            render_valid += 1 if sv["render"] else 0
        if r.get("slm_extract_latency_ms") is not None:
            ex_lat.append(r["slm_extract_latency_ms"])
        if r.get("slm_render_latency_ms") is not None:
            rd_lat.append(r["slm_render_latency_ms"])
        if r.get("fell_back"):
            fell_back += 1

    def _p50(xs):
        if not xs:
            return None
        s = sorted(xs)
        return round(s[len(s) // 2], 1)

    return {
        "n": len(records),
        "agreement": {f: round(agg[f] / n, 4) for f in fields},
        "schema_validity": {
            "extract": round(extract_valid / ex_seen, 4) if ex_seen else None,
            "render": round(render_valid / rd_seen, 4) if rd_seen else None,
        },
        "latency_ms_p50": {"extract": _p50(ex_lat), "render": _p50(rd_lat)},
        "fell_back": fell_back,
    }


# ── record builder ───────────────────────────────────────────────────────────

def build_record(turn, live_extract, live_render, slm_extract, slm_render,
                 *, schema_valid=None, slm_extract_latency_ms=None,
                 slm_render_latency_ms=None, fell_back=False, error=None,
                 execution_id=None):
    """Assemble the shadow comparison record.  This is the flywheel capture
    object: it carries the turn INPUT, the live (chosen) output, the SLM output,
    and the agreement — everything ``slm_replay`` needs to turn a real turn into
    a labelable training example, and everything ``slm_eval``'s aggregation
    needs to score the SLM on real traffic.

    The SLM output is recorded but **not chosen**: ``chosen == "live"`` always
    in shadow mode (RFC §2.2)."""
    rec = {
        "kind": "slm_shadow_comparison",
        "execution_id": execution_id,
        "turn": {
            "event_type": turn.get("event_type"),
            "event_payload": turn.get("event_payload"),
            "slot_state": turn.get("slot_state"),
        },
        "live_extract": live_extract,
        "live_render": live_render,
        "slm_extract": slm_extract,
        "slm_render": slm_render,
        "chosen": "live",            # shadow never serves the SLM output
        "agreement": {},
        "schema_valid": schema_valid or {},
        "slm_extract_latency_ms": slm_extract_latency_ms,
        "slm_render_latency_ms": slm_render_latency_ms,
        "fell_back": bool(fell_back),
        "error": error,
    }
    if not fell_back and slm_extract is not None:
        rec["agreement"].update(compare_extract(live_extract, slm_extract))
    if not fell_back and slm_render is not None:
        rec["agreement"].update(compare_render(live_render, slm_render))
    return rec


# ── thin HTTP client over slm_serve ──────────────────────────────────────────

class ShadowClient:
    """stdlib urllib client for the ``slm_serve`` MLX endpoint.  All errors
    (endpoint down, timeout, decode) surface as ``ShadowError`` so the caller
    can record ``fell_back`` and move on — the planner's worker step inlines the
    same try/except (RFC §3.3 fallback rule)."""

    def __init__(self, endpoint, timeout_ms=60000):
        self.endpoint = endpoint.rstrip("/")
        self.timeout_s = max(0.1, timeout_ms / 1000.0)

    def _post(self, route, body):
        url = self.endpoint + route
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            url, data=data, headers={"Content-Type": "application/json"}, method="POST")
        t0 = time.perf_counter()
        with urllib.request.urlopen(req, timeout=self.timeout_s) as resp:
            out = json.loads(resp.read().decode("utf-8"))
        out.setdefault("client_latency_ms", round((time.perf_counter() - t0) * 1000.0, 1))
        return out

    def extract(self, turn):
        return self._post("/extract", {"turn": turn})

    def render(self, turn, extraction):
        return self._post("/render", {"turn": turn, "extraction": extraction})

    def healthz(self):
        with urllib.request.urlopen(self.endpoint + "/healthz", timeout=self.timeout_s) as resp:
            return json.loads(resp.read().decode("utf-8"))


class ShadowError(Exception):
    pass
