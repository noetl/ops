"""Toy second-domain oracle — support-ticket triage.

Deliberately unrelated to travel.  Its only job is to prove the generic
`automation/mlops/slm` template pack is config-only per domain: this domain
stands up dataset_build + eval by supplying its own config + oracle + corpus +
schema, with ZERO edits to the framework playbooks or engine (the RFC §2.2
"second domain" extraction test).

Contract: a support message -> {category, priority}.  No tools, no widgets —
a different shape from travel, on purpose.
"""

RENDER_INTENT_VOCAB = ["billing", "technical", "account", "other"]
TOOL_VOCAB = []  # this domain emits no tools

_RULES = [
    ("billing", ("refund", "charge", "invoice", "payment", "billed", "subscription")),
    ("technical", ("error", "crash", "bug", "broken", "not working", "fails")),
    ("account", ("login", "password", "sign in", "locked", "access", "email")),
]


def extract(turn):
    text = (turn.get("event_payload") or {}).get("text", "").lower()
    category = "other"
    for cat, kws in _RULES:
        if any(k in text for k in kws):
            category = cat
            break
    high = any(k in text for k in ("urgent", "asap", "immediately", "down", "can't"))
    priority = "high" if high else ("low" if category == "other" else "medium")
    return {"category": category, "priority": priority, "render_intent": {"kind": category}}


def render(turn, extraction=None, tool_summary=None):
    if extraction is None:
        extraction = extract(turn)
    return {
        "bot_message": "Routed to %s (%s priority)." % (extraction["category"], extraction["priority"]),
        "widgets": [],
    }


def run_turn(turn):
    ex = extract(turn)
    return {"extract": ex, "render": render(turn, ex), "tool_summary": {}}
