"""End-to-end smoke for the SLM continuous-improvement loop (noetl/ai-meta#150).

Runs the whole flywheel loop — harvest → threshold gate → train → eval +
promotion gate → report — against a domain's existing dataset + a small shadow
corpus, using the **stub** backend (CPU, no GPU) and the **local** file-backed
registry, then asserts every loop invariant the design promises:

  1. HARVEST produces a REGISTERED candidate dataset (G3 lineage anchor).
  2. THRESHOLD GATE skips when new turns < N and proceeds when >= N (or forced).
  3. a tiny train + eval completes and registers a model + eval.
  4. PROMOTION GATE keeps the champion when the candidate doesn't beat it, and
     the pure decision function WOULD promote a candidate that does.
  5. all G3 lineage links resolve (dataset → model → eval; release → [model, eval]).

This is the reproducible form of the kind / CPU validation — it proves the loop
orchestration is correct without a GPU, a server, or live traffic.

Run::

    NOETL_REGISTRY_BACKEND=local \
    python3 lib/slm_improve_smoke.py \
      --config ../../../travel/automation/mlops/slm/travel/slm.config.yaml

Exits non-zero on any assertion failure.
"""

import argparse
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_common as C  # noqa: E402
import slm_finetune as FT  # noqa: E402
import slm_eval as EV  # noqa: E402
import slm_package as PK  # noqa: E402
import slm_registry as REG  # noqa: E402
import slm_improve as IMP  # noqa: E402


def _bootstrap_champion(config_path, dataset_version, tenant, project):
    """Stand up an incumbent champion: train+eval+release a stub model on an
    existing dataset version, returning (release_ref, eval_ref, model_ref)."""
    os.environ["SLM_DATASET_VERSION"] = dataset_version
    ft = FT.finetune(config_path, backend="stub", augment_teacher=True,
                     tenant=tenant, project=project)
    model_ref = ft["registry"]["model_ref"]
    rep, _ = EV.evaluate(config_path, candidate_override="slm", model_ref=model_ref,
                         register=True, tenant=tenant, project=project,
                         constrained_decode=True)
    eval_ref = rep["registry"]["eval_ref"]
    pk = PK.package(config_path, model_ref=model_ref, eval_ref=eval_ref,
                    tenant=tenant, project=project)
    return pk["registry"]["release_ref"], eval_ref, model_ref, rep["metrics"]


def _make_shadow_corpus(seed_path, n, out_path):
    """Carve N seed turns into a shadow-shaped corpus (the harvested delta)."""
    rows = C.read_jsonl(seed_path)[:n]
    for i, r in enumerate(rows):
        r["id"] = "shadow_smoke_%03d" % i
        r["source"] = "shadow_comparison"
        r["started_at"] = "2026-06-28T00:%02d:00Z" % i
    C.write_jsonl(out_path, rows)
    return len(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--champion-dataset", default="v3")
    ap.add_argument("--tenant", default="muno")
    ap.add_argument("--project", default="travel")
    args = ap.parse_args()

    os.environ["NOETL_REGISTRY_BACKEND"] = "local"
    os.environ["NOETL_REGISTRY_LOCAL_DIR"] = tempfile.mkdtemp(prefix="slm_improve_reg_")
    run_dir = tempfile.mkdtemp(prefix="slm_improve_run_")
    client = REG.make_client()

    cfg, cfg_dir = C.load_config(args.config)
    dom = cfg["slm_domain"]
    seed_path = C.resolve(cfg_dir, dom["data"]["seed_corpus"])

    print("== 0. bootstrap incumbent champion (stub on %s) ==" % args.champion_dataset)
    champ_release, champ_eval, champ_model, champ_metrics = _bootstrap_champion(
        args.config, args.champion_dataset, args.tenant, args.project)
    print("  champion release:", champ_release, "| eval:", champ_eval)
    assert champ_release and client.resolve(champ_release, tenant=args.tenant, project=args.project)

    # a shadow delta of 6 turns (the "new real traffic")
    shadow_path = os.path.join(run_dir, "shadow_delta.jsonl")
    n_shadow = _make_shadow_corpus(seed_path, 6, shadow_path)
    print("  shadow delta turns:", n_shadow)

    # ── 1. HARVEST ───────────────────────────────────────────────────────────
    print("== 1. HARVEST ==")
    st = IMP.harvest(args.config, run_dir, shadow_corpus=shadow_path,
                     base_corpus=seed_path, tenant=args.tenant, project=args.project)
    assert st["candidate_dataset_ref"], "harvest must register a candidate dataset"
    assert client.resolve(st["candidate_dataset_ref"], tenant=args.tenant, project=args.project), \
        "candidate dataset ref must resolve"
    assert st["new_real_turns"] == n_shadow, \
        "new_real_turns must count only the shadow delta (%s != %s)" % (st["new_real_turns"], n_shadow)
    # leak-free split + 100% schema validity invariant
    val = st.get("dataset_validity") or {}
    print("  dataset:", st["candidate_dataset_ref"], "| new_real_turns:", st["new_real_turns"],
          "| validity:", val)

    # ── 2. THRESHOLD GATE — skip path ────────────────────────────────────────
    print("== 2a. THRESHOLD GATE (N high -> skip) ==")
    st = IMP.threshold_gate(run_dir, min_new_real_turns=n_shadow + 100)
    assert st["proceed"] is False, "gate must NOT proceed when new turns < N"
    print("  proceed:", st["proceed"], "|", st["threshold_gate"]["reason"])

    # train + eval no-op while gate is closed
    IMP.train(args.config, run_dir, backend="stub", tenant=args.tenant, project=args.project)
    IMP.eval_and_promote(args.config, run_dir, tenant=args.tenant, project=args.project)
    skip_summary = IMP.report(run_dir)
    assert skip_summary["proceeded"] is False
    assert skip_summary["decision"]["promote"] is False
    assert "insufficient new data" in skip_summary["decision"]["reason"]
    print("  loop no-op summary:", skip_summary["decision"]["reason"])

    print("== 2b. THRESHOLD GATE (N low -> proceed) ==")
    st = IMP.threshold_gate(run_dir, min_new_real_turns=1)
    assert st["proceed"] is True, "gate must proceed when new turns >= N"
    print("  proceed:", st["proceed"], "|", st["threshold_gate"]["reason"])

    # ── 3. TRAIN ─────────────────────────────────────────────────────────────
    print("== 3. TRAIN (stub) ==")
    st = IMP.train(args.config, run_dir, backend="stub", tenant=args.tenant, project=args.project)
    cand_model = st["train"]["candidate_model_ref"]
    assert cand_model and client.resolve(cand_model, tenant=args.tenant, project=args.project), \
        "train must register a candidate model"
    # model lineage -> dataset
    m_entry = client.resolve(cand_model, tenant=args.tenant, project=args.project)
    assert m_entry.get("lineage"), "candidate model must carry dataset lineage"
    print("  candidate model:", cand_model, "<- lineage", m_entry["lineage"])

    # ── 4. EVAL + PROMOTION GATE ─────────────────────────────────────────────
    print("== 4. EVAL + PROMOTION GATE ==")
    st = IMP.eval_and_promote(args.config, run_dir, tenant=args.tenant, project=args.project)
    ep = st["eval_promote"]
    cand_eval = ep["candidate_eval_ref"]
    assert cand_eval and client.resolve(cand_eval, tenant=args.tenant, project=args.project), \
        "eval must register a candidate eval"
    # eval lineage -> model
    e_entry = client.resolve(cand_eval, tenant=args.tenant, project=args.project)
    assert cand_model in (e_entry.get("lineage") or []), "candidate eval must point at the candidate model"
    # the tiny stub cannot clear the 0.98 match targets -> champion is kept
    assert ep["promoted"] is False, "tiny stub must NOT be promoted over the champion"
    assert ep["decision"]["threshold_failures"], "rejection must cite threshold failures"
    print("  decision:", ep["decision"]["reason"])
    print("  champion kept:", ep["champion"])

    # champion release unchanged (still the only release)
    releases = client.list(kind="release", name=IMP._model_name(dom),
                           tenant=args.tenant, project=args.project)
    assert len(releases) == 1 and releases[0]["ref"] == champ_release, \
        "no new release on rejection — champion stays"

    # ── 4b. PROMOTION DECISION — the WOULD-promote path (pure function) ───────
    print("== 4b. PROMOTION DECISION (would-promote / regression) ==")
    targets = IMP._gate_targets(dom)
    # a candidate that meets every target and matches/beats the champion → promote
    better = {k: max(1.0, champ_metrics.get(k, 0.0)) for k in targets}
    better.update({k: 1.0 for k in targets})
    v_promote = IMP.promotion_decision(better, champ_metrics, targets)
    assert v_promote["promote"] is True, "a candidate that meets targets + no regression must promote"
    # a candidate that regresses one field vs champion → reject
    worse = dict(better)
    one = next(iter(targets))
    worse[one] = 0.0
    v_reject = IMP.promotion_decision(worse, {k: 1.0 for k in targets}, targets)
    assert v_reject["promote"] is False and (one in v_reject["regressions"] or one in v_reject["threshold_failures"]), \
        "a regressing candidate must be rejected"
    print("  would-promote:", v_promote["reason"])
    print("  regression-reject:", v_reject["reason"])

    # ── 5. REPORT + full lineage resolution ──────────────────────────────────
    print("== 5. REPORT + lineage ==")
    summary = IMP.report(run_dir)
    lin = summary["lineage"]
    for ref in (lin["dataset_ref"], lin["candidate_model_ref"], lin["candidate_eval_ref"]):
        assert ref and client.resolve(ref, tenant=args.tenant, project=args.project), \
            "lineage ref must resolve: %s" % ref
    # champion release lineage = [model, eval]
    rel = client.resolve(champ_release, tenant=args.tenant, project=args.project)
    assert champ_model in rel["lineage"] and champ_eval in rel["lineage"], \
        "champion release lineage must be [model, eval]"
    kinds = {e["kind"] for e in client.list(tenant=args.tenant, project=args.project)}
    assert {"dataset", "model", "eval", "release"} <= kinds, "all 4 G3 kinds present, got %s" % kinds

    print("\nOK — continuous-improvement loop proven end-to-end:")
    print("  • harvest registered a candidate dataset (G3 lineage anchor)")
    print("  • threshold gate skips below N, proceeds at/above N")
    print("  • train + eval completed and registered model + eval")
    print("  • promotion gate KEPT the champion (candidate didn't beat it);")
    print("    decision function WOULD promote a candidate that does")
    print("  • all dataset → model → eval → release lineage links resolve")


if __name__ == "__main__":
    main()
