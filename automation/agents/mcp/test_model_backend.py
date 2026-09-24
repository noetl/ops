"""Tests for the selectable model backend.

Run with no third-party dependency::

    python3 -m unittest discover -s automation/agents/mcp -p 'test_*.py' -v

The load-bearing test is :class:`DefaultIsUnchanged`, which re-implements the
PREVIOUS inline resolver verbatim as an oracle and asserts the new module agrees
with it on every input the old one could take. That makes "flag off changes
nothing" a checked property rather than a claim.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from model_backend import (  # noqa: E402
    DEFAULT_MODEL,
    DEFAULT_OLLAMA_ENDPOINT,
    DEFAULT_SERVER,
    UnknownBackendError,
    resolve_model_backend,
)

NOETL_URL = "http://noetl-server.noetl.svc.cluster.local:8082"
LEGACY_KEYS = ("status", "server", "endpoint", "tool", "model", "source_hint")


def legacy_resolve(triage_mcp_server, triage_model, triage_mcp_endpoint, triage_mcp_tool, noetl_url):
    """Verbatim copy of the resolver that shipped inline in
    ``automation/agents/troubleshoot/diagnose_execution.yaml:236-295``.
    Kept as a frozen oracle; do not "improve" it."""
    DEFAULT_SERVER_ = "mcp/ollama"
    DEFAULT_MODEL_ = "gemma3:4b"
    DEFAULT_OLLAMA_ENDPOINT_ = "http://ollama-bridge.noetl.svc.cluster.local:8765/jsonrpc"
    VERTEX_STUB_SERVER_ = "mcp/vertex-ai-stub"
    VERTEX_AI_SERVER_ = "mcp/vertex-ai"

    def _s(value):
        return str(value).strip() if value is not None else ""

    server = _s(triage_mcp_server) or DEFAULT_SERVER_
    model = _s(triage_model) or DEFAULT_MODEL_
    endpoint = _s(triage_mcp_endpoint)
    tool = _s(triage_mcp_tool)
    if server == VERTEX_STUB_SERVER_:
        endpoint = endpoint or (_s(noetl_url).rstrip("/") + "/api/mcp/playbook/automation/agents/mcp/vertex-ai-stub/jsonrpc")
        tool = tool or "chat_completion"
    elif server == VERTEX_AI_SERVER_:
        endpoint = endpoint or (_s(noetl_url).rstrip("/") + "/api/mcp/playbook/automation/agents/mcp/vertex-ai/jsonrpc")
        tool = tool or "chat_completion"
    else:
        endpoint = endpoint or DEFAULT_OLLAMA_ENDPOINT_
        tool = tool or "chat"
    return {
        "status": "ok",
        "server": server,
        "endpoint": endpoint,
        "tool": tool,
        "model": model,
        "source_hint": ("vertex-stub" if server == VERTEX_STUB_SERVER_
                        else "vertex-ai" if server == VERTEX_AI_SERVER_ else "ollama"),
    }


class DefaultIsUnchanged(unittest.TestCase):
    """With the flag unset, the new resolver must agree with the old one."""

    def test_bare_default_matches_current_production_behaviour(self):
        got = resolve_model_backend(noetl_url=NOETL_URL, env={})
        self.assertEqual(got["server"], DEFAULT_SERVER)
        self.assertEqual(got["model"], DEFAULT_MODEL)
        self.assertEqual(got["endpoint"], DEFAULT_OLLAMA_ENDPOINT)
        self.assertEqual(got["tool"], "chat")
        self.assertEqual(got["source_hint"], "ollama")

    def test_differential_against_frozen_oracle(self):
        servers = [None, "", "mcp/ollama", "mcp/vertex-ai", "mcp/vertex-ai-stub"]
        models = [None, "", "gemma3:4b", "gemini-2.5-flash"]
        endpoints = [None, "", "http://override/x"]
        tools = [None, "", "chat", "chat_completion"]
        checked = 0
        for s in servers:
            for m in models:
                for e in endpoints:
                    for t in tools:
                        want = legacy_resolve(s, m, e, t, NOETL_URL)
                        got = resolve_model_backend(
                            server=s, model=m, endpoint=e, tool=t,
                            noetl_url=NOETL_URL, env={},
                        )
                        for k in LEGACY_KEYS:
                            self.assertEqual(got[k], want[k], f"key {k} for {(s, m, e, t)}")
                        checked += 1
        # Print the denominator: a passing differential test over zero cases
        # is indistinguishable from a broken loop.
        self.assertEqual(checked, len(servers) * len(models) * len(endpoints) * len(tools))
        print(f"\n    differential cases checked: {checked}")


class FlagSelectsBackend(unittest.TestCase):
    def test_vertex(self):
        got = resolve_model_backend(noetl_url=NOETL_URL, env={"NOETL_SLM_BACKEND": "vertex"})
        self.assertEqual(got["server"], "mcp/vertex-ai")
        self.assertEqual(got["source_hint"], "vertex-ai")
        self.assertEqual(got["tool"], "chat_completion")
        self.assertTrue(got["endpoint"].endswith("/automation/agents/mcp/vertex-ai/jsonrpc"))

    def test_vllm(self):
        got = resolve_model_backend(env={"NOETL_SLM_BACKEND": "vllm"})
        self.assertEqual(got["server"], "mcp/vllm")
        self.assertEqual(got["source_hint"], "vllm")
        self.assertIn("/v1/chat/completions", got["endpoint"])

    def test_vertex_stub(self):
        got = resolve_model_backend(noetl_url=NOETL_URL, env={"NOETL_SLM_BACKEND": "vertex-stub"})
        self.assertEqual(got["source_hint"], "vertex-stub")

    def test_every_backend_name_resolves_and_is_distinguishable(self):
        hints = set()
        for name in ("ollama", "vertex", "vertex-stub", "vllm"):
            got = resolve_model_backend(noetl_url=NOETL_URL, env={"NOETL_SLM_BACKEND": name})
            self.assertEqual(got["backend"], name)
            hints.add(got["source_hint"])
        self.assertEqual(len(hints), 4, "each backend must carry a distinct source_hint")


class Precedence(unittest.TestCase):
    def test_explicit_server_beats_flag(self):
        got = resolve_model_backend(
            server="mcp/ollama", noetl_url=NOETL_URL, env={"NOETL_SLM_BACKEND": "vertex"}
        )
        self.assertEqual(got["server"], "mcp/ollama")
        self.assertEqual(got["source_hint"], "ollama")

    def test_explicit_model_beats_env_model(self):
        got = resolve_model_backend(model="gemma2:2b", env={"NOETL_SLM_MODEL": "other"})
        self.assertEqual(got["model"], "gemma2:2b")

    def test_env_model_beats_default(self):
        got = resolve_model_backend(env={"NOETL_SLM_MODEL": "gemma3:4b-it"})
        self.assertEqual(got["model"], "gemma3:4b-it")

    def test_endpoint_override_for_direct_vertex_endpoint(self):
        got = resolve_model_backend(env={
            "NOETL_SLM_BACKEND": "vertex",
            "NOETL_SLM_VERTEX_ENDPOINT": "https://us-central1-aiplatform.googleapis.com/v1/x:predict",
        })
        self.assertEqual(got["endpoint"], "https://us-central1-aiplatform.googleapis.com/v1/x:predict")


class UnknownFlagIsLoud(unittest.TestCase):
    def test_typo_raises_rather_than_falling_back(self):
        with self.assertRaises(UnknownBackendError):
            resolve_model_backend(env={"NOETL_SLM_BACKEND": "vertexai"})

    def test_error_names_the_accepted_values(self):
        try:
            resolve_model_backend(env={"NOETL_SLM_BACKEND": "nope"})
        except UnknownBackendError as exc:
            self.assertIn("ollama", str(exc))
            self.assertIn("vllm", str(exc))
        else:
            self.fail("expected UnknownBackendError")


class BackendPlaybooksExist(unittest.TestCase):
    """Every selectable backend must map to a playbook file that exists.

    A backend name the resolver accepts but that has no playbook behind it is
    the dangling-reference failure this module was written to surface -- the
    same shape as `mcp/ollama` being the DEFAULT while the Service it points
    at is absent from the cluster. This checks the repo half of that; cluster
    reachability is a deploy-time concern and is documented, not asserted here.
    """

    def test_each_mcp_backend_has_a_playbook(self):
        here = os.path.dirname(os.path.abspath(__file__))
        expected = {
            "mcp/ollama": "ollama.yaml",
            "mcp/vertex-ai": "vertex-ai.yaml",
            "mcp/vertex-ai-stub": "vertex-ai-stub.yaml",
            "mcp/vllm": "vllm.yaml",
        }
        from model_backend import BACKENDS
        self.assertEqual(
            set(BACKENDS.values()), set(expected),
            "a backend was added to BACKENDS without a playbook mapping here",
        )
        missing = [f for f in expected.values() if not os.path.isfile(os.path.join(here, f))]
        self.assertEqual(missing, [], f"selectable backend(s) with no playbook: {missing}")
        print(f"\n    backend playbooks verified present: {len(expected)}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
