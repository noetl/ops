# Self-troubleshoot agent

NoETL-as-AI-OS Gap 4 — composes Gaps 1+2+3+5 into a self-troubleshoot
playbook that diagnoses failed executions cheap-first via local
Ollama, escalating to OpenAI only when the local model's confidence
is below a configurable threshold.

## Layout

```
automation/agents/troubleshoot/
  diagnose_execution.yaml   # main flow (fetch → triage → escalate → persist)
  runtime.yaml              # terminal-facing wrapper (calls diagnose_execution as agent)
```

## Flow

```
fetch_events ──→ extract_failure_signal ──→ ollama_triage
                                                   │
                                          parse_ollama_response
                                                   │
                          ┌────────── high confidence ──────────┐
                          │                                      │
                  persist_diagnosis                              │
                          │                                      │
                       (end)                                     │
                                                                 │
                          ┌──── low confidence ─────────────────┘
                          │
                   escalate_openai
                          │
                  parse_openai_response
                          │
                  persist_diagnosis
                          │
                       (end)
```

## Workload knobs

| key                    | default                                            | what it controls                       |
|------------------------|----------------------------------------------------|----------------------------------------|
| `execution_id`         | `""` (required)                                    | which failed execution to diagnose     |
| `noetl_url`            | `http://noetl-server.noetl.svc.cluster.local:8080` | NoETL API base (for fetching events)   |
| `triage_model`         | `gemma3:4b`                                        | triage model for first-pass diagnosis  |
| `triage_mcp_server`    | `mcp/ollama`                                       | catalog path of the triage MCP backend |
| `confidence_threshold` | `0.7`                                              | escalate when local confidence < this  |
| `escalate_to`          | `openai`                                           | `openai` / `claude` / `none`           |
| `openai_credential`    | `openai_token`                                     | keychain entry for OpenAI API key      |
| `openai_model`         | `gpt-4o-mini`                                      | OpenAI model for escalation            |

Migration history: workload backend knobs were simplified in v2.36.0
after noetl#418 made canonical `triage_*` forwarding generic. Use
`triage_model` and `triage_mcp_server` for both local Ollama and cloud
MCP backends.

## Output shape

The playbook returns a structured envelope that the GUI's run-dialog
extractor + MCP clients both understand:

```json
{
  "status": "ok",
  "diagnosis": {
    "execution_id": "619156384600293663",
    "category": "transient_5xx",
    "confidence": 0.82,
    "root_cause": "Amadeus sandbox returned HTTP 500 on a well-formed query",
    "suggested_action": "Retry; if persistent, check api.amadeus.com status page",
    "source": "ollama",
    "escalated": false
  },
  "summary": "Amadeus sandbox is temporarily unavailable; retry shortly.",
  "text": "Amadeus sandbox is temporarily unavailable; retry shortly.",
  "user_message": "Amadeus sandbox is temporarily unavailable; retry shortly."
}
```

## Cost / latency profile

```
most failures (HTTP 5xx, timeouts, known patterns):
  Ollama only — ~200ms, $0.00

novel / interesting failures:
  Ollama + OpenAI escalation — ~3s, ~$0.01
```

vs. "OpenAI for every failure" which is ~3s and ~$0.01 *per call*
regardless of whether the failure is novel. At fleet error volumes
(O(thousands) per day) this is the difference between $0/day and
~$30/day in inference spend.

## How to register

```bash
noetl catalog register --type playbook \
  repos/ops/automation/agents/troubleshoot/diagnose_execution.yaml

noetl catalog register --type playbook \
  repos/ops/automation/agents/troubleshoot/runtime.yaml
```

After both register, the runtime agent is callable from the GUI's
terminal as:

```
troubleshoot diagnose <execution_id>
```

Or programmatically as `tool: agent framework=noetl entrypoint:
automation/agents/troubleshoot/runtime` from any peer playbook.

Or as an MCP tool from Cursor / Claude Desktop — point them at:

```
POST /api/mcp/playbook/automation/agents/troubleshoot/diagnose_execution/jsonrpc
```

## Prerequisites

- Triage MCP backend registered in the catalog. Local development uses
  the Ollama bridge sidecar at `mcp/ollama` (NoETL-as-AI-OS Gap 5 — see
  `noetl/tools/ollama_bridge/catalog_template.yaml`)
- A model pulled locally when using the Ollama backend (`ollama pull gemma3:4b`)
- For escalation: `openai_token` in the keychain
