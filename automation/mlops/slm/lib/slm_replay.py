"""Generic SLM event-log replay ingestion — real traffic -> a labelable corpus.

Domain-agnostic.  Pulls real executions of a consuming playbook from the NoETL
server's HTTP API (READ-ONLY — never mutates prod, honoring the data-access
boundary: ``noetl.*`` is reached only through the server API), extracts each
turn's INPUT (the user event + prior slot state) and the production label the
playbook actually emitted, redacts PII, and writes a corpus JSONL in the exact
shape ``dataset_build`` reads from the seed corpus.

The corpus this produces is the *held-out golden eval set from real traffic*
that Phase 1 calls for: ``dataset_build`` re-labels each input with the
deterministic floor + the teacher ceiling, and ``eval`` measures the
floor↔ceiling gap on it.  The production label captured here (``prod_extract``)
is carried along as a third reference — it is itself a real hosted-LLM label,
so teacher↔prod agreement is a sanity check that the teacher reproduces what
production does.

Config (read from the org ``slm.config.yaml`` ``data.event_log_replay`` block):
  * ``server_api`` / ``--base-url``  — the server base URL (default localhost).
  * ``path``                          — the consuming playbook catalog path.
  * the redaction policy + sample cap arrive via CLI flags / config.

Transport: stdlib ``urllib`` only.  No write verbs are ever issued.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_common as C  # noqa: E402

# ── PII redaction ───────────────────────────────────────────────────────────
_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
# ISO date / datetime — semantically load-bearing for travel, must be PRESERVED.
_ISO_DATE_RE = re.compile(r"\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?\b")
# phone: a run of digits + grouping punctuation; redacted only if it holds
# >=9 digits, so flight numbers / "1 adult" / counts don't match.
_PHONE_RE = re.compile(r"\+?[\d][\d\s\-().]{7,}\d")
_CARD_RE = re.compile(r"(?<!\d)(?:\d[ -]?){13,19}(?!\d)")
# "for John Smith" / "passenger John Smith" / "name is John Smith" — conservative
_NAME_RE = re.compile(
    r"\b(?:for|passenger|name is|traveller|traveler|under)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,2})"
)


def redact_text(text):
    if not isinstance(text, str) or not text:
        return text
    # protect ISO dates/times from the phone+card passes, then restore
    protected = []

    def _stash(m):
        protected.append(m.group(0))
        return "\x00%d\x00" % (len(protected) - 1)

    out = _ISO_DATE_RE.sub(_stash, text)
    out = _CARD_RE.sub("[REDACTED_NUM]", out)
    out = _EMAIL_RE.sub("[REDACTED_EMAIL]", out)
    out = _PHONE_RE.sub(
        lambda m: "[REDACTED_PHONE]" if sum(c.isdigit() for c in m.group(0)) >= 9 else m.group(0),
        out,
    )
    out = _NAME_RE.sub(lambda m: m.group(0).split()[0] + " [REDACTED_NAME]", out)
    for i, val in enumerate(protected):
        out = out.replace("\x00%d\x00" % i, val)
    return out


def redact_payload(payload):
    if not isinstance(payload, dict):
        return payload
    red = dict(payload)
    for key in ("text", "message", "label"):
        if isinstance(red.get(key), str):
            red[key] = redact_text(red[key])
    return red


# ── server API (read-only) ──────────────────────────────────────────────────
def _get(base_url, path_and_query, timeout=30):
    url = base_url.rstrip("/") + path_and_query
    req = urllib.request.Request(url, method="GET")  # READ-ONLY
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _deep_find(obj, keys, depth=0, max_depth=12):
    """Yield values for any of ``keys`` found anywhere in a nested structure."""
    if depth > max_depth:
        return
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in keys:
                yield k, v
            yield from _deep_find(v, keys, depth + 1, max_depth)
    elif isinstance(obj, list):
        for item in obj:
            yield from _deep_find(item, keys, depth + 1, max_depth)


def _parse_prod_extract(detail, extract_node="extract_turn"):
    """Pull the production extraction label out of an execution's events.

    Prefers the verbatim ``json_str`` the planner emits (the exact contract
    object); falls back to reconstructing from ``first_tool`` + slot captures.
    """
    for e in detail.get("events", []):
        if e.get("node_name") != extract_node:
            continue
        if e.get("event_type") not in ("call.done", "command.completed"):
            continue
        result = e.get("result")
        # 1) verbatim json_str (the contract object as the planner serialized it)
        for _, v in _deep_find(result, {"json_str"}):
            if isinstance(v, str):
                try:
                    obj = json.loads(v)
                    if isinstance(obj, dict) and "render_intent" in obj:
                        return {
                            "slot_updates": obj.get("slot_updates", {}) or {},
                            "tool_requests": obj.get("tool_requests", []) or [],
                            "render_intent": obj.get("render_intent", {}) or {},
                        }
                except Exception:
                    pass
        # 2) reconstruct from structured captures
        first_tool = first_args = render_intent = slot_updates = None
        for k, v in _deep_find(result, {"first_tool", "first_tool_arguments", "render_intent", "captured_changes"}):
            if k == "first_tool" and first_tool is None:
                first_tool = v
            elif k == "first_tool_arguments" and first_args is None:
                first_args = v
            elif k == "render_intent" and render_intent is None:
                render_intent = v
            elif k == "captured_changes" and slot_updates is None:
                slot_updates = v
        if render_intent is not None:
            reqs = []
            if first_tool:
                reqs = [{"tool": first_tool, "arguments": first_args or {}}]
            return {
                "slot_updates": slot_updates or {},
                "tool_requests": reqs,
                "render_intent": render_intent,
            }
    return None


def _parse_slot_state(detail, load_node="load_slot_state"):
    """Best-effort prior slot_state from the load step's result; {} if absent
    or the load failed (e.g. cold-start turns)."""
    for e in detail.get("events", []):
        if e.get("node_name") != load_node:
            continue
        result = e.get("result")
        for _, v in _deep_find(result, {"data"}):
            if isinstance(v, dict):
                doc = v.get("document") or v
                if isinstance(doc, dict):
                    dd = doc.get("data")
                    if isinstance(dd, dict) and any(
                        kk in dd for kk in ("region", "check_in_date", "party")
                    ):
                        return dd
    return {}


def ingest(base_url, path, limit=500, out_path=None, config_path=None,
           extract_node="extract_turn", status="COMPLETED"):
    # config overrides (optional)
    if config_path:
        cfg, _ = C.load_config(config_path)
        repl = cfg.get("slm_domain", {}).get("data", {}).get("event_log_replay", {}) or {}
        path = path or repl.get("path")

    listing = _get(base_url, "/api/executions?path=%s&limit=%d" % (path, int(limit)))
    if status:
        listing = [x for x in listing if x.get("status") == status]

    turns = []
    skipped = 0
    for summ in listing:
        exec_id = summ.get("execution_id")
        try:
            detail = _get(base_url, "/api/executions/%s" % exec_id)
        except urllib.error.HTTPError:
            skipped += 1
            continue
        workload = detail.get("workload", {}) or {}
        event_type = workload.get("event_type")
        event_payload = workload.get("event_payload")
        if not event_type or event_payload in (None, {}):
            skipped += 1
            continue
        prod_extract = _parse_prod_extract(detail, extract_node)
        slot_state = _parse_slot_state(detail)
        turn = {
            "id": "replay_%s" % exec_id,
            "intent_label": ((prod_extract or {}).get("render_intent") or {}).get("kind"),
            "event_type": event_type,
            "event_payload": redact_payload(event_payload),
            "slot_state": slot_state,
            "thread_context": [],
            "source": "event_log_replay",
            "execution_id": str(exec_id),
            "started_at": summ.get("started_at"),
        }
        if prod_extract is not None:
            turn["prod_extract"] = prod_extract
        turns.append(turn)

    out_path = out_path or "replay_corpus.jsonl"
    C.write_jsonl(out_path, turns)
    return {
        "out": out_path,
        "executions_listed": len(listing),
        "turns_written": len(turns),
        "skipped": skipped,
        "with_prod_label": sum(1 for t in turns if "prod_extract" in t),
        "path": path,
    }


# ── shadow-comparison ingestion (the data flywheel) ─────────────────────────

def _find_shadow_record(detail, shadow_node="shadow_slm_compare"):
    """Pull the slm_shadow_comparison record out of an execution's events.  It is
    the result of the planner's (or selftest's) shadow leaf — the capture object
    built at ``log_shadow_comparison`` / ``shadow_slm_compare`` time."""
    for e in detail.get("events", []):
        if e.get("node_name") != shadow_node:
            continue
        if e.get("event_type") not in ("call.done", "command.completed"):
            continue
        for _, v in _deep_find(e.get("result"), {"kind"}):
            pass  # _deep_find yields (key, value); we want the dict carrying kind
        # locate the dict whose kind == slm_shadow_comparison
        rec = _locate_shadow_dict(e.get("result"))
        if rec is not None:
            return rec
    return None


def _locate_shadow_dict(obj, depth=0, max_depth=14):
    if depth > max_depth:
        return None
    if isinstance(obj, dict):
        if obj.get("kind") == "slm_shadow_comparison":
            return obj
        for v in obj.values():
            r = _locate_shadow_dict(v, depth + 1, max_depth)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = _locate_shadow_dict(v, depth + 1, max_depth)
            if r is not None:
                return r
    return None


def ingest_shadow(base_url, path, limit=500, out_path=None, config_path=None,
                  shadow_node="shadow_slm_compare", status="COMPLETED"):
    """Read shadow-comparison records (the SLM-vs-live captures from shadow mode)
    out of real executions and emit a labelable corpus in the SAME shape
    ``dataset_build`` reads — turning shadow traffic into training data.

    The turn text is re-redacted defensively (it is already redacted at capture).
    The live (oracle) output the planner actually served is carried as
    ``prod_extract`` — the same third-reference role the event-log replay uses —
    so ``dataset_build`` re-labels the input and the captured live label is a
    sanity reference.  The SLM's own shadow output rides along under
    ``slm_extract`` for offline agreement analysis.
    """
    if config_path:
        cfg, _ = C.load_config(config_path)
        repl = cfg.get("slm_domain", {}).get("data", {}).get("event_log_replay", {}) or {}
        path = path or repl.get("path")

    listing = _get(base_url, "/api/executions?path=%s&limit=%d" % (path, int(limit)))
    if status:
        listing = [x for x in listing if x.get("status") == status]

    turns = []
    skipped = with_slm = fell_back = 0
    for summ in listing:
        exec_id = summ.get("execution_id")
        try:
            detail = _get(base_url, "/api/executions/%s" % exec_id)
        except urllib.error.HTTPError:
            skipped += 1
            continue
        rec = _find_shadow_record(detail, shadow_node)
        if rec is None:
            skipped += 1
            continue
        turn = rec.get("turn", {}) or {}
        event_type = turn.get("event_type")
        event_payload = turn.get("event_payload")
        if not event_type or event_payload in (None, {}):
            skipped += 1
            continue
        live_extract = rec.get("live_extract") or {}
        prod_extract = {
            "slot_updates": live_extract.get("slot_updates", {}) or {},
            "tool_requests": live_extract.get("tool_requests", []) or [],
            "render_intent": live_extract.get("render_intent", {}) or {},
        } if live_extract else None
        out_turn = {
            "id": "shadow_%s" % exec_id,
            "intent_label": ((prod_extract or {}).get("render_intent") or {}).get("kind"),
            "event_type": event_type,
            "event_payload": redact_payload(event_payload),
            "slot_state": turn.get("slot_state", {}) or {},
            "thread_context": [],
            "source": "shadow_comparison",
            "execution_id": str(exec_id),
            "started_at": summ.get("started_at"),
        }
        if prod_extract is not None:
            out_turn["prod_extract"] = prod_extract
        if rec.get("slm_extract"):
            out_turn["slm_extract"] = rec.get("slm_extract")
            out_turn["slm_agreement"] = rec.get("agreement")
            with_slm += 1
        if rec.get("fell_back"):
            fell_back += 1
        turns.append(out_turn)

    out_path = out_path or "shadow_replay_corpus.jsonl"
    C.write_jsonl(out_path, turns)
    return {
        "out": out_path,
        "executions_listed": len(listing),
        "turns_written": len(turns),
        "skipped": skipped,
        "with_slm_shadow": with_slm,
        "fell_back": fell_back,
        "with_prod_label": sum(1 for t in turns if "prod_extract" in t),
        "path": path,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=os.environ.get("NOETL_SERVER_URL", "http://localhost:8082"))
    ap.add_argument("--path", default="muno/playbooks/itinerary-planner")
    ap.add_argument("--limit", type=int, default=500)
    ap.add_argument("--out", default=None)
    ap.add_argument("--config", default=None)
    ap.add_argument("--extract-node", default="extract_turn")
    ap.add_argument("--shadow", action="store_true",
                    help="ingest shadow-comparison records (the data flywheel) instead of raw extract labels")
    ap.add_argument("--shadow-node", default="shadow_slm_compare")
    args = ap.parse_args()
    if args.shadow:
        summary = ingest_shadow(
            args.base_url, args.path, limit=args.limit,
            out_path=args.out or "shadow_replay_corpus.jsonl",
            config_path=args.config, shadow_node=args.shadow_node)
        print("=== shadow replay ingest complete ===")
    else:
        summary = ingest(
            args.base_url, args.path, limit=args.limit,
            out_path=args.out or "replay_corpus.jsonl",
            config_path=args.config, extract_node=args.extract_node)
        print("=== replay ingest complete ===")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
