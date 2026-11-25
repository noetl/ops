#!/usr/bin/env python3
"""Latency bench report (noetl/ai-meta#557).

Reads a run directory written by bench.sh (one `<execution_id>.json` per
execution = the body of `GET /api/executions/{id}`, plus `children/` for awaited
child executions and `metrics-{before,after}-*.txt` scrapes) and prints, per
transition, p50 / p95 / mean / n.

Per step `s` with predecessor `p` (the step whose completion drove `s`):

  drive    step.enter(s)        - command.completed(p)   server got p's completion ->
                                                         drive ran -> s entered
                                                         (today: hand-off #1, the
                                                         __orchestrate__ round trip
                                                         through the system pool)
  issue    command.issued(s)    - step.enter(s)
  pickup   command.claimed(s)   - command.issued(s)      hand-off #2: feed -> claim
  start    command.started(s)   - command.claimed(s)
  tool     call.done(s)         - command.started(s)     the step's own work
  report   command.completed(s) - call.done(s)
  step     command.completed(s) - command.completed(p)   wall per step
  overhead step - tool                                   orchestration per step

Per execution: wall (playbook_started -> playbook.completed), first-pickup
(playbook_started -> first command.claimed), tail (last command.completed ->
playbook.completed), steps.

Awaited hops (`kind: playbook` with return_result), per hop step h and its child c:
  hop.spawn   playbook_started(c)  - command.started(h)
  hop.child   playbook.completed(c) - playbook_started(c)
  hop.notice  call.done(h)         - playbook.completed(c)  how long the parent
                                                           took to SEE the child finish
                                                           (today: the poll interval)
  hop.total   call.done(h)         - command.started(h)

All timestamps are `created_at` of the events. Worker events are stamped by the
worker, server events by the server; in kind they share one node clock.

Usage:
  report.py RUN_DIR                    # one arm
  report.py RUN_DIR_A RUN_DIR_B        # before/after, with deltas
  report.py --json RUN_DIR             # machine-readable
"""
import json
import os
import re
import statistics
import sys
from datetime import datetime

SEGMENTS = ["drive", "issue", "pickup", "start", "tool", "report", "step", "overhead"]
EXEC_KEYS = ["wall", "first_pickup", "tail", "steps"]
HOP_KEYS = ["hop.spawn", "hop.child", "hop.notice", "hop.total"]


def ts(s):
    # 2026-11-14T05:05:39.875073Z  (variable fractional digits)
    s = s.replace("Z", "+00:00")
    m = re.match(r"(.*\.)(\d+)(\+.*)", s)
    if m:
        s = m.group(1) + m.group(2)[:6].ljust(6, "0") + m.group(3)
    return datetime.fromisoformat(s).timestamp()


def pct(xs, p):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def first(evs, etype, node):
    c = [e for e in evs if e["event_type"] == etype and e.get("node_name") == node]
    return min((ts(e["created_at"]) for e in c), default=None)


def last(evs, etype, node=None):
    c = [e for e in evs if e["event_type"] == etype and (node is None or e.get("node_name") == node)]
    return max((ts(e["created_at"]) for e in c), default=None)


def child_id_of(evs, step):
    """The child execution a `kind: playbook` step spawned (from its call.done)."""
    for e in evs:
        if e["event_type"] == "call.done" and e.get("node_name") == step:
            blob = json.dumps(e.get("result")) + json.dumps(e.get("meta") or {})
            m = re.search(r'"child_execution_id"\s*:\s*"?(\d{12,})', blob) or re.search(
                r'"execution_id"\s*:\s*"?(\d{12,})', blob)
            if m:
                return m.group(1)
    return None


def analyse_exec(doc, children):
    evs = doc.get("events") or []
    out = {k: [] for k in SEGMENTS + HOP_KEYS}
    ex = {}
    started = last(evs, "playbook_started")
    done = last(evs, "playbook.completed") or last(evs, "playbook.failed")
    if started is None or done is None:
        return None, None, out
    ex["wall"] = done - started
    claims = [ts(e["created_at"]) for e in evs if e["event_type"] == "command.claimed"]
    ex["first_pickup"] = (min(claims) - started) if claims else float("nan")
    completes = [(ts(e["created_at"]), e.get("node_name")) for e in evs if e["event_type"] == "command.completed"]
    ex["tail"] = done - max(t for t, _ in completes) if completes else float("nan")
    ex["steps"] = len({n for _, n in completes})

    # Order steps by their command.issued; predecessor = the step completed most
    # recently before this step's step.enter (sequential chains: the previous one).
    issued = sorted((ts(e["created_at"]), e["node_name"]) for e in evs if e["event_type"] == "command.issued")
    seen = set()
    order = []
    for t, n in issued:
        if n not in seen:
            seen.add(n)
            order.append(n)
    for i, s in enumerate(order):
        iss = first(evs, "command.issued", s)
        clm = first(evs, "command.claimed", s)
        sta = first(evs, "command.started", s)
        cd = first(evs, "call.done", s)
        cmp_ = first(evs, "command.completed", s)
        ent = first(evs, "step.enter", s)
        if None not in (iss, clm):
            out["pickup"].append(clm - iss)
        if None not in (clm, sta):
            out["start"].append(sta - clm)
        if None not in (sta, cd):
            out["tool"].append(cd - sta)
        if None not in (cd, cmp_):
            out["report"].append(cmp_ - cd)
        if i == 0:
            continue
        prev_done = [t for t, _ in completes if t <= (ent or iss)]
        if not prev_done:
            continue
        pd = max(prev_done)
        if ent is not None:
            out["drive"].append(ent - pd)
            out["issue"].append(iss - ent)
        else:
            out["drive"].append(iss - pd)
        if cmp_ is not None:
            out["step"].append(cmp_ - pd)
            if None not in (sta, cd):
                out["overhead"].append((cmp_ - pd) - (cd - sta))
        # awaited child hop
        cid = child_id_of(evs, s)
        if cid and cid in children:
            cevs = children[cid].get("events") or []
            cst = last(cevs, "playbook_started")
            cdone = last(cevs, "playbook.completed") or last(cevs, "playbook.failed")
            if None not in (sta, cst, cdone, cd):
                out["hop.spawn"].append(cst - sta)
                out["hop.child"].append(cdone - cst)
                out["hop.notice"].append(cd - cdone)
                out["hop.total"].append(cd - sta)
    # the first step's hop too (h1 is order[1] when start is a noop) handled above
    return ex, evs, out


METRIC_RE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([0-9.eE+-]+|NaN|\+Inf)$')


def parse_metrics(path):
    vals = {}
    try:
        with open(path) as f:
            for line in f:
                m = METRIC_RE.match(line.strip())
                if m:
                    vals[(m.group(1), m.group(2) or "")] = float(m.group(3))
    except FileNotFoundError:
        pass
    return vals


def metric_means(run_dir):
    """Mean of each *_seconds histogram series over the run (after - before)."""
    res = {}
    for f in os.listdir(run_dir):
        if not f.startswith("metrics-before-"):
            continue
        src = f[len("metrics-before-"):-4]
        b = parse_metrics(os.path.join(run_dir, f))
        a = parse_metrics(os.path.join(run_dir, "metrics-after-" + src + ".txt"))
        for (name, labels), v in a.items():
            if not name.endswith("_seconds_sum"):
                continue
            base = name[: -len("_sum")]
            if not any(k in base for k in ("pickup_phase", "ingest_phase", "state_builder", "orchestrate", "claim")):
                continue
            cnt = a.get((base + "_count", labels), 0) - b.get((base + "_count", labels), 0)
            s = v - b.get((name, labels), 0)
            if cnt > 0:
                key = f"{src}:{base}{labels}"
                res[key] = (s / cnt, int(cnt))
    return res


def load_run(run_dir):
    execs = {}
    children = {}
    cdir = os.path.join(run_dir, "children")
    if os.path.isdir(cdir):
        for f in os.listdir(cdir):
            if f.endswith(".json"):
                children[f[:-5]] = json.load(open(os.path.join(cdir, f)))
    for f in sorted(os.listdir(run_dir)):
        if f.endswith(".json") and f[:-5].isdigit():
            execs[f[:-5]] = json.load(open(os.path.join(run_dir, f)))
    seg = {k: [] for k in SEGMENTS + HOP_KEYS}
    exs = {k: [] for k in EXEC_KEYS}
    statuses = {}
    for eid, doc in execs.items():
        ex, _, out = analyse_exec(doc, children)
        st = (doc.get("status") or "?").upper()
        statuses[st] = statuses.get(st, 0) + 1
        if ex is None:
            continue
        for k in EXEC_KEYS:
            exs[k].append(ex[k])
        for k, v in out.items():
            seg[k].extend(v)
    meta = {}
    mp = os.path.join(run_dir, "run.json")
    if os.path.exists(mp):
        meta = json.load(open(mp))
    return {"meta": meta, "statuses": statuses, "exec": exs, "seg": seg, "metrics": metric_means(run_dir)}


def summ(xs, scale=1000.0):
    xs = [x for x in xs if x == x]
    if not xs:
        return None
    return {"n": len(xs), "p50": pct(xs, 0.5) * scale, "p95": pct(xs, 0.95) * scale,
            "mean": statistics.fmean(xs) * scale}


def fmt(s, unit="ms"):
    if s is None:
        return "—"
    return f"p50 {s['p50']:8.1f}  p95 {s['p95']:8.1f}  mean {s['mean']:8.1f} {unit}  n={s['n']}"


def print_run(r, label=""):
    m = r["meta"]
    print(f"== {label} {m.get('playbook', '')}  server={m.get('server_image', '?')}  worker={m.get('worker_image', '?')}")
    if m.get("flags"):
        print(f"   flags: {m['flags']}")
    print(f"   runs: {r['statuses']}  concurrency={m.get('concurrency', 1)}  host load (1m) {m.get('host_load_1m', '?')}")
    for k in EXEC_KEYS:
        if k == "steps":
            xs = r["exec"][k]
            print(f"   {'steps':12s} {sorted(set(xs))}")
            continue
        print(f"   exec.{k:7s} {fmt(summ(r['exec'][k]))}")
    for k in SEGMENTS + HOP_KEYS:
        s = summ(r["seg"][k])
        if s:
            print(f"   {k:12s} {fmt(s)}")
    if r["metrics"]:
        print("   metrics (mean over the run, from histogram deltas):")
        for k, (mean, cnt) in sorted(r["metrics"].items()):
            print(f"     {k:100s} {mean * 1000:8.2f} ms  n={cnt}")


def compare(a, b):
    print_run(a, "BEFORE")
    print()
    print_run(b, "AFTER")
    print()
    print("== delta (after - before), ms")
    rows = [("exec." + k, a["exec"][k], b["exec"][k]) for k in ("wall", "first_pickup", "tail")]
    rows += [(k, a["seg"][k], b["seg"][k]) for k in SEGMENTS + HOP_KEYS]
    for name, xa, xb in rows:
        sa, sb = summ(xa), summ(xb)
        if not sa or not sb:
            continue
        print(f"   {name:16s} p50 {sb['p50'] - sa['p50']:+9.1f} ({sa['p50']:.1f} -> {sb['p50']:.1f})   "
              f"p95 {sb['p95'] - sa['p95']:+9.1f} ({sa['p95']:.1f} -> {sb['p95']:.1f})")


def main(argv):
    as_json = False
    if argv and argv[0] == "--json":
        as_json = True
        argv = argv[1:]
    if not argv:
        print(__doc__)
        return 2
    runs = [load_run(d) for d in argv]
    if as_json:
        out = []
        for r in runs:
            out.append({"meta": r["meta"], "statuses": r["statuses"],
                        "exec": {k: summ(v) for k, v in r["exec"].items() if k != "steps"},
                        "seg": {k: summ(v) for k, v in r["seg"].items()},
                        "metrics": {k: {"mean_ms": v[0] * 1000, "n": v[1]} for k, v in r["metrics"].items()}})
        print(json.dumps(out, indent=2))
        return 0
    if len(runs) == 1:
        print_run(runs[0])
    else:
        compare(runs[0], runs[1])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
