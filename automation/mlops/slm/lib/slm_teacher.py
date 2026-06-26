"""Generic SLM teacher labeling engine — the labeling *ceiling*.

Domain-agnostic.  Given a turn (the same dict the deterministic oracle reads),
this calls a hosted teacher LLM twice — once per role — using the EXACT
production system prompts + output contracts the org's ``slm.config.yaml``
declares, and returns ``{extract, render, usage}`` in the same shape
``oracle.run_turn`` returns.  That symmetry lets ``slm_dataset_build`` store an
oracle (floor) label and a teacher (ceiling) label side by side per example,
and lets ``slm_eval`` measure the floor↔ceiling gap per field.

Why this exists: the deterministic oracle is a zero-cost *floor*.  The teacher
(OpenAI gpt-4o / gpt-4o-mini for the travel instance) is the *ceiling* — the
quality a fine-tuned SLM is trying to reach.  The gap between them, per field,
is the signal that ranks candidate model sizes (RFC §10 decision 1).

Transport: Python stdlib ``urllib`` only — no ``openai``/``requests`` dep, so
the engine runs anywhere the runtime's ``python3`` runs.  The API key arrives
through the environment (``OPENAI_API_KEY`` by default; the production
``dataset_build`` playbook injects it from the keychain alias named in the
config ``teachers[].credential`` via the step ``auth:`` block — the key is
never inlined, logged, or written to any artifact).

Usage (library): see ``slm_dataset_build`` when a teacher block is enabled.
"""

import json
import os
import time
import urllib.error
import urllib.request

# ── teacher price table (USD per 1M tokens) ─────────────────────────────────
# Estimate only, for the token-cost line in the manifest/report.  Override per
# model via the config ``teachers[].pricing`` block when prices move.  Public
# OpenAI list pricing at the time this Phase-1 run shipped (2026-06).
_DEFAULT_PRICING = {
    "gpt-4o": {"input_per_1m": 2.50, "output_per_1m": 10.00},
    "gpt-4o-mini": {"input_per_1m": 0.15, "output_per_1m": 0.60},
    "gpt-4o-2024-08-06": {"input_per_1m": 2.50, "output_per_1m": 10.00},
}

_OPENAI_CHAT_URL = "https://api.openai.com/v1/chat/completions"


class TeacherError(RuntimeError):
    pass


class Teacher:
    """One configured teacher: the two role models + their prod prompts.

    Construct from the config via :func:`from_config`.  ``label_turn`` produces
    both labels for one turn and accumulates token usage on the instance so the
    caller can read ``teacher.usage`` after the whole corpus is labeled.
    """

    def __init__(
        self,
        api_key,
        extract_model,
        render_model,
        extract_system_prompt,
        render_system_prompt,
        vocab=None,
        pricing=None,
        endpoint=None,
        max_retries=4,
        timeout=90,
        request_sleep=0.0,
    ):
        if not api_key:
            raise TeacherError(
                "teacher api key not present in the environment — set the env var "
                "named by the config (default OPENAI_API_KEY); in production the "
                "dataset_build step injects it from the keychain via auth:."
            )
        self._api_key = api_key
        self.extract_model = extract_model
        self.render_model = render_model
        self.extract_system_prompt = extract_system_prompt
        self.render_system_prompt = render_system_prompt
        self.vocab = vocab or {}
        self.pricing = dict(_DEFAULT_PRICING)
        if pricing:
            self.pricing.update(pricing)
        self.endpoint = endpoint or _OPENAI_CHAT_URL
        self.max_retries = max_retries
        self.timeout = timeout
        self.request_sleep = request_sleep
        # cumulative accounting across every call this instance makes
        self.usage = {
            "calls": 0,
            "errors": 0,
            "by_model": {},  # model -> {calls, prompt_tokens, completion_tokens, total_tokens, cost_usd}
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "total_tokens": 0,
            "cost_usd": 0.0,
        }

    # ── construction from the org config ────────────────────────────────────
    @classmethod
    def from_config(cls, cfg, cfg_dir, common, teacher_id=None):
        """Build a Teacher from the loaded config + the ``slm_common`` module.

        Returns ``None`` (with a reason printed) when no enabled teacher block
        is present, so callers can fall back to oracle-only cleanly.
        """
        dom = cfg["slm_domain"]
        teachers = dom.get("teachers", []) or []
        chosen = None
        for t in teachers:
            if teacher_id and t.get("id") != teacher_id:
                continue
            if str(t.get("status", "disabled")).lower() in ("enabled", "active", "on"):
                chosen = t
                break
        if chosen is None:
            return None, "no enabled teacher block (teachers[].status != enabled)"

        models = chosen.get("models", {})
        extract_model = models.get("extract")
        render_model = models.get("render")
        if not extract_model or not render_model:
            raise TeacherError(
                "teacher block %r missing models.extract / models.render" % chosen.get("id")
            )

        # credential alias -> env var name.  The config value is a keychain
        # template like "{{ openai_token }}"; the production playbook resolves it
        # via auth: and exports the secret as the env var named in
        # teachers[].api_key_env (default OPENAI_API_KEY).  We never read the
        # secret from the config — only from the environment.
        api_key_env = chosen.get("api_key_env", "OPENAI_API_KEY")
        api_key = os.environ.get(api_key_env, "")

        roles = dom.get("roles", [])

        def _role(rid):
            for r in roles:
                if r.get("id") == rid:
                    return r
            return {}

        extract_prompt = cls._load_prompt(_role("extract"), cfg_dir, common)
        render_prompt = cls._load_prompt(_role("render"), cfg_dir, common)

        return (
            cls(
                api_key=api_key,
                extract_model=extract_model,
                render_model=render_model,
                extract_system_prompt=extract_prompt,
                render_system_prompt=render_prompt,
                vocab=dom.get("vocab", {}),
                pricing=chosen.get("pricing"),
                endpoint=chosen.get("endpoint"),
                request_sleep=float(chosen.get("request_sleep_s", 0.0)),
            ),
            "teacher %r enabled (extract=%s, render=%s)"
            % (chosen.get("id"), extract_model, render_model),
        )

    @staticmethod
    def _load_prompt(role, cfg_dir, common):
        p = common.resolve(cfg_dir, role.get("system_prompt"))
        if p and os.path.exists(p):
            with open(p, "r") as fh:
                return fh.read()
        return ""

    # ── HTTP (stdlib only) ──────────────────────────────────────────────────
    def _chat_json(self, model, system_prompt, user_payload):
        """One JSON-mode chat completion. Returns (parsed_obj, usage_dict)."""
        body = json.dumps(
            {
                "model": model,
                "temperature": 0,
                "response_format": {"type": "json_object"},
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_payload},
                ],
            }
        ).encode("utf-8")

        last_err = None
        for attempt in range(self.max_retries):
            req = urllib.request.Request(self.endpoint, data=body, method="POST")
            req.add_header("Content-Type", "application/json")
            req.add_header("Authorization", "Bearer %s" % self._api_key)
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))
                content = payload["choices"][0]["message"]["content"]
                usage = payload.get("usage", {}) or {}
                obj = json.loads(content)
                return obj, usage
            except urllib.error.HTTPError as exc:
                code = exc.code
                # retry on rate-limit / transient server errors
                if code in (429, 500, 502, 503, 504) and attempt < self.max_retries - 1:
                    last_err = "HTTP %d" % code
                    time.sleep(min(2 ** attempt, 20))
                    continue
                detail = ""
                try:
                    detail = exc.read().decode("utf-8")[:200]
                except Exception:
                    pass
                raise TeacherError("teacher HTTP %d: %s" % (code, detail))
            except (urllib.error.URLError, TimeoutError) as exc:
                last_err = str(exc)
                if attempt < self.max_retries - 1:
                    time.sleep(min(2 ** attempt, 20))
                    continue
                raise TeacherError("teacher transport error: %s" % last_err)
            except (KeyError, ValueError) as exc:
                # malformed JSON from the model — one retry then give up
                last_err = "bad response: %s" % exc
                if attempt < self.max_retries - 1:
                    time.sleep(1)
                    continue
                raise TeacherError(last_err)
        raise TeacherError("teacher exhausted retries: %s" % last_err)

    def _account(self, model, usage):
        pt = int(usage.get("prompt_tokens", 0) or 0)
        ct = int(usage.get("completion_tokens", 0) or 0)
        tt = int(usage.get("total_tokens", pt + ct) or (pt + ct))
        price = self.pricing.get(model, {})
        cost = (
            pt * price.get("input_per_1m", 0.0) / 1_000_000.0
            + ct * price.get("output_per_1m", 0.0) / 1_000_000.0
        )
        bm = self.usage["by_model"].setdefault(
            model,
            {"calls": 0, "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0, "cost_usd": 0.0},
        )
        bm["calls"] += 1
        bm["prompt_tokens"] += pt
        bm["completion_tokens"] += ct
        bm["total_tokens"] += tt
        bm["cost_usd"] = round(bm["cost_usd"] + cost, 6)
        self.usage["calls"] += 1
        self.usage["prompt_tokens"] += pt
        self.usage["completion_tokens"] += ct
        self.usage["total_tokens"] += tt
        self.usage["cost_usd"] = round(self.usage["cost_usd"] + cost, 6)

    # ── role passes ─────────────────────────────────────────────────────────
    def extract(self, turn):
        user = json.dumps(
            {
                "new_event": {
                    "event_type": turn.get("event_type", "user_message"),
                    "event_payload": turn.get("event_payload", {}),
                },
                "slot_state": turn.get("slot_state", {}),
                "thread_context": turn.get("thread_context", []),
                "runtime": {
                    "duffel_env": turn.get("duffel_env", "test"),
                    "amadeus_env": turn.get("amadeus_env", "test"),
                },
                "instruction": (
                    "Return ONLY the JSON object for the extraction output "
                    "contract: {slot_updates, tool_requests, render_intent}. "
                    "tool ids and render_intent.kind must come from the declared "
                    "vocabulary."
                ),
                "vocabulary": self.vocab,
            },
            sort_keys=True,
        )
        obj, usage = self._chat_json(self.extract_model, self.extract_system_prompt, user)
        self._account(self.extract_model, usage)
        # normalize to the contract keys (defensive: drop unexpected top keys)
        return {
            "slot_updates": obj.get("slot_updates", {}) or {},
            "tool_requests": obj.get("tool_requests", []) or [],
            "render_intent": obj.get("render_intent", {"kind": "summarize"}) or {"kind": "summarize"},
        }

    def render(self, turn, extraction, tool_summary=None):
        slot = dict(turn.get("slot_state") or {})
        slot.update(extraction.get("slot_updates") or {})
        user = json.dumps(
            {
                "slot_state": slot,
                "extraction": extraction,
                "tool_summary": tool_summary or {},
                "render_intent": extraction.get("render_intent", {}),
                "instruction": (
                    "Return ONLY the JSON object for the chat-render output "
                    "contract: {bot_message, widgets}. Every widget must be a "
                    "valid envelope {schema_version:1, widget_type, variant, "
                    "payload}. Keep widget-type selection deterministic for the "
                    "slot state + render_intent."
                ),
            },
            sort_keys=True,
        )
        obj, usage = self._chat_json(self.render_model, self.render_system_prompt, user)
        self._account(self.render_model, usage)
        return {
            "bot_message": obj.get("bot_message", "") or "",
            "widgets": obj.get("widgets", []) or [],
        }

    def label_turn(self, turn, tool_summary_fn=None):
        """Produce both teacher labels for one turn.

        ``tool_summary_fn`` (optional): callable(extraction, slot_state) ->
        normalized tool summary, used so the render pass sees the SAME
        deterministic fixture the floor sees for its own extraction (keeps the
        floor↔ceiling render comparison apples-to-apples in Phase A, where no
        live MCP call is made).  When absent, render gets an empty summary.
        """
        ex = self.extract(turn)
        slot = dict(turn.get("slot_state") or {})
        slot.update(ex.get("slot_updates") or {})
        ts = tool_summary_fn(ex, slot) if tool_summary_fn else {}
        rd = self.render(turn, ex, ts)
        if self.request_sleep:
            time.sleep(self.request_sleep)
        return {"extract": ex, "render": rd, "tool_summary": ts}
