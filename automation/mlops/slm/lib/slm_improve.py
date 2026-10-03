"""Generic SLM continuous-improvement loop engine — the data-flywheel operator.

This is the orchestration brain behind ``automation/mlops/slm/improve.yaml``: it
ties the already-shipped flywheel stages — replay(``--shadow``), the
oracle-labeled synthetic generator, ``dataset_build``, ``finetune``, ``eval``,
``package``, and the G3 registry — into ONE gated loop whose job is "keep the
domain SLM constantly improved" without a human in the inner loop.

Domain-agnostic: every knob comes from the org ``slm.config.yaml`` (the same one
the other stages read) + the loop's own ``improvement`` block.  Travel is the
worked example; ``examples/support_triage`` would run the identical loop with its
own config.

Five stages, two gates (RFC §2.2 ``improvement`` block, noetl/ai-meta#150):

  1. HARVEST           ingest new shadow records since the last run
                       (``slm_replay --shadow``) + optional oracle-labeled
                       synthetic top-up for thin slices → assemble + REGISTER a
                       candidate dataset version in G3 (leak-free split, 100%%
                       schema validity).
  2. THRESHOLD GATE    proceed to train only if the candidate carries
                       >= ``min_new_real_turns`` NEW real turns OR the scheduled
                       cadence elapsed — else no-op + report "insufficient new
                       data" (stops pointless retrains).
  3. TRAIN             finetune a candidate model on the new dataset (the
                       validated recipe: qwen2.5-1.5B LoRA, balanced extract
                       distribution, NO envelope-first serialization — the v4
                       negative-result learnings) → REGISTER a G3 model
                       (lineage → dataset).  ``mode=local`` stub for CI / kind;
                       ``mode=mlx`` real local LoRA; ``mode=container`` GPU Job.
  4. EVAL + PROMOTION  eval the candidate under constrained decoding on the
       GATE            holdout (schema validity + per-field match vs the oracle
                       floor AND vs the current CHAMPION).  Promote to champion
                       only if it does NOT regress any field vs the champion AND
                       meets every configured per-field threshold; else keep the
                       champion + record the candidate as rejected (with reason).
                       Promotion = register a G3 ``release`` (the new champion
                       marker); lineage → [model, eval].
  5. REPORT            emit a run summary: dataset delta, candidate-vs-champion
                       per-field table, promote/reject decision + reason, all
                       lineage URNs.

The champion is tracked as the latest G3 ``release`` entry for the model name
(``<domain>_slm_multitask``).  On the very first loop run no release exists yet,
so the loop BOOTSTRAPS the champion from the configured incumbent
(``improvement.champion`` in the config, or ``--champion-eval-ref`` /
``--champion-model-ref``) — for travel that is the v3 model + eval — and
registers the initial champion release so subsequent runs compare against it.

State is shared between the playbook's per-stage steps through
``<run_dir>/run_state.json`` (so ``improve.yaml`` can run each stage as a
separate, individually-inspectable NoETL step), and the whole loop is also
runnable in one process via the ``run`` subcommand (used by the smoke test).

Registry access is server-mediated for the real run (``NOETL_REGISTRY_BACKEND``
unset / ``server`` + ``NOETL_SERVER_URL`` + ``NOETL_INTERNAL_API_TOKEN`` against
a server with ``NOETL_REGISTRY_ENABLED=true``) and file-backed for the offline
smoke (``NOETL_REGISTRY_BACKEND=local``) — data-access-boundary.md: never direct
DB / object access.

Tracks noetl/ai-meta#150 (continuous-improvement loop engine), umbrella #139 /
#153 (shadow rollout Option A — the flywheel this operationalizes).
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_common as C  # noqa: E402


# ── helpers ──────────────────────────────────────────────────────────────────

def _registry_namespace(dom):
    ns = dom.get("improvement", {}).get("governance", {}).get(
        "registry_namespace", "default/default")
    t, _, p = ns.partition("/")
    return (t or "default"), (p or dom["name"])


def _model_name(dom):
    return "%s_slm_multitask" % dom["name"]


def _improve_cfg(dom):
    return dom.get("improvement", {}) or {}


def _gate_targets(dom):
    """The per-field thresholds the candidate must clear — the same numeric
    targets the eval gate uses (config ``eval.metrics``)."""
    out = {}
    for m in dom.get("eval", {}).get("metrics", []):
        if "target" in m:
            out[m["id"]] = m["target"]
    return out


def _load_state(run_dir):
    path = os.path.join(run_dir, "run_state.json")
    if os.path.isfile(path):
        with open(path) as fh:
            return json.load(fh)
    return {}


def _save_state(run_dir, state):
    os.makedirs(run_dir, exist_ok=True)
    C.write_json(os.path.join(run_dir, "run_state.json"), state)
    return state


def _registry_client():
    import slm_registry as REG
    return REG.make_client()


# ── stage 1: HARVEST ─────────────────────────────────────────────────────────

def harvest(config_path, run_dir, *, shadow_corpus=None, base_corpus=None,
            synthetic_topup=0, base_url=None, replay_path=None, replay_limit=1000,
            candidate_version=None, tenant=None, project=None, use_teacher=False):
    """Assemble + register a candidate dataset from new shadow traffic.

    Sources, in priority order, merged into one corpus dataset_build re-labels:

      * ``shadow_corpus`` — a pre-harvested ``slm_replay --shadow`` corpus file
        (the offline / CI path: no live server needed).
      * ``base_url`` — when given, run ``slm_replay.ingest_shadow`` live to pull
        NEW shadow records from the event log (read-only, the production path).
      * ``base_corpus`` — an existing labelable corpus (e.g. the seed) to anchor
        the dataset so a thin shadow delta still trains.
      * ``synthetic_topup`` — N oracle-labeled synthetic turns for
        under-represented slices (the generator is the domain's
        ``gen_synthetic_corpus.py``; optional, off by default).

    ``new_real_turns`` (what the threshold gate reads) counts ONLY the harvested
    shadow turns — the real-traffic delta — not the anchor or synthetic top-up.
    """
    cfg, cfg_dir = C.load_config(config_path)
    dom = cfg["slm_domain"]
    t, p = _registry_namespace(dom)
    tenant = tenant or t
    project = project or p
    state = _load_state(run_dir)

    harvested = []
    sources = []

    # (a) live replay of NEW shadow records since the last run watermark
    last_ts = state.get("watermark_started_at")
    replay_summary = None
    if base_url:
        try:
            import slm_replay as RP
            out = os.path.join(run_dir, "shadow_replay_corpus.jsonl")
            replay_summary = RP.ingest_shadow(
                base_url, replay_path or dom.get("data", {}).get(
                    "event_log_replay", {}).get("path"),
                limit=replay_limit, out_path=out, config_path=config_path)
            live = C.read_jsonl(out)
            # incremental: keep only turns newer than the watermark
            if last_ts:
                live = [r for r in live if (r.get("started_at") or "") > last_ts]
            harvested.extend(live)
            sources.append({"kind": "live_replay", "turns": len(live),
                            "summary": replay_summary})
        except Exception as exc:  # live replay is best-effort; offline path covers CI
            sources.append({"kind": "live_replay", "error": str(exc)})

    # (b) a pre-harvested shadow corpus file (offline / CI)
    if shadow_corpus and os.path.isfile(shadow_corpus):
        rows = C.read_jsonl(shadow_corpus)
        if last_ts:
            rows = [r for r in rows if (r.get("started_at") or "") > last_ts or not r.get("started_at")]
        harvested.extend(rows)
        sources.append({"kind": "shadow_corpus_file", "path": shadow_corpus, "turns": len(rows)})

    new_real_turns = len(harvested)

    # (c) synthetic top-up for thin slices (oracle-labeled, cheap)
    synth = []
    if synthetic_topup and int(synthetic_topup) > 0:
        synth = _synthetic_topup(cfg_dir, dom, int(synthetic_topup), run_dir)
        sources.append({"kind": "synthetic_topup", "turns": len(synth)})

    # (d) anchor corpus so a thin delta still yields a trainable dataset
    anchor = []
    if base_corpus and os.path.isfile(base_corpus):
        anchor = C.read_jsonl(base_corpus)
        sources.append({"kind": "anchor_corpus", "path": base_corpus, "turns": len(anchor)})

    corpus = anchor + harvested + synth
    if not corpus:
        raise SystemExit("harvest produced an empty corpus — give --shadow-corpus, "
                         "--base-url, --base-corpus, or --synthetic-topup")

    corpus_path = os.path.join(run_dir, "candidate_corpus.jsonl")
    C.write_jsonl(corpus_path, corpus)

    # build the versioned candidate dataset (leak-free split + schema validity)
    version = candidate_version or _candidate_version(state)
    import slm_dataset_build as DB
    manifest, ds_dir = DB.build(
        config_path, corpus_override=corpus_path, version_override=version,
        use_teacher=use_teacher)

    # register the dataset in G3 (lineage anchor for the model)
    dataset_ref = None
    reg_err = None
    try:
        client = _registry_client()
        ds_name = "%s_%s" % (dom["name"], version)
        existing = client.list(kind="dataset", name=ds_name, tenant=tenant, project=project, limit=1)
        if existing:
            dataset_ref = existing[0]["ref"]
        else:
            entry = client.register(
                "dataset", ds_name,
                metadata={"manifest": manifest, "dataset_dir": ds_dir,
                          "new_real_turns": new_real_turns, "sources": sources,
                          "registered_by": "slm_improve.harvest"},
                tags=["slm", dom["name"], version, "candidate"],
                tenant=tenant, project=project)
            dataset_ref = entry["ref"]
    except Exception as exc:
        reg_err = str(exc)

    # watermark: newest started_at we have seen (for the next incremental run)
    seen_ts = [r.get("started_at") for r in harvested if r.get("started_at")]
    watermark = max(seen_ts) if seen_ts else last_ts

    state.update({
        "config": config_path,
        "tenant": tenant, "project": project,
        "candidate_version": version,
        "candidate_dataset_dir": ds_dir,
        "candidate_dataset_ref": dataset_ref,
        "dataset_register_error": reg_err,
        "new_real_turns": new_real_turns,
        "dataset_counts": manifest.get("counts"),
        "dataset_validity": manifest.get("validity"),
        "harvest_sources": sources,
        "watermark_started_at": watermark,
        "harvest_unix": int(time.time()),
    })
    _save_state(run_dir, state)
    return state


def _candidate_version(state):
    """A deterministic, monotonically-increasing candidate version label."""
    n = int(state.get("loop_counter", 0)) + 1
    return "improve_cand_%03d" % n


def _synthetic_topup(cfg_dir, dom, n, run_dir):
    """Generate N oracle-labeled synthetic turns via the domain's
    ``gen_synthetic_corpus.py`` (if present).  Returns labelable corpus rows
    (dataset_build re-labels them, so we only need the input shape)."""
    gen_path = os.path.join(cfg_dir, "gen_synthetic_corpus.py")
    if not os.path.isfile(gen_path):
        return []
    try:
        gen = C.import_module_from_path(gen_path)
    except Exception:
        return []
    # the generator exposes generate(n) -> list[turn] in the corpus input shape
    for fn in ("generate", "generate_corpus", "sample"):
        if hasattr(gen, fn):
            try:
                rows = getattr(gen, fn)(n)
                return list(rows)[:n]
            except Exception:
                continue
    return []


# ── stage 2: THRESHOLD GATE ──────────────────────────────────────────────────

def threshold_gate(run_dir, *, min_new_real_turns, force=False,
                   cadence_days=None, last_run_unix=None):
    """Decide whether the candidate carries enough new signal to justify a
    retrain.  Proceed if forced, OR >= ``min_new_real_turns`` new real turns,
    OR the scheduled cadence elapsed since the last run."""
    state = _load_state(run_dir)
    new_real = int(state.get("new_real_turns", 0))
    reasons = []
    proceed = False

    if force:
        proceed = True
        reasons.append("forced (--force)")
    if new_real >= int(min_new_real_turns):
        proceed = True
        reasons.append("new_real_turns %d >= min %d" % (new_real, min_new_real_turns))
    else:
        reasons.append("new_real_turns %d < min %d" % (new_real, min_new_real_turns))

    cadence_elapsed = False
    if cadence_days and last_run_unix:
        elapsed_days = (time.time() - float(last_run_unix)) / 86400.0
        cadence_elapsed = elapsed_days >= float(cadence_days)
        if cadence_elapsed:
            proceed = True
            reasons.append("cadence elapsed (%.1f >= %s days)" % (elapsed_days, cadence_days))

    decision = {
        "proceed": proceed,
        "new_real_turns": new_real,
        "min_new_real_turns": int(min_new_real_turns),
        "cadence_days": cadence_days,
        "cadence_elapsed": cadence_elapsed,
        "forced": bool(force),
        "reason": "; ".join(reasons),
    }
    state["threshold_gate"] = decision
    state["proceed"] = proceed
    _save_state(run_dir, state)
    return state


# ── stage 3: TRAIN ───────────────────────────────────────────────────────────

def train(config_path, run_dir, *, backend="stub", augment_teacher=True,
          tenant=None, project=None, **mlx_kwargs):
    """Finetune a candidate model on the harvested dataset → register a G3 model
    (lineage → dataset).  No-op when the threshold gate said don't proceed."""
    state = _load_state(run_dir)
    if not state.get("proceed"):
        state["train"] = {"skipped": True, "reason": "threshold gate: no proceed"}
        _save_state(run_dir, state)
        return state

    os.environ["SLM_DATASET_VERSION"] = state["candidate_version"]
    import slm_finetune as FT
    ft = FT.finetune(
        config_path, backend=backend, dataset_dir=state.get("candidate_dataset_dir"),
        augment_teacher=augment_teacher, register=True,
        tenant=tenant or state.get("tenant"), project=project or state.get("project"),
        **mlx_kwargs)
    reg = ft.get("registry") or {}
    state["train"] = {
        "skipped": False,
        "backend": ft.get("backend"),
        "base_model": ft.get("base_model"),
        "candidate_model_ref": reg.get("model_ref"),
        "dataset_ref": reg.get("dataset_ref"),
        "train_records": ft.get("train_records"),
    }
    _save_state(run_dir, state)
    return state


# ── stage 4: EVAL + PROMOTION GATE ───────────────────────────────────────────

def _resolve_champion(client, dom, tenant, project, *, champion_eval_ref=None,
                      champion_model_ref=None):
    """Return ``(champion_metrics, champion_info)``.

    Champion = the latest G3 ``release`` for the model name; its
    ``metadata.eval_metrics`` are the bar to beat.  On the first loop run (no
    release yet) bootstrap from the configured incumbent eval ref (travel: v3).
    Returns ``(None, {...})`` when there is genuinely no incumbent (first model
    ever for a brand-new domain) — then the candidate auto-promotes if it clears
    the configured thresholds."""
    model_name = _model_name(dom)
    releases = client.list(kind="release", name=model_name, tenant=tenant, project=project, limit=1)
    if releases:
        rel = releases[0]
        metrics = (rel.get("metadata", {}) or {}).get("eval_metrics") or {}
        return metrics, {"source": "release", "release_ref": rel.get("ref"),
                         "eval_ref": (rel.get("metadata", {}) or {}).get("eval_ref"),
                         "model_ref": (rel.get("metadata", {}) or {}).get("model_ref")}

    # bootstrap from the configured incumbent
    imp = _improve_cfg(dom).get("champion", {}) or {}
    eval_ref = champion_eval_ref or imp.get("eval_ref")
    model_ref = champion_model_ref or imp.get("model_ref")
    if eval_ref:
        entry = client.resolve(eval_ref, tenant=tenant, project=project)
        if entry:
            metrics = (entry.get("metadata", {}) or {}).get("metrics") or {}
            return metrics, {"source": "bootstrap_eval_ref", "eval_ref": eval_ref,
                             "model_ref": model_ref, "bootstrap": True}
    return None, {"source": "none", "note": "no incumbent champion — first model for this domain"}


def promotion_decision(candidate_metrics, champion_metrics, targets, *, epsilon=1e-9):
    """The promotion rule: promote only if the candidate REGRESSES NO field vs
    the champion AND meets EVERY configured per-field threshold.

    Returns a structured verdict with the per-field comparison so REPORT can
    print exactly why a candidate was kept or rejected.
    """
    fields = sorted(set(targets) | set(champion_metrics or {}))
    comparison = []
    regressions = []
    threshold_failures = []
    for f in fields:
        cand = candidate_metrics.get(f)
        champ = (champion_metrics or {}).get(f)
        tgt = targets.get(f)
        row = {"field": f, "candidate": cand, "champion": champ, "target": tgt}
        if cand is None:
            row["status"] = "missing"
            comparison.append(row)
            continue
        regressed = champ is not None and cand < champ - epsilon
        below_target = tgt is not None and cand < tgt - epsilon
        row["regressed_vs_champion"] = regressed
        row["below_target"] = below_target
        row["delta_vs_champion"] = (round(cand - champ, 6) if champ is not None else None)
        if regressed:
            regressions.append(f)
        if below_target:
            threshold_failures.append(f)
        row["status"] = "ok" if not (regressed or below_target) else "fail"
        comparison.append(row)

    has_champion = bool(champion_metrics)
    promote = (not regressions) and (not threshold_failures)
    if has_champion:
        if promote:
            reason = "no field regresses vs champion and all thresholds met"
        elif regressions:
            reason = "regresses vs champion on: %s" % ", ".join(regressions)
        else:
            reason = "below configured threshold on: %s" % ", ".join(threshold_failures)
    else:
        promote = not threshold_failures
        reason = ("no incumbent champion; promoted as first model (thresholds met)"
                  if promote else
                  "no incumbent champion; below threshold on: %s" % ", ".join(threshold_failures))

    return {
        "promote": promote,
        "reason": reason,
        "regressions": regressions,
        "threshold_failures": threshold_failures,
        "has_champion": has_champion,
        "comparison": comparison,
    }


def eval_and_promote(config_path, run_dir, *, constrained_decode=True,
                     champion_eval_ref=None, champion_model_ref=None,
                     tenant=None, project=None, do_promote=True):
    """Eval the candidate (candidate=slm, constrained) → register the eval →
    compare vs champion → promote (register a release) or reject."""
    state = _load_state(run_dir)
    if not state.get("proceed"):
        state["eval_promote"] = {"skipped": True, "reason": "threshold gate: no proceed"}
        _save_state(run_dir, state)
        return state

    cfg, _ = C.load_config(config_path)
    dom = cfg["slm_domain"]
    tenant = tenant or state.get("tenant")
    project = project or state.get("project")

    cand_model_ref = (state.get("train") or {}).get("candidate_model_ref")

    import slm_eval as EV
    os.environ["SLM_DATASET_VERSION"] = state["candidate_version"]
    report, out_path = EV.evaluate(
        config_path, dataset_dir=state.get("candidate_dataset_dir"),
        candidate_override="slm", model_ref=cand_model_ref or "latest",
        register=True, tenant=tenant, project=project,
        constrained_decode=constrained_decode)
    cand_metrics = report["metrics"]
    eval_ref = (report.get("registry") or {}).get("eval_ref")

    client = _registry_client()
    champ_metrics, champ_info = _resolve_champion(
        client, dom, tenant, project,
        champion_eval_ref=champion_eval_ref, champion_model_ref=champion_model_ref)

    targets = _gate_targets(dom)
    verdict = promotion_decision(cand_metrics, champ_metrics, targets)

    release_ref = None
    promoted = False
    if verdict["promote"] and do_promote:
        import slm_package as PK
        pk = PK.package(config_path, model_ref=cand_model_ref or "latest",
                        eval_ref=eval_ref or "latest", tenant=tenant, project=project)
        release_ref = (pk.get("registry") or {}).get("release_ref")
        promoted = True

    state["eval_promote"] = {
        "skipped": False,
        "candidate_eval_ref": eval_ref,
        "candidate_model_ref": cand_model_ref,
        "candidate_metrics": cand_metrics,
        "candidate_latency_ms": report.get("latency_ms"),
        "champion": champ_info,
        "champion_metrics": champ_metrics,
        "decision": verdict,
        "promoted": promoted,
        "new_champion_release_ref": release_ref,
    }
    _save_state(run_dir, state)
    return state


# ── stage 5: REPORT ──────────────────────────────────────────────────────────

def report(run_dir):
    """Assemble the run summary from the shared state, write run_summary.json,
    return it."""
    state = _load_state(run_dir)
    ep = state.get("eval_promote") or {}
    decision = ep.get("decision") or {}
    summary = {
        "domain_config": state.get("config"),
        "namespace": {"tenant": state.get("tenant"), "project": state.get("project")},
        "candidate_version": state.get("candidate_version"),
        "dataset_delta": {
            "new_real_turns": state.get("new_real_turns"),
            "counts": state.get("dataset_counts"),
            "validity": state.get("dataset_validity"),
            "sources": state.get("harvest_sources"),
        },
        "threshold_gate": state.get("threshold_gate"),
        "proceeded": bool(state.get("proceed")),
        "train": state.get("train"),
        "decision": {
            "promote": decision.get("promote"),
            "reason": decision.get("reason"),
            "regressions": decision.get("regressions"),
            "threshold_failures": decision.get("threshold_failures"),
        } if decision else (
            {"promote": False, "reason": "insufficient new data — loop no-op"}
            if not state.get("proceed") else None),
        "per_field": (decision.get("comparison") if decision else None),
        "lineage": {
            "dataset_ref": state.get("candidate_dataset_ref"),
            "candidate_model_ref": (state.get("train") or {}).get("candidate_model_ref"),
            "candidate_eval_ref": ep.get("candidate_eval_ref"),
            "champion": ep.get("champion"),
            "new_champion_release_ref": ep.get("new_champion_release_ref"),
        },
        "generated_unix": int(time.time()),
    }
    _save_state(run_dir, {**state, "run_summary": summary})
    C.write_json(os.path.join(run_dir, "run_summary.json"), summary)
    return summary


# ── one-process driver (smoke / cadence trigger) ─────────────────────────────

def run(config_path, run_dir, *, min_new_real_turns=25, force=False,
        backend="stub", shadow_corpus=None, base_corpus=None, synthetic_topup=0,
        base_url=None, replay_path=None, cadence_days=None, last_run_unix=None,
        constrained_decode=True, champion_eval_ref=None, champion_model_ref=None,
        tenant=None, project=None, augment_teacher=True):
    """Run all five stages in one process.  Honors the threshold gate: when the
    gate says no-op, train + eval_promote short-circuit and REPORT records
    'insufficient new data'."""
    harvest(config_path, run_dir, shadow_corpus=shadow_corpus, base_corpus=base_corpus,
            synthetic_topup=synthetic_topup, base_url=base_url, replay_path=replay_path,
            tenant=tenant, project=project)
    threshold_gate(run_dir, min_new_real_turns=min_new_real_turns, force=force,
                   cadence_days=cadence_days, last_run_unix=last_run_unix)
    train(config_path, run_dir, backend=backend, augment_teacher=augment_teacher,
          tenant=tenant, project=project)
    eval_and_promote(config_path, run_dir, constrained_decode=constrained_decode,
                     champion_eval_ref=champion_eval_ref, champion_model_ref=champion_model_ref,
                     tenant=tenant, project=project)
    return report(run_dir)


# ── CLI ──────────────────────────────────────────────────────────────────────

def _add_common(ap):
    ap.add_argument("--config", required=True)
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--tenant", default=None)
    ap.add_argument("--project", default=None)


def main():
    ap = argparse.ArgumentParser(description="SLM continuous-improvement loop engine")
    sub = ap.add_subparsers(dest="cmd", required=True)

    h = sub.add_parser("harvest"); _add_common(h)
    h.add_argument("--shadow-corpus", default=None)
    h.add_argument("--base-corpus", default=None)
    h.add_argument("--synthetic-topup", type=int, default=0)
    h.add_argument("--base-url", default=None)
    h.add_argument("--replay-path", default=None)
    h.add_argument("--candidate-version", default=None)
    h.add_argument("--use-teacher", action="store_true")

    g = sub.add_parser("gate"); _add_common(g)
    g.add_argument("--min-new-real-turns", type=int, required=True)
    g.add_argument("--force", action="store_true")
    g.add_argument("--cadence-days", type=float, default=None)
    g.add_argument("--last-run-unix", type=float, default=None)

    tr = sub.add_parser("train"); _add_common(tr)
    tr.add_argument("--backend", default="stub", choices=["stub", "mlx", "peft"])
    tr.add_argument("--no-augment-teacher", action="store_true")

    ep = sub.add_parser("eval-promote"); _add_common(ep)
    ep.add_argument("--champion-eval-ref", default=None)
    ep.add_argument("--champion-model-ref", default=None)
    ep.add_argument("--no-constrained-decode", action="store_true")
    ep.add_argument("--no-promote", action="store_true")

    rp = sub.add_parser("report"); _add_common(rp)

    rn = sub.add_parser("run"); _add_common(rn)
    rn.add_argument("--min-new-real-turns", type=int, default=25)
    rn.add_argument("--force", action="store_true")
    rn.add_argument("--backend", default="stub", choices=["stub", "mlx", "peft"])
    rn.add_argument("--shadow-corpus", default=None)
    rn.add_argument("--base-corpus", default=None)
    rn.add_argument("--synthetic-topup", type=int, default=0)
    rn.add_argument("--base-url", default=None)
    rn.add_argument("--replay-path", default=None)
    rn.add_argument("--cadence-days", type=float, default=None)
    rn.add_argument("--last-run-unix", type=float, default=None)
    rn.add_argument("--champion-eval-ref", default=None)
    rn.add_argument("--champion-model-ref", default=None)
    rn.add_argument("--no-constrained-decode", action="store_true")

    args = ap.parse_args()
    if args.cmd == "harvest":
        st = harvest(args.config, args.run_dir, shadow_corpus=args.shadow_corpus,
                     base_corpus=args.base_corpus, synthetic_topup=args.synthetic_topup,
                     base_url=args.base_url, replay_path=args.replay_path,
                     candidate_version=args.candidate_version, tenant=args.tenant,
                     project=args.project, use_teacher=args.use_teacher)
        print("=== HARVEST ===")
        print("candidate dataset:", st.get("candidate_dataset_ref"), "(", st.get("candidate_version"), ")")
        print("new_real_turns:", st.get("new_real_turns"))
        print("counts:", json.dumps(st.get("dataset_counts")))
        print("validity:", json.dumps(st.get("dataset_validity")))
    elif args.cmd == "gate":
        st = threshold_gate(args.run_dir, min_new_real_turns=args.min_new_real_turns,
                            force=args.force, cadence_days=args.cadence_days,
                            last_run_unix=args.last_run_unix)
        print("=== THRESHOLD GATE ===")
        print(json.dumps(st["threshold_gate"], indent=2))
    elif args.cmd == "train":
        st = train(args.config, args.run_dir, backend=args.backend,
                   augment_teacher=not args.no_augment_teacher,
                   tenant=args.tenant, project=args.project)
        print("=== TRAIN ===")
        print(json.dumps(st.get("train"), indent=2))
    elif args.cmd == "eval-promote":
        st = eval_and_promote(args.config, args.run_dir,
                              constrained_decode=not args.no_constrained_decode,
                              champion_eval_ref=args.champion_eval_ref,
                              champion_model_ref=args.champion_model_ref,
                              tenant=args.tenant, project=args.project,
                              do_promote=not args.no_promote)
        ep = st.get("eval_promote", {})
        print("=== EVAL + PROMOTION GATE ===")
        print("promoted:", ep.get("promoted"), "| reason:", (ep.get("decision") or {}).get("reason"))
        print(json.dumps(ep.get("decision"), indent=2))
    elif args.cmd == "report":
        summary = report(args.run_dir)
        print("=== RUN SUMMARY ===")
        print(json.dumps(summary, indent=2))
    elif args.cmd == "run":
        summary = run(args.config, args.run_dir, min_new_real_turns=args.min_new_real_turns,
                      force=args.force, backend=args.backend, shadow_corpus=args.shadow_corpus,
                      base_corpus=args.base_corpus, synthetic_topup=args.synthetic_topup,
                      base_url=args.base_url, replay_path=args.replay_path,
                      cadence_days=args.cadence_days, last_run_unix=args.last_run_unix,
                      constrained_decode=not args.no_constrained_decode,
                      champion_eval_ref=args.champion_eval_ref,
                      champion_model_ref=args.champion_model_ref,
                      tenant=args.tenant, project=args.project)
        print("=== RUN SUMMARY ===")
        print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
