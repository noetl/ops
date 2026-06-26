"""End-to-end smoke for the G3 registry (noetl/ai-meta#146).

Exercises the full MLOps-stage shape against a running NoETL server (the server
must run with ``NOETL_REGISTRY_ENABLED=true``):

  1. dataset_build  → PUT dataset artifact + register dataset v1
  2. finetune       → PUT model adapter + register model v1 (lineage → dataset)
  3. eval           → register eval (metadata-only; lineage → model)
  4. finetune again → register model v2 (proves monotonic versioning)
  5. list / resolve (specific + ``latest``)
  6. GET the dataset artifact back from the object store (bytes round-trip)
  7. assert lineage links resolved end-to-end

Used as the kind-validation harness for #146 and as the worked dogfood example
the SLM stages follow.

Run:
    NOETL_SERVER_URL=http://localhost:8082 \
    NOETL_INTERNAL_API_TOKEN=<token> \
    python3 slm_registry_smoke.py
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from slm_registry import RegistryClient  # noqa: E402


def main():
    domain = os.environ.get("SLM_SMOKE_DOMAIN", "smoke_travel")
    client = RegistryClient()
    print("== G3 registry smoke (#146) :: project=%s ==" % domain)

    # 1. dataset_build — store a (tiny stand-in for GB-scale) dataset + register.
    dataset_jsonl = "\n".join(
        json.dumps({"turn": i, "label": "search_flights"}) for i in range(5)
    )
    ds = client.put_and_register(
        "dataset", "intent_turns", "train.jsonl", dataset_jsonl,
        media_type="application/jsonl",
        metadata={"rows": 5, "split": "train", "source": "seed_corpus"},
        tags=["seed", "v0"], project=domain,
    )
    print("  dataset registered:", ds["ref"], "artifact=", ds["artifact_uri"])
    assert ds["version"] == 1, ds

    # 2. finetune — store an adapter blob + register model v1, lineage → dataset.
    adapter_bytes = b"\x00ADAPTER-WEIGHTS-v1\x00" * 64
    m1 = client.put_and_register(
        "model", "intent_extractor", "adapter.safetensors", adapter_bytes,
        media_type="application/octet-stream",
        metadata={"base_model": "qwen2.5-1.5b", "recipe": "qlora-r16", "train_rows": 5},
        lineage=[ds["ref"]], project=domain,
    )
    print("  model v1 registered:", m1["ref"], "lineage=", m1["lineage"])
    assert m1["version"] == 1 and ds["ref"] in m1["lineage"], m1

    # 3. eval — metadata-only entry, lineage → model v1.
    ev = client.register(
        "eval", "intent_extractor_floor",
        metadata={"accuracy": 0.91, "floor": 0.85, "ceiling": 0.97, "passed": True},
        lineage=[m1["ref"], ds["ref"]], project=domain,
    )
    print("  eval registered:", ev["ref"], "metrics=", ev["metadata"])
    assert ev["artifact_uri"] is None, ev

    # 4. finetune again — model v2 (monotonic versioning under the same name).
    m2 = client.put_and_register(
        "model", "intent_extractor", "adapter.safetensors",
        b"\x00ADAPTER-WEIGHTS-v2\x00" * 64,
        metadata={"base_model": "qwen2.5-1.5b", "recipe": "qlora-r32", "train_rows": 9},
        lineage=[ds["ref"], ev["ref"]], project=domain,
    )
    print("  model v2 registered:", m2["ref"])
    assert m2["version"] == 2, m2

    # 5. list + resolve.
    models = client.list(kind="model", name="intent_extractor", project=domain)
    print("  list model/intent_extractor ->", [e["version"] for e in models])
    assert {e["version"] for e in models} == {1, 2}, models

    latest = client.resolve("registry://model/intent_extractor/latest", project=domain)
    print("  resolve latest ->", latest["ref"], "v", latest["version"])
    assert latest["version"] == 2, latest

    pinned = client.resolve("registry://model/intent_extractor/1", project=domain)
    assert pinned["version"] == 1 and pinned["entry_id"] == m1["entry_id"], pinned

    # 6. artifact bytes round-trip from the object store.
    fetched = client.get_artifact(ds["artifact_uri"])
    assert fetched.decode("utf-8") == dataset_jsonl, "dataset bytes mismatch"
    print("  artifact round-trip OK (%d bytes)" % len(fetched))

    # 7. lineage walks end-to-end: eval -> model v1 -> dataset.
    eval_resolved = client.resolve(ev["ref"], project=domain)
    assert m1["ref"] in eval_resolved["lineage"], eval_resolved
    model_resolved = client.resolve(m1["ref"], project=domain)
    assert ds["ref"] in model_resolved["lineage"], model_resolved
    dataset_resolved = client.resolve(ds["ref"], project=domain)
    assert dataset_resolved["artifact_uri"] == ds["artifact_uri"], dataset_resolved
    print("  lineage walk eval -> model -> dataset OK")

    print("== PASS: register / list / resolve / lineage / artifact put+get ==")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as exc:
        print("ASSERT FAILED:", exc, file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # noqa: BLE001
        print("ERROR:", exc, file=sys.stderr)
        sys.exit(2)
