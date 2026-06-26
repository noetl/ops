"""Offline unit tests for the SLM teacher provider seam (stdlib only).

Run:  python3 -m unittest slm_teacher -v   (from this lib dir)
  or:  python3 test_slm_teacher.py

No network, no API key, no GCP metadata server: every HTTP boundary is faked
via a small urlopen stub or by injecting ``token_fn`` / patching ``_generate``.
Covers: OpenAI + Vertex request build, JSON parse, usage mapping, pro→flash
fallback, and the clean Workload-Identity-block error.
"""

import json
import unittest
import unittest.mock
import urllib.error

import slm_teacher as T


class _FakeResp:
    """Minimal context-manager stand-in for urllib's response object."""

    def __init__(self, body):
        self._b = body.encode("utf-8") if isinstance(body, str) else body

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _capture_urlopen(response_body, sink):
    """Return a urlopen stub that records (url, headers, data) into ``sink``."""

    def _stub(req, timeout=None):
        sink["url"] = req.full_url
        sink["headers"] = {k.lower(): v for k, v in req.header_items()}
        sink["data"] = req.data.decode("utf-8") if req.data else None
        sink["method"] = req.get_method()
        return _FakeResp(response_body)

    return _stub


# ── OpenAI provider ─────────────────────────────────────────────────────────
class TestOpenAIProvider(unittest.TestCase):
    def test_request_build_and_json_parse(self):
        sink = {}
        resp = json.dumps(
            {
                "choices": [{"message": {"content": json.dumps({"slot_updates": {"origin": "JFK"}})}}],
                "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18},
            }
        )
        p = T.OpenAIProvider(api_key="sk-test", max_retries=1)
        with unittest.mock.patch("urllib.request.urlopen", _capture_urlopen(resp, sink)):
            obj, usage = p.chat_json("gpt-4o", "SYS", "USER")
        # request shape
        self.assertEqual(sink["url"], T._OPENAI_CHAT_URL)
        self.assertEqual(sink["method"], "POST")
        self.assertEqual(sink["headers"]["authorization"], "Bearer sk-test")
        body = json.loads(sink["data"])
        self.assertEqual(body["model"], "gpt-4o")
        self.assertEqual(body["response_format"], {"type": "json_object"})
        self.assertEqual(body["messages"][0]["content"], "SYS")
        self.assertEqual(body["messages"][1]["content"], "USER")
        # parsed result + normalized usage
        self.assertEqual(obj, {"slot_updates": {"origin": "JFK"}})
        self.assertEqual(
            usage,
            {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18, "model": "gpt-4o"},
        )

    def test_missing_key_raises(self):
        with self.assertRaises(T.TeacherError):
            T.OpenAIProvider(api_key="")

    def test_openai_compatible_custom_endpoint(self):
        sink = {}
        resp = json.dumps(
            {"choices": [{"message": {"content": "{}"}}], "usage": {}}
        )
        p = T.OpenAIProvider(api_key="sk", endpoint="http://gemma.local/v1/chat/completions", max_retries=1)
        with unittest.mock.patch("urllib.request.urlopen", _capture_urlopen(resp, sink)):
            p.chat_json("qwen2.5-3b", "SYS", "USER")
        self.assertEqual(sink["url"], "http://gemma.local/v1/chat/completions")


# ── Vertex Gemini provider ──────────────────────────────────────────────────
def _vertex_resp(text_obj, usage_meta=None):
    return json.dumps(
        {
            "candidates": [{"content": {"parts": [{"text": json.dumps(text_obj)}]}}],
            "usageMetadata": usage_meta
            or {"promptTokenCount": 20, "candidatesTokenCount": 5, "totalTokenCount": 25},
        }
    )


class TestVertexGeminiProvider(unittest.TestCase):
    def test_request_build_and_json_parse(self):
        sink = {}
        p = T.VertexGeminiProvider(
            project="noetl-demo-19700101", region="us-central1", token_fn=lambda: "wi-token"
        )
        with unittest.mock.patch(
            "urllib.request.urlopen", _capture_urlopen(_vertex_resp({"bot_message": "hi"}), sink)
        ):
            obj, usage = p.chat_json("gemini-2.5-pro", "SYS", "USER")
        self.assertIn(
            "us-central1-aiplatform.googleapis.com/v1/projects/noetl-demo-19700101/"
            "locations/us-central1/publishers/google/models/gemini-2.5-pro:generateContent",
            sink["url"],
        )
        self.assertEqual(sink["headers"]["authorization"], "Bearer wi-token")
        body = json.loads(sink["data"])
        self.assertEqual(body["systemInstruction"]["parts"][0]["text"], "SYS")
        self.assertEqual(body["contents"][0]["parts"][0]["text"], "USER")
        self.assertEqual(body["generationConfig"]["responseMimeType"], "application/json")
        self.assertEqual(obj, {"bot_message": "hi"})
        self.assertEqual(usage["model"], "gemini-2.5-pro")

    def test_usage_mapping(self):
        usage = T._normalize_vertex_usage(
            {"promptTokenCount": 100, "candidatesTokenCount": 40, "totalTokenCount": 140},
            "gemini-2.5-pro",
        )
        self.assertEqual(
            usage,
            {"prompt_tokens": 100, "completion_tokens": 40, "total_tokens": 140, "model": "gemini-2.5-pro"},
        )

    def test_pro_to_flash_fallback(self):
        p = T.VertexGeminiProvider(project="proj", token_fn=lambda: "tok")
        calls = []

        def fake_generate(token, model, system, user):
            calls.append(model)
            if model == "gemini-2.5-pro":
                raise T.TeacherError("vertex gemini-2.5-pro HTTP 429: resource exhausted")
            return {"ok": True}, {
                "prompt_tokens": 1,
                "completion_tokens": 1,
                "total_tokens": 2,
                "model": model,
            }

        with unittest.mock.patch.object(p, "_generate", side_effect=fake_generate):
            obj, usage = p.chat_json("gemini-2.5-pro", "SYS", "USER")
        self.assertEqual(calls, ["gemini-2.5-pro", "gemini-2.5-flash"])
        self.assertEqual(obj, {"ok": True})
        self.assertEqual(usage["model"], "gemini-2.5-flash")

    def test_wi_block_clean_error(self):
        # metadata server unreachable → clean TeacherError, no fallback masking
        def boom_urlopen(req, timeout=None):
            raise urllib.error.URLError("metadata.google.internal: name resolution failed")

        p = T.VertexGeminiProvider(project="proj")  # default token_fn = real metadata mint
        with unittest.mock.patch("urllib.request.urlopen", boom_urlopen):
            with self.assertRaises(T.TeacherError) as ctx:
                p.chat_json("gemini-2.5-pro", "SYS", "USER")
        msg = str(ctx.exception)
        self.assertIn("metadata server unreachable", msg)
        self.assertIn("Workload Identity", msg)

    def test_no_candidates_raises(self):
        sink = {}
        resp = json.dumps({"candidates": [], "promptFeedback": {"blockReason": "SAFETY"}})
        p = T.VertexGeminiProvider(project="proj", fallback_model=None, token_fn=lambda: "tok", max_retries=1)
        with unittest.mock.patch("urllib.request.urlopen", _capture_urlopen(resp, sink)):
            with self.assertRaises(T.TeacherError) as ctx:
                p.chat_json("gemini-2.5-pro", "SYS", "USER")
        self.assertIn("no candidates", str(ctx.exception))


# ── from_config provider selection ──────────────────────────────────────────
class _FakeCommon:
    @staticmethod
    def resolve(cfg_dir, p):
        return None  # no prompt file → empty system prompt (offline)


def _cfg(teacher):
    return {
        "slm_domain": {
            "roles": [{"id": "extract"}, {"id": "render"}],
            "vocab": {},
            "teachers": [teacher],
        }
    }


class TestFromConfigProviderSelection(unittest.TestCase):
    def test_selects_vertex_gemini(self):
        cfg = _cfg(
            {
                "id": "primary",
                "status": "enabled",
                "provider": "vertex_gemini",
                "vertex": {"project": "noetl-demo-19700101", "region": "us-central1"},
                "models": {"extract": "gemini-2.5-pro", "render": "gemini-2.5-pro", "fallback": "gemini-2.5-flash"},
            }
        )
        teacher, msg = T.Teacher.from_config(cfg, ".", _FakeCommon)
        self.assertIsInstance(teacher._provider, T.VertexGeminiProvider)
        self.assertEqual(teacher._provider.project, "noetl-demo-19700101")
        self.assertEqual(teacher._provider.fallback_model, "gemini-2.5-flash")
        self.assertEqual(teacher.extract_model, "gemini-2.5-pro")
        self.assertIn("vertex_gemini", msg)

    def test_selects_openai(self):
        import os

        os.environ["OPENAI_API_KEY"] = "sk-fromenv"
        try:
            cfg = _cfg(
                {
                    "id": "primary",
                    "status": "enabled",
                    "provider": "openai",
                    "models": {"extract": "gpt-4o", "render": "gpt-4o-mini"},
                }
            )
            teacher, _ = T.Teacher.from_config(cfg, ".", _FakeCommon)
            self.assertIsInstance(teacher._provider, T.OpenAIProvider)
        finally:
            del os.environ["OPENAI_API_KEY"]

    def test_disabled_teacher_returns_none(self):
        cfg = _cfg({"id": "primary", "status": "disabled"})
        teacher, msg = T.Teacher.from_config(cfg, ".", _FakeCommon)
        self.assertIsNone(teacher)
        self.assertIn("no enabled teacher", msg)

    def test_unknown_provider_raises(self):
        cfg = _cfg(
            {
                "id": "primary",
                "status": "enabled",
                "provider": "anthropic",
                "models": {"extract": "x", "render": "y"},
            }
        )
        with self.assertRaises(T.TeacherError):
            T.Teacher.from_config(cfg, ".", _FakeCommon)


if __name__ == "__main__":
    import unittest.mock  # noqa: F401  (ensure available when run as a script)

    unittest.main(verbosity=2)
