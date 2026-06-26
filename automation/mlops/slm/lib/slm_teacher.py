"""Generic SLM teacher labeling engine — the labeling *ceiling*.

Domain-agnostic.  Given a turn (the same dict the deterministic oracle reads),
this calls a hosted teacher LLM twice — once per role — using the EXACT
production system prompts + output contracts the org's ``slm.config.yaml``
declares, and returns ``{extract, render, usage}`` in the same shape
``oracle.run_turn`` returns.  That symmetry lets ``slm_dataset_build`` store an
oracle (floor) label and a teacher (ceiling) label side by side per example,
and lets ``slm_eval`` measure the floor↔ceiling gap per field.

Why this exists: the deterministic oracle is a zero-cost *floor*.  The teacher
is the *ceiling* — the quality a fine-tuned SLM is trying to reach.  The gap
between them, per field, is the signal that ranks candidate model sizes
(RFC §10 decision 1).

Pluggable teacher providers (RFC decision #6 — the teacher is a swappable
ceiling source):

  * ``vertex_gemini`` — Vertex AI ``generateContent`` (default for the travel
    instance).  Mints a Workload-Identity OAuth token in-python from the GKE
    metadata server with stdlib ``urllib`` — no ``google-auth`` library, no
    API key, no Secret Manager.  The worker pod's bound service account is the
    only credential; off-cluster (kind) the mint fails with a clear message and
    the turn is recorded as a teacher error (the floor label still ships).
    Primary ``gemini-2.5-pro`` with a ``gemini-2.5-flash`` fallback on a
    primary-model failure.
  * ``openai`` / ``openai_compatible`` — OpenAI Chat Completions wire format.
    ``openai_compatible`` + an ``endpoint`` lets a future self-hosted teacher
    (Gemma / Qwen behind an OpenAI-compatible server) drop in unchanged.  The
    API key arrives through the environment (``OPENAI_API_KEY`` by default);
    the generic ``dataset_build`` playbook no longer injects an OpenAI key, so
    a domain that wants the OpenAI ceiling supplies it in its own overlay.

Transport: Python stdlib ``urllib`` only — no ``openai`` / ``requests`` /
``google-auth`` dep, so the engine runs anywhere the runtime's ``python3``
runs.

Usage (library): see ``slm_dataset_build`` when a teacher block is enabled.
"""

import json
import os
import time
import urllib.error
import urllib.request

try:
    import slm_schema as S  # sibling module (draft-07 -> Vertex responseSchema)
except Exception:  # pragma: no cover - allows import in contexts without the sibling
    S = None

# ── teacher price table (USD per 1M tokens) ─────────────────────────────────
# Estimate only, for the token-cost line in the manifest/report.  Override per
# model via the config ``teachers[].pricing`` block when prices move.
_DEFAULT_PRICING = {
    # OpenAI list pricing, 2026-06.
    "gpt-4o": {"input_per_1m": 2.50, "output_per_1m": 10.00},
    "gpt-4o-mini": {"input_per_1m": 0.15, "output_per_1m": 0.60},
    "gpt-4o-2024-08-06": {"input_per_1m": 2.50, "output_per_1m": 10.00},
    # Vertex Gemini list pricing, 2026-06 (≤200k-token context tier).
    "gemini-2.5-pro": {"input_per_1m": 1.25, "output_per_1m": 10.00},
    "gemini-2.5-flash": {"input_per_1m": 0.30, "output_per_1m": 2.50},
}

_OPENAI_CHAT_URL = "https://api.openai.com/v1/chat/completions"

# GKE metadata server token endpoint — exactly what google.auth.default() reads
# under the hood on GKE, so a direct urllib GET is the library-free equivalent
# (copied from automation/agents/mcp/google-places.yaml, noetl/ai-meta#137).
_METADATA_TOKEN_URL = (
    "http://metadata.google.internal/computeMetadata/v1/"
    "instance/service-accounts/default/token"
)


class TeacherError(RuntimeError):
    pass


# ── provider seam ───────────────────────────────────────────────────────────
# A provider turns (model, system_prompt, user_payload) into (parsed_json,
# usage).  ``usage`` is normalized to {prompt_tokens, completion_tokens,
# total_tokens, model} so the Teacher accounts cost the same way regardless of
# which backend served the call.


def _retryable_http(code):
    return code in (429, 500, 502, 503, 504)


class OpenAIProvider:
    """OpenAI Chat Completions JSON-mode transport.

    Also serves ``openai_compatible`` self-hosted teachers (same wire format)
    by passing a different ``endpoint``.
    """

    def __init__(self, api_key, endpoint=None, max_retries=4, timeout=90):
        if not api_key:
            raise TeacherError(
                "teacher api key not present in the environment — set the env var "
                "named by the config (default OPENAI_API_KEY).  The generic "
                "dataset_build playbook no longer injects an OpenAI key; a domain "
                "that selects the openai provider supplies it in its own overlay."
            )
        self._api_key = api_key
        self.endpoint = endpoint or _OPENAI_CHAT_URL
        self.max_retries = max_retries
        self.timeout = timeout

    def chat_json(self, model, system_prompt, user_payload, response_schema=None):
        # OpenAI structured outputs: a response_schema (Vertex-subset dict, which
        # is also a valid JSON Schema) upgrades json_object to a strict
        # json_schema response_format.  Pluggable: None keeps plain JSON mode.
        if response_schema is not None:
            response_format = {
                "type": "json_schema",
                "json_schema": {
                    "name": "slm_contract",
                    "strict": False,
                    "schema": response_schema,
                },
            }
        else:
            response_format = {"type": "json_object"}
        body = json.dumps(
            {
                "model": model,
                "temperature": 0,
                "response_format": response_format,
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
                raw_usage = payload.get("usage", {}) or {}
                obj = json.loads(content)
                return obj, _normalize_openai_usage(raw_usage, model)
            except urllib.error.HTTPError as exc:
                code = exc.code
                if _retryable_http(code) and attempt < self.max_retries - 1:
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
                last_err = "bad response: %s" % exc
                if attempt < self.max_retries - 1:
                    time.sleep(1)
                    continue
                raise TeacherError(last_err)
        raise TeacherError("teacher exhausted retries: %s" % last_err)


class VertexGeminiProvider:
    """Vertex AI ``generateContent`` JSON-mode transport with WI-metadata auth.

    No ``google-auth`` library, no API key, no Secret Manager: the OAuth token
    is minted from the GKE metadata server using the worker pod's Workload
    Identity.  Primary ``model`` with a ``fallback_model`` retry on a
    primary-model failure (e.g. transient resource exhaustion).
    """

    def __init__(
        self,
        project,
        region="us-central1",
        fallback_model="gemini-2.5-flash",
        token_fn=None,
        max_retries=4,
        timeout=90,
        metadata_timeout=10,
    ):
        if not project:
            raise TeacherError("vertex_gemini provider requires a GCP project")
        self.project = project
        self.region = region
        self.fallback_model = fallback_model
        # token_fn overridable for offline tests; defaults to the metadata mint
        self._token_fn = token_fn or self._mint_token
        self.max_retries = max_retries
        self.timeout = timeout
        self.metadata_timeout = metadata_timeout

    # ── Workload-Identity token mint (stdlib urllib, no google-auth) ─────────
    def _mint_token(self):
        req = urllib.request.Request(
            _METADATA_TOKEN_URL, headers={"Metadata-Flavor": "Google"}, method="GET"
        )
        try:
            with urllib.request.urlopen(req, timeout=self.metadata_timeout) as resp:
                payload = json.loads(resp.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")[:300]
            raise TeacherError(
                "vertex WI token mint failed HTTP %d: the worker pod's Workload "
                "Identity is not bound to a service account with Vertex AI access "
                "(%s)" % (exc.code, body)
            )
        except (urllib.error.URLError, TimeoutError) as exc:
            raise TeacherError(
                "vertex WI token mint: metadata server unreachable (%s) — expected "
                "off-cluster (e.g. kind); a real ceiling run needs a GKE pod with "
                "Workload Identity bound to a Vertex-enabled service account"
                % getattr(exc, "reason", exc)
            )
        token = payload.get("access_token") if isinstance(payload, dict) else None
        if not token:
            raise TeacherError("vertex WI token mint: metadata endpoint returned no access_token")
        return token

    def _endpoint(self, model):
        return (
            "https://%s-aiplatform.googleapis.com/v1/projects/%s/locations/%s/"
            "publishers/google/models/%s:generateContent"
            % (self.region, self.project, self.region, model)
        )

    def _generate(self, token, model, system_prompt, user_payload, response_schema=None):
        gen_config = {
            "temperature": 0,
            "responseMimeType": "application/json",
        }
        # Schema-constrained decoding (noetl/ai-meta#140 Phase 1): when a
        # Vertex-subset responseSchema is supplied, the model's output is
        # JSON-schema-valid by construction — this is the fix the ceiling-run
        # finding implies (constrain the decoder, don't grow the model).
        if response_schema is not None:
            gen_config["responseSchema"] = response_schema
        body = json.dumps(
            {
                "systemInstruction": {"parts": [{"text": system_prompt}]},
                "contents": [{"role": "user", "parts": [{"text": user_payload}]}],
                "generationConfig": gen_config,
            }
        ).encode("utf-8")
        url = self._endpoint(model)

        last_err = None
        for attempt in range(self.max_retries):
            req = urllib.request.Request(url, data=body, method="POST")
            req.add_header("Content-Type", "application/json")
            req.add_header("Authorization", "Bearer %s" % token)
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))
                candidates = payload.get("candidates") or []
                if not candidates:
                    reason = payload.get("promptFeedback", {}).get("blockReason")
                    raise TeacherError(
                        "vertex %s returned no candidates (blockReason=%s)" % (model, reason)
                    )
                parts = candidates[0].get("content", {}).get("parts", []) or []
                text = "".join(p.get("text", "") for p in parts)
                obj = json.loads(text)
                usage = _normalize_vertex_usage(payload.get("usageMetadata") or {}, model)
                return obj, usage
            except urllib.error.HTTPError as exc:
                code = exc.code
                if _retryable_http(code) and attempt < self.max_retries - 1:
                    last_err = "HTTP %d" % code
                    time.sleep(min(2 ** attempt, 20))
                    continue
                detail = ""
                try:
                    detail = exc.read().decode("utf-8")[:200]
                except Exception:
                    pass
                raise TeacherError("vertex %s HTTP %d: %s" % (model, code, detail))
            except (urllib.error.URLError, TimeoutError) as exc:
                last_err = str(exc)
                if attempt < self.max_retries - 1:
                    time.sleep(min(2 ** attempt, 20))
                    continue
                raise TeacherError("vertex %s transport error: %s" % (model, last_err))
            except (KeyError, ValueError) as exc:
                last_err = "bad response: %s" % exc
                if attempt < self.max_retries - 1:
                    time.sleep(1)
                    continue
                raise TeacherError("vertex %s %s" % (model, last_err))
        raise TeacherError("vertex %s exhausted retries: %s" % (model, last_err))

    def chat_json(self, model, system_prompt, user_payload, response_schema=None):
        # Mint the token ONCE per call so a Workload-Identity block surfaces its
        # clean message directly rather than being masked by the fallback path.
        token = self._token_fn()
        try:
            return self._generate(token, model, system_prompt, user_payload, response_schema)
        except TeacherError as primary_err:
            if self.fallback_model and self.fallback_model != model:
                try:
                    return self._generate(
                        token, self.fallback_model, system_prompt, user_payload, response_schema
                    )
                except TeacherError as fb_err:
                    raise TeacherError(
                        "vertex primary (%s) and fallback (%s) both failed: %s | %s"
                        % (model, self.fallback_model, primary_err, fb_err)
                    )
            raise


def _normalize_openai_usage(raw, model):
    pt = int(raw.get("prompt_tokens", 0) or 0)
    ct = int(raw.get("completion_tokens", 0) or 0)
    tt = int(raw.get("total_tokens", pt + ct) or (pt + ct))
    return {"prompt_tokens": pt, "completion_tokens": ct, "total_tokens": tt, "model": model}


def _normalize_vertex_usage(meta, model):
    pt = int(meta.get("promptTokenCount", 0) or 0)
    ct = int(meta.get("candidatesTokenCount", 0) or 0)
    tt = int(meta.get("totalTokenCount", pt + ct) or (pt + ct))
    return {"prompt_tokens": pt, "completion_tokens": ct, "total_tokens": tt, "model": model}


# ── teacher (role logic over a provider) ────────────────────────────────────
class Teacher:
    """One configured teacher: the two role models + their prod prompts.

    Construct from the config via :func:`from_config`.  ``label_turn`` produces
    both labels for one turn and accumulates token usage on the instance so the
    caller can read ``teacher.usage`` after the whole corpus is labeled.
    """

    def __init__(
        self,
        provider,
        extract_model,
        render_model,
        extract_system_prompt,
        render_system_prompt,
        vocab=None,
        pricing=None,
        request_sleep=0.0,
        constrained=True,
        extract_schema_path=None,
        widget_dir=None,
    ):
        self._provider = provider
        self.extract_model = extract_model
        self.render_model = render_model
        self.extract_system_prompt = extract_system_prompt
        self.render_system_prompt = render_system_prompt
        self.vocab = vocab or {}
        self.pricing = dict(_DEFAULT_PRICING)
        if pricing:
            self.pricing.update(pricing)
        self.request_sleep = request_sleep
        # ── schema-constrained decoding (noetl/ai-meta#140 Phase 1) ──
        # When on (default) and the converter + contract schemas are available,
        # each pass is given a Vertex-subset responseSchema so the output is
        # schema-valid by construction.  Falls back to unconstrained JSON mode
        # (the old behaviour) when the converter is missing or a schema can't be
        # converted, so the engine still runs and the repair pass cleans up.
        self.constrained = bool(constrained) and S is not None
        self.extract_schema_path = extract_schema_path
        self.widget_dir = widget_dir
        self._extract_response_schema = None
        if self.constrained and extract_schema_path:
            try:
                self._extract_response_schema = S.extract_response_schema(extract_schema_path)
            except Exception as exc:  # converter failure -> envelope-free extract
                self._extract_response_schema = None
                self.constrained_warnings = getattr(self, "constrained_warnings", [])
                self.constrained_warnings.append("extract schema convert failed: %s" % exc)
        # cache of per-turn render schemas keyed by the sorted widget-type tuple
        self._render_schema_cache = {}
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

        Returns ``(None, reason)`` (with a reason string) when no enabled
        teacher block is present, so callers can fall back to oracle-only
        cleanly.
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

        provider = cls._build_provider(chosen, models)

        roles = dom.get("roles", [])

        def _role(rid):
            for r in roles:
                if r.get("id") == rid:
                    return r
            return {}

        extract_prompt = cls._load_prompt(_role("extract"), cfg_dir, common)
        render_prompt = cls._load_prompt(_role("render"), cfg_dir, common)

        # contract schema paths for constrained decoding (extract output schema
        # + the widget-contract dir for per-type render payloads)
        extract_schema_path = common.resolve(cfg_dir, _role("extract").get("output_schema"))
        widget_dir = common.resolve(cfg_dir, _role("render").get("widget_schema_dir"))
        # constrained decoding defaults ON; a teacher block may opt out with
        # constrained_decoding: false (e.g. to measure the unconstrained ceiling).
        constrained = str(chosen.get("constrained_decoding", "true")).lower() not in (
            "false", "0", "off", "no"
        )

        provider_kind = str(chosen.get("provider", "openai")).lower()
        return (
            cls(
                provider=provider,
                extract_model=extract_model,
                render_model=render_model,
                extract_system_prompt=extract_prompt,
                render_system_prompt=render_prompt,
                vocab=dom.get("vocab", {}),
                pricing=chosen.get("pricing"),
                request_sleep=float(chosen.get("request_sleep_s", 0.0)),
                constrained=constrained,
                extract_schema_path=extract_schema_path,
                widget_dir=widget_dir,
            ),
            "teacher %r enabled (provider=%s, extract=%s, render=%s, constrained=%s)"
            % (chosen.get("id"), provider_kind, extract_model, render_model, constrained),
        )

    @staticmethod
    def _build_provider(chosen, models):
        """Select the transport from ``teachers[].provider`` (default openai)."""
        provider_kind = str(chosen.get("provider", "openai")).lower()
        if provider_kind in ("openai", "openai_compatible"):
            api_key_env = chosen.get("api_key_env", "OPENAI_API_KEY")
            api_key = os.environ.get(api_key_env, "")
            return OpenAIProvider(api_key=api_key, endpoint=chosen.get("endpoint"))
        if provider_kind in ("vertex_gemini", "vertex", "gemini"):
            vcfg = chosen.get("vertex", {}) or {}
            project = vcfg.get("project") or chosen.get("project")
            if not project:
                raise TeacherError(
                    "vertex_gemini teacher %r missing vertex.project" % chosen.get("id")
                )
            fallback = models.get("fallback") or vcfg.get("fallback_model", "gemini-2.5-flash")
            return VertexGeminiProvider(
                project=project,
                region=vcfg.get("region", "us-central1"),
                fallback_model=fallback,
            )
        raise TeacherError(
            "unknown teacher provider %r (expected openai | openai_compatible | "
            "vertex_gemini)" % provider_kind
        )

    @staticmethod
    def _load_prompt(role, cfg_dir, common):
        p = common.resolve(cfg_dir, role.get("system_prompt"))
        if p and os.path.exists(p):
            with open(p, "r") as fh:
                return fh.read()
        return ""

    def _account(self, model, usage):
        # account under the model that actually served the call (provider may
        # have fallen back), normalized usage carries it in usage["model"]
        served = usage.get("model", model)
        pt = int(usage.get("prompt_tokens", 0) or 0)
        ct = int(usage.get("completion_tokens", 0) or 0)
        tt = int(usage.get("total_tokens", pt + ct) or (pt + ct))
        price = self.pricing.get(served, {})
        cost = (
            pt * price.get("input_per_1m", 0.0) / 1_000_000.0
            + ct * price.get("output_per_1m", 0.0) / 1_000_000.0
        )
        bm = self.usage["by_model"].setdefault(
            served,
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
        schema = self._extract_response_schema if self.constrained else None
        obj, usage = self._provider.chat_json(
            self.extract_model, self.extract_system_prompt, user, response_schema=schema
        )
        self._account(self.extract_model, usage)
        # normalize to the contract keys (defensive: drop unexpected top keys),
        # and repair tool-request shape drift — the first unconstrained ceiling
        # run emitted `tool_id` / `tool_name` / `parameters` instead of the
        # contract's `tool` / `arguments`, which both failed extract validation
        # and crashed the oracle tool-summary with KeyError (noetl/ai-meta#140).
        return {
            "slot_updates": obj.get("slot_updates", {}) or {},
            "tool_requests": _normalize_tool_requests(obj.get("tool_requests", []) or []),
            "render_intent": obj.get("render_intent", {"kind": "summarize"}) or {"kind": "summarize"},
        }

    def _render_schema_for(self, allowed_widget_types):
        """Per-turn render responseSchema pinned to the authoritative oracle's
        widget types (cached by the sorted type tuple).  Returns None when
        constrained decoding is off or the per-type payload schemas can't be
        converted (the repair pass then cleans up)."""
        if not (self.constrained and self.widget_dir and allowed_widget_types):
            return None
        key = tuple(sorted(set(allowed_widget_types)))
        if key in self._render_schema_cache:
            return self._render_schema_cache[key]
        try:
            schema = S.render_response_schema(self.widget_dir, list(allowed_widget_types))
        except Exception as exc:
            schema = None
            self.constrained_warnings = getattr(self, "constrained_warnings", [])
            self.constrained_warnings.append(
                "render schema convert failed for %s: %s" % (list(key), exc)
            )
        self._render_schema_cache[key] = schema
        return schema

    def render(self, turn, extraction, tool_summary=None, allowed_widget_types=None):
        slot = dict(turn.get("slot_state") or {})
        slot.update(extraction.get("slot_updates") or {})
        user = json.dumps(
            {
                "slot_state": slot,
                "extraction": extraction,
                "tool_summary": tool_summary or {},
                "render_intent": extraction.get("render_intent", {}),
                "allowed_widget_types": list(allowed_widget_types or []),
                "instruction": (
                    "Return ONLY the JSON object for the chat-render output "
                    "contract: {bot_message, widgets}. Every widget must be a "
                    "valid envelope {schema_version:1, widget_type, variant, "
                    "payload}, and every required payload field for the widget "
                    "type must be present. Use only the widget types in "
                    "allowed_widget_types, in that order, one widget each. Keep "
                    "widget-type selection deterministic for the slot state + "
                    "render_intent."
                ),
            },
            sort_keys=True,
        )
        schema = self._render_schema_for(allowed_widget_types)
        obj, usage = self._provider.chat_json(
            self.render_model, self.render_system_prompt, user, response_schema=schema
        )
        self._account(self.render_model, usage)
        return {
            "bot_message": obj.get("bot_message", "") or "",
            "widgets": obj.get("widgets", []) or [],
        }

    def label_turn(self, turn, tool_summary_fn=None, oracle_render=None):
        """Produce both teacher labels for one turn.

        ``tool_summary_fn`` (optional): callable(extraction, slot_state) ->
        normalized tool summary, used so the render pass sees the SAME
        deterministic fixture the floor sees for its own extraction (keeps the
        floor↔ceiling render comparison apples-to-apples in Phase A, where no
        live MCP call is made).  When absent, render gets an empty summary.

        ``oracle_render`` (optional): the authoritative oracle's render for this
        turn.  Its widget types pin the per-turn render responseSchema so the
        teacher fills the *required payload shape* for exactly the contract's
        widget types — the intent is authoritative, the teacher supplies the
        copy.  When absent, render is constrained only at the envelope level.
        """
        ex = self.extract(turn)
        slot = dict(turn.get("slot_state") or {})
        slot.update(ex.get("slot_updates") or {})
        ts = tool_summary_fn(ex, slot) if tool_summary_fn else {}
        allowed = [
            w.get("widget_type")
            for w in (oracle_render or {}).get("widgets", [])
            if isinstance(w, dict) and w.get("widget_type")
        ]
        rd = self.render(turn, ex, ts, allowed_widget_types=allowed)
        if self.request_sleep:
            time.sleep(self.request_sleep)
        return {"extract": ex, "render": rd, "tool_summary": ts}


def _normalize_tool_requests(reqs):
    """Coerce teacher tool-request items onto the contract shape.

    Maps the common drift keys (``tool_id`` / ``tool_name`` -> ``tool``,
    ``parameters`` / ``args`` -> ``arguments``) and drops anything unexpected, so
    a request is always ``{tool, arguments}`` — schema-valid and routable by the
    oracle tool-summary.  Constrained decoding usually makes this a no-op, but it
    guards the fallback / unconstrained path.
    """
    out = []
    for r in reqs or []:
        if not isinstance(r, dict):
            continue
        tool = r.get("tool") or r.get("tool_id") or r.get("tool_name") or ""
        args = r.get("arguments")
        if args is None:
            args = r.get("parameters")
        if args is None:
            args = r.get("args")
        if not isinstance(args, dict):
            args = {}
        if not tool:
            # unroutable request with no tool key — skip rather than emit an
            # invalid {arguments-only} item that fails the enum + required check.
            continue
        out.append({"tool": tool, "arguments": args})
    return out
