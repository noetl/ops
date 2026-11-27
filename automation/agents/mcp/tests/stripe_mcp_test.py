#!/usr/bin/env python3
"""automation/agents/mcp/stripe.yaml: the Stripe MCP agent (TEST MODE ONLY).

Executes the step's embedded code against a patched urllib.request.urlopen,
so the HTTP the agent would send is what is asserted. No network, no key.

  python3 automation/agents/mcp/tests/stripe_mcp_test.py
"""
import base64
import io
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
PLAYBOOK = os.path.join(HERE, "..", "stripe.yaml")

failures = []


def check(cond, label):
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        failures.append(label)


class Resp(io.BytesIO):
    def __init__(self, body, status=200):
        super().__init__(json.dumps(body).encode())
        self.status, self.headers = status, {}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        pass


def http_error(url, status, body):
    return urllib.error.HTTPError(url, status, "err", {}, io.BytesIO(json.dumps(body).encode()))


state = {"secret": "sk_test_abc123", "metadata": "ok", "stripe": None}
sent = []


def secret_payload(raw):
    return {"payload": {"data": base64.b64encode(raw.encode()).decode()}}


def fake_urlopen(req, timeout=None):
    url = req.full_url
    if "metadata.google.internal" in url:
        if state["metadata"] == "down":
            raise urllib.error.URLError("Name or service not known")
        return Resp({"access_token": "wi-token"})
    if "secretmanager.googleapis.com" in url:
        return Resp(secret_payload(state["secret"]))
    if url.startswith("https://api.stripe.com/"):
        sent.append(req)
        handler = state["stripe"]
        status, body = handler(req) if handler else (200, {"id": "x", "livemode": False})
        if status >= 400:
            raise http_error(url, status, body)
        return Resp(body, status)
    raise AssertionError("unexpected URL " + url)


urllib.request.urlopen = fake_urlopen

doc = yaml.safe_load(open(PLAYBOOK))
steps = {s["step"]: s for s in doc["workflow"]}
CODE = steps["stripe_dispatch"]["tool"]["code"]


def run(tool="", arguments=None, method="tools/call", handler=None):
    sent.clear()
    state["stripe"] = handler
    g = dict(method=method, tool=tool, arguments=arguments or {}, stripe_api_base="https://api.stripe.com",
             stripe_api_version="2024-06-20", google_project="p", stripe_secret_name="stripe-api-test")
    exec(CODE, g)
    return g["result"]


def form(req):
    return dict(urllib.parse.parse_qsl(req.data.decode()))


def hdr(req, name):
    return {k.lower(): v for k, v in req.header_items()}.get(name.lower())


PI = {"id": "pi_1", "object": "payment_intent", "status": "requires_payment_method", "amount": 12345,
      "currency": "usd", "capture_method": "manual", "client_secret": "pi_1_secret_zzz",
      "metadata": {"checkout_id": "co_1"}, "livemode": False}

# --- shape ---------------------------------------------------------------
check([s["step"] for s in doc["workflow"]] == ["start", "stripe_dispatch", "end"], "start -> stripe_dispatch -> end")
check(doc["workload"]["stripe_secret_name"] == "stripe-api-test", "workload references GSM stripe-api-test by name")
check("sk_test_" not in json.dumps(doc["workload"]) and "sk_live" not in open(PLAYBOOK).read(),
      "no key material in the playbook")

# --- tools/list ----------------------------------------------------------
res = run(method="tools/list")
names = [t["name"] for t in res["data"]["tools"]]
check(names == ["create_payment_intent", "retrieve_payment_intent", "capture_payment_intent",
                "cancel_payment_intent", "create_refund", "retrieve_event"], "tools/list has the six tools")
check(not sent, "tools/list sends nothing to Stripe")

# --- create: form encoding, idempotency, client_secret --------------------
def create_ok(req):
    return 200, PI


res = run("create_payment_intent", {"amount": 12345, "currency": "USD", "idempotency_key": "checkout:co_1:create",
                                    "metadata": {"checkout_id": "co_1", "kind": "flight"}, "description": "Muno test"},
          handler=create_ok)
req = sent[0]
f = form(req)
check(req.get_method() == "POST" and req.full_url == "https://api.stripe.com/v1/payment_intents", "create POSTs /v1/payment_intents")
check(f.get("metadata[checkout_id]") == "co_1" and f.get("metadata[kind]") == "flight", "nested metadata is form-encoded as metadata[k]")
check(f.get("automatic_payment_methods[enabled]") == "true", "automatic_payment_methods[enabled]=true")
check(f.get("capture_method") == "manual" and f.get("currency") == "usd" and f.get("amount") == "12345",
      "manual capture, lowercase currency, integer minor-unit amount")
check(hdr(req, "Idempotency-Key") == "checkout:co_1:create", "Idempotency-Key header sent")
check(hdr(req, "Stripe-Version") == "2024-06-20", "Stripe-Version header sent")
check(hdr(req, "Authorization") == "Bearer sk_test_abc123", "bearer is the GSM key")
check(res["data"]["payment_intent"]["client_secret"] == "pi_1_secret_zzz", "create returns client_secret")
check("sk_test_abc123" not in json.dumps(res), "key never appears in the result")

res = run("create_payment_intent", {"amount": 100, "currency": "usd"}, handler=create_ok)
check(res["isError"] and res["data"]["code"] == "validation_error" and not sent, "create without idempotency_key is refused, nothing sent")
res = run("create_payment_intent", {"amount": "12.5", "currency": "usd", "idempotency_key": "k"}, handler=create_ok)
check(res["isError"] and not sent, "non-integer amount refused")

# --- retrieve never returns client_secret -------------------------------
res = run("retrieve_payment_intent", {"payment_intent_id": "pi_1"}, handler=lambda r: (200, dict(PI, status="requires_capture")))
check(sent[0].get_method() == "GET" and sent[0].full_url.endswith("/v1/payment_intents/pi_1"), "retrieve GETs the PI")
check(res["data"]["payment_intent"]["status"] == "requires_capture", "retrieve reports status")
check("client_secret" not in json.dumps(res), "retrieve never includes client_secret")

# --- capture / cancel / refund -------------------------------------------
res = run("capture_payment_intent", {"payment_intent_id": "pi_1", "idempotency_key": "checkout:co_1:capture"},
          handler=lambda r: (200, dict(PI, status="succeeded")))
check(sent[0].full_url.endswith("/v1/payment_intents/pi_1/capture") and hdr(sent[0], "Idempotency-Key") == "checkout:co_1:capture",
      "capture POSTs /capture with its idempotency key")
check(res["data"]["payment_intent"]["status"] == "succeeded" and "client_secret" not in json.dumps(res), "capture ok, no client_secret")
res = run("capture_payment_intent", {"payment_intent_id": "pi_1"})
check(res["isError"] and not sent, "capture without idempotency_key refused")

res = run("cancel_payment_intent", {"payment_intent_id": "pi_1", "idempotency_key": "checkout:co_1:cancel",
                                    "cancellation_reason": "abandoned"},
          handler=lambda r: (200, dict(PI, status="canceled")))
check(sent[0].full_url.endswith("/pi_1/cancel") and form(sent[0]).get("cancellation_reason") == "abandoned", "cancel POSTs /cancel with reason")
check(res["data"]["payment_intent"]["status"] == "canceled", "cancel ok")

res = run("create_refund", {"payment_intent_id": "pi_1", "idempotency_key": "checkout:co_1:refund:1", "amount": 500,
                            "reason": "requested_by_customer"},
          handler=lambda r: (200, {"id": "re_1", "status": "succeeded", "amount": 500, "currency": "usd",
                                   "payment_intent": "pi_1", "livemode": False}))
f = form(sent[0])
check(sent[0].full_url.endswith("/v1/refunds") and f == {"payment_intent": "pi_1", "amount": "500", "reason": "requested_by_customer"},
      "refund POSTs /v1/refunds with payment_intent, amount, reason")
check(hdr(sent[0], "Idempotency-Key") == "checkout:co_1:refund:1" and res["data"]["refund"]["id"] == "re_1", "refund keyed and ok")

# --- retrieve_event strips client_secret from the embedded object --------
res = run("retrieve_event", {"event_id": "evt_1"},
          handler=lambda r: (200, {"id": "evt_1", "type": "payment_intent.amount_capturable_updated", "livemode": False,
                                   "data": {"object": dict(PI, status="requires_capture")}}))
check(sent[0].full_url.endswith("/v1/events/evt_1") and res["data"]["event"]["object"]["status"] == "requires_capture",
      "retrieve_event returns the event object")
check("client_secret" not in json.dumps(res), "retrieve_event strips client_secret")

# --- Stripe error mapping -------------------------------------------------
res = run("capture_payment_intent", {"payment_intent_id": "pi_1", "idempotency_key": "k"},
          handler=lambda r: (402, {"error": {"type": "card_error", "code": "card_declined", "decline_code": "insufficient_funds",
                                             "message": "Your card has insufficient funds."}}))
d = res["data"]
check(res["isError"] and d["code"] == "card_declined" and d["stripe_decline_code"] == "insufficient_funds"
      and d["stripe_type"] == "card_error" and d["status_code"] == 402, "card_error maps code/decline_code/type")
res = run("create_payment_intent", {"amount": 1, "currency": "usd", "idempotency_key": "k"},
          handler=lambda r: (400, {"error": {"type": "idempotency_error", "message": "Keys for idempotent requests can only be used with the same parameters"}}))
check(res["isError"] and res["data"]["code"] == "idempotency_error", "idempotency_error mapped")

# --- livemode refusal ----------------------------------------------------
res = run("retrieve_payment_intent", {"payment_intent_id": "pi_1"}, handler=lambda r: (200, dict(PI, livemode=True)))
check(res["isError"] and res["data"]["code"] == "livemode_refused", "livemode:true response refused")
check("pi_1_secret_zzz" not in json.dumps(res) and "requires_payment_method" not in json.dumps(res), "refused body is not returned")

# --- live-key refusal sends nothing ---------------------------------------
for live in ("sk_live_zzz", "rk_live_zzz", "pk_test_zzz", "garbage"):
    state["secret"] = live
    res = run("create_payment_intent", {"amount": 1, "currency": "usd", "idempotency_key": "k"}, handler=create_ok)
    check(res["isError"] and res["data"]["code"] == "live_key_refused" and not sent, f"{live[:8]}… refused before any Stripe request")
    check(live not in json.dumps(res), f"{live[:8]}… not echoed")

# --- secret payload shapes -----------------------------------------------
for label, raw in (("bare", "rk_test_r1"), ("{token}", json.dumps({"token": "rk_test_r1"})),
                   ("{data:{token}}", json.dumps({"name": "stripe", "type": "secret_manager", "data": {"token": "rk_test_r1"}}))):
    state["secret"] = raw
    run("retrieve_payment_intent", {"payment_intent_id": "pi_1"}, handler=lambda r: (200, PI))
    check(len(sent) == 1 and hdr(sent[0], "Authorization") == "Bearer rk_test_r1", f"secret payload {label} resolves the key")
state["secret"] = json.dumps({"other": "x"})
res = run("retrieve_payment_intent", {"payment_intent_id": "pi_1"})
check(res["data"]["code"] == "credential_unavailable" and not sent, "secret JSON without a token is credential_unavailable")
state["secret"] = "sk_test_abc123"

# --- metadata server missing (kind / off-cluster) ------------------------
state["metadata"] = "down"
res = run("retrieve_payment_intent", {"payment_intent_id": "pi_1"})
check(res["isError"] and res["data"]["code"] == "credential_unavailable" and "metadata server unreachable" in res["data"]["error"]
      and not sent, "no metadata server: clear credential_unavailable, nothing sent")
state["metadata"] = "ok"

# --- unknown tool / method ------------------------------------------------
check(run("charge_card")["data"]["code"] == "validation_error", "unknown tool refused")
check(run(method="resources/list")["isError"], "unsupported method refused")

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
