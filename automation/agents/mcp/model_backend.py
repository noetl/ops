"""Selectable model backend for NoETL small-language-model call sites.

One OpenAI-shaped surface (`chat_completion`) over three interchangeable
backends:

| backend       | server                  | transport                                  |
| :--           | :--                     | :--                                        |
| ``ollama``    | ``mcp/ollama``          | in-cluster ollama-bridge JSON-RPC          |
| ``vertex``    | ``mcp/vertex-ai``       | Vertex AI / Gemini via the NoETL MCP hop   |
| ``vllm``      | ``mcp/vllm``            | OpenAI-shaped vLLM server                  |

Plus ``vertex-stub`` (``mcp/vertex-ai-stub``) for local validation, which
already existed.

Why this module exists
----------------------
The selection logic lived inline in
``automation/agents/troubleshoot/diagnose_execution.yaml`` and was reachable
only from that one playbook. This module is the same decision, extracted so
any call site can make it, plus a ``vllm`` backend and an environment flag.

Backward compatibility is the load-bearing property: with no environment
variable set and no explicit override, :func:`resolve_model_backend` returns
byte-identical values to the previous inline resolver — ``mcp/ollama``,
``gemma3:4b``, the ollama-bridge endpoint, tool ``chat``. ``test_model_backend``
asserts that against a frozen copy of the old outputs, so "the default did not
move" is checked rather than claimed.

Precedence (highest first)
--------------------------
1. an explicit argument at the call site (``server=`` / ``model=`` / ``endpoint=``)
2. the ``NOETL_SLM_BACKEND`` environment flag
3. the default (``ollama``)

A call site that passes nothing and runs with no flag keeps today's behaviour.
"""

from __future__ import annotations

import os
from typing import Any, Dict, Mapping, Optional

# --- current behaviour, preserved exactly -----------------------------------
DEFAULT_BACKEND = "ollama"
DEFAULT_SERVER = "mcp/ollama"
DEFAULT_MODEL = "gemma3:4b"
DEFAULT_OLLAMA_ENDPOINT = "http://ollama-bridge.noetl.svc.cluster.local:8765/jsonrpc"

VERTEX_STUB_SERVER = "mcp/vertex-ai-stub"
VERTEX_AI_SERVER = "mcp/vertex-ai"
VLLM_SERVER = "mcp/vllm"

DEFAULT_VLLM_ENDPOINT = "http://vllm.noetl.svc.cluster.local:8000/v1/chat/completions"

ENV_BACKEND = "NOETL_SLM_BACKEND"
ENV_MODEL = "NOETL_SLM_MODEL"
ENV_VLLM_ENDPOINT = "NOETL_SLM_VLLM_ENDPOINT"
ENV_VERTEX_ENDPOINT = "NOETL_SLM_VERTEX_ENDPOINT"

#: Backend name -> server path. Also the accepted value set for the flag.
BACKENDS: Dict[str, str] = {
    "ollama": DEFAULT_SERVER,
    "vertex": VERTEX_AI_SERVER,
    "vertex-stub": VERTEX_STUB_SERVER,
    "vllm": VLLM_SERVER,
}

#: Server path -> the ``source_hint`` recorded on the answer, so a result
#: carries WHICH backend produced it. Reading a hint is how a caller tells a
#: real Vertex answer from a silent fallback to the default.
SOURCE_HINTS: Dict[str, str] = {
    DEFAULT_SERVER: "ollama",
    VERTEX_AI_SERVER: "vertex-ai",
    VERTEX_STUB_SERVER: "vertex-stub",
    VLLM_SERVER: "vllm",
}

_MCP_PLAYBOOK_PATHS: Dict[str, str] = {
    VERTEX_AI_SERVER: "automation/agents/mcp/vertex-ai",
    VERTEX_STUB_SERVER: "automation/agents/mcp/vertex-ai-stub",
    VLLM_SERVER: "automation/agents/mcp/vllm",
}


class UnknownBackendError(ValueError):
    """Raised when the flag names a backend that does not exist.

    Deliberately loud. A typo in ``NOETL_SLM_BACKEND`` silently falling back to
    Ollama would be indistinguishable from the flag working, which is the
    failure mode this whole module exists to make visible.
    """


def _s(value: Any) -> str:
    return str(value).strip() if value is not None else ""


def _mcp_endpoint(noetl_url: str, server: str) -> str:
    path = _MCP_PLAYBOOK_PATHS[server]
    return _s(noetl_url).rstrip("/") + f"/api/mcp/playbook/{path}/jsonrpc"


def resolve_model_backend(
    server: Any = None,
    model: Any = None,
    endpoint: Any = None,
    tool: Any = None,
    noetl_url: Any = None,
    env: Optional[Mapping[str, str]] = None,
) -> Dict[str, Any]:
    """Resolve the backend for one model call.

    Every argument is an optional per-call-site override; all of them win over
    the environment flag. Returns a superset of the keys the previous inline
    resolver returned, so it is a drop-in replacement.
    """
    env = os.environ if env is None else env

    explicit_server = _s(server)
    flag = _s(env.get(ENV_BACKEND))

    if explicit_server:
        resolved_server = explicit_server
    elif flag:
        if flag not in BACKENDS:
            raise UnknownBackendError(
                f"{ENV_BACKEND}={flag!r} is not one of {sorted(BACKENDS)}"
            )
        resolved_server = BACKENDS[flag]
    else:
        resolved_server = DEFAULT_SERVER

    resolved_model = _s(model) or _s(env.get(ENV_MODEL)) or DEFAULT_MODEL

    resolved_endpoint = _s(endpoint)
    resolved_tool = _s(tool)

    if resolved_server in (VERTEX_AI_SERVER, VERTEX_STUB_SERVER):
        if not resolved_endpoint:
            override = _s(env.get(ENV_VERTEX_ENDPOINT)) if resolved_server == VERTEX_AI_SERVER else ""
            resolved_endpoint = override or _mcp_endpoint(noetl_url, resolved_server)
        resolved_tool = resolved_tool or "chat_completion"
    elif resolved_server == VLLM_SERVER:
        resolved_endpoint = (
            resolved_endpoint or _s(env.get(ENV_VLLM_ENDPOINT)) or DEFAULT_VLLM_ENDPOINT
        )
        resolved_tool = resolved_tool or "chat_completion"
    else:
        resolved_endpoint = resolved_endpoint or DEFAULT_OLLAMA_ENDPOINT
        resolved_tool = resolved_tool or "chat"

    return {
        "status": "ok",
        "server": resolved_server,
        "endpoint": resolved_endpoint,
        "tool": resolved_tool,
        "model": resolved_model,
        # `source_hint` is the anti-false-clean field: assert on it to prove a
        # backend was actually taken rather than merely configured.
        "source_hint": SOURCE_HINTS.get(resolved_server, "ollama"),
        "backend": next(
            (name for name, path in BACKENDS.items() if path == resolved_server),
            "custom",
        ),
        "api": "openai-chat",
    }
