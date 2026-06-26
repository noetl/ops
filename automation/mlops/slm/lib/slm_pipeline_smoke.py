"""End-to-end Phase-B pipeline smoke (noetl/ai-meta#141).

Runs the whole MLOps spine — finetune → eval → package — against a domain's
Phase-1 dataset using the **stub** backend (CPU, no GPU, no heavy deps) and the
**local** file-backed registry, then asserts the lineage DAG and the
constrained-decoding validity invariant.  This is the reproducible form of the
kind / CPU validation: it proves the orchestration is correct without touching a
GPU or a server.

Run::

    NOETL_REGISTRY_BACKEND=local \
    python3 lib/slm_pipeline_smoke.py \
      --config ../../../travel/automation/mlops/slm/travel/slm.config.yaml \
      --dataset-version v1_constrained

Exits non-zero on any assertion failure.
"""

import argparse
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_finetune as FT  # noqa: E402
import slm_eval as EV  # noqa: E402
import slm_package as PK  # noqa: E402
import slm_registry as REG  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--dataset-version", default="v1_constrained")
    ap.add_argument("--tenant", default="muno")
    ap.add_argument("--project", default="travel")
    args = ap.parse_args()

    # isolate the registry to a throwaway dir + force the local backend
    os.environ["NOETL_REGISTRY_BACKEND"] = "local"
    os.environ["NOETL_REGISTRY_LOCAL_DIR"] = tempfile.mkdtemp(prefix="slm_smoke_reg_")
    os.environ["SLM_DATASET_VERSION"] = args.dataset_version

    print("== finetune (stub, local) ==")
    ft = FT.finetune(args.config, backend="stub", augment_teacher=True,
                     tenant=args.tenant, project=args.project)
    model_ref = ft["registry"]["model_ref"]
    dataset_ref = ft["registry"]["dataset_ref"]
    assert model_ref and dataset_ref, "finetune must register a model + dataset"
    print("  model:", model_ref, "<-", dataset_ref)

    print("== eval (candidate=slm, register) ==")
    report, _ = EV.evaluate(args.config, candidate_override="slm", model_ref="latest",
                            register=True, tenant=args.tenant, project=args.project)
    m = report["metrics"]
    eval_ref = report["registry"]["eval_ref"]
    assert report["registry"]["model_ref"] == model_ref, "eval lineage must point at the model"
    # the load-bearing invariant: constrained decoding holds schema validity at 1.0
    for k in ("widget_schema_validity", "extract_schema_validity",
              "tool_vocab_validity", "render_intent_vocab_validity"):
        assert m[k] == 1.0, "%s must be 1.0 under constrained decoding, got %s" % (k, m[k])
    print("  eval:", eval_ref, "| validity all 1.0 | match tool=%.2f intent=%.2f"
          % (m["tool_match"], m["render_intent_match"]))

    print("== package (release) ==")
    pk = PK.package(args.config, tenant=args.tenant, project=args.project)
    release_ref = pk["registry"]["release_ref"]
    assert set(pk["registry"]["lineage"]) == {model_ref, eval_ref}, "release lineage = {model, eval}"
    print("  release:", release_ref, "<-", pk["registry"]["lineage"])

    # assert the full DAG is queryable
    client = REG.make_client()
    kinds = {e["kind"] for e in client.list(tenant=args.tenant, project=args.project)}
    assert kinds == {"dataset", "model", "eval", "release"}, "DAG must have all 4 kinds, got %s" % kinds

    print("\nOK — dataset -> model -> eval -> release lineage proven; "
          "constrained-decoding validity invariant held.")


if __name__ == "__main__":
    main()
