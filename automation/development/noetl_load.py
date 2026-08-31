#!/usr/bin/env python3
"""Synthetic NoETL load generator — rate-controlled playbook executions.

Drives POST /api/execute at a configured rate for a configured duration, so the
traffic-dependent paths that cannot be observed on an idle cluster actually get
exercised: the D1 age-seal window, the catalog read-serve counters, and the
cross-store parity comparator.

Standard library only.  No install step.

SAFETY — read this before pointing it anywhere
----------------------------------------------
`--expect-version` is REQUIRED and has no default.  Before sending a single
request the tool reads GET /api/health, prints the identity it found, and
ABORTS if the reported version is not the one you declared.

That is not ceremony.  A `kubectl port-forward` FAILS OPEN: if some other
process already holds the local port, your `http://localhost:8082` silently
resolves to whatever cluster owns that forward, and `--context` does not
protect a plain HTTP client.  A session has already created a real production
execution that way while believing it was talking to kind.  Declaring the
version you expect turns that silent misroute into a refusal.

Nothing is sent in --dry-run.

Usage
-----
    # kind
    ./noetl_load.py --url http://localhost:8082 --expect-version 3.91.1 \
        --playbook test/simple_loop --rate 2 --duration 60 \
        --metrics writer=http://localhost:9106/metrics

    # stop early: Ctrl-C once.  In-flight requests drain, then the summary prints.
"""
from __future__ import annotations

import argparse
import json
import re
import signal
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

# Series worth watching while load runs.  Absent is NOT zero: prometheus prunes
# metric families with no children, so a labelled series does not appear until
# something increments it.  The report distinguishes the two, because a metric
# that is missing because the binary predates it looks exactly like a healthy
# zero otherwise.
WATCH = [
    "ehdb_l0_unreplicated_age_seconds",     # the D1 durability window, per shard
    "ehdb_l0_unreplicated_records",
    "noetl_catalog_read_served_total",      # catalog read-serve decision
    "noetl_catalog_relation_read_total",
    "noetl_ehdb_crossstore_events_compared_total",
    "noetl_ehdb_crossstore_divergence_total",
]

_stop = threading.Event()


def _get(url: str, timeout: float = 10.0) -> str:
    req = urllib.request.Request(url, headers={"accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def _post(url: str, body: dict, timeout: float = 30.0) -> tuple[int, str]:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url, data=data, headers={"content-type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")[:400]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:400]


def scrape(url: str) -> dict[str, list[tuple[str, float]]]:
    """Return {metric_name: [(labels, value), ...]} for the watched series."""
    out: dict[str, list[tuple[str, float]]] = {}
    try:
        text = _get(url, timeout=8)
    except Exception as e:                      # noqa: BLE001 - report, never raise
        return {"__error__": [(str(e), 0.0)]}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(.+)$", line)
        if not m:
            continue
        name, labels, val = m.group(1), m.group(2) or "", m.group(3)
        if name not in WATCH:
            continue
        try:
            out.setdefault(name, []).append((labels, float(val)))
        except ValueError:
            pass
    return out


def preflight(base: str, expect: str, allow_prod: bool) -> dict:
    """Prove what we are talking to BEFORE sending load.  Aborts on mismatch."""
    url = base.rstrip("/") + "/api/health"
    print(f"  pre-flight  GET {url}")
    try:
        health = json.loads(_get(url, timeout=8))
    except Exception as e:                      # noqa: BLE001
        sys.exit(f"  ABORT: cannot read {url}: {e}")

    got = str(health.get("version", "<none>"))
    print(f"  identity    version={got} status={health.get('status')} "
          f"db={health.get('database')} uptime={health.get('uptime_seconds')}s")

    if got != expect:
        sys.exit(
            f"  ABORT: server reports version {got!r}, you declared {expect!r}.\n"
            f"         Refusing to send load to a target you did not expect.\n"
            f"         A port-forward can silently point localhost at another\n"
            f"         cluster; this check is what catches that."
        )
    if health.get("uptime_seconds", 0) > 60 * 60 * 24 * 7 and not allow_prod:
        print("  note        uptime > 7d — long-lived cluster; make sure this is intended")
    print("  ✅ identity matches; proceeding")
    return health


def render_metrics(label: str, before: dict, after: dict) -> None:
    print(f"\n  metrics [{label}]")
    names = sorted(set(before) | set(after))
    if not names or names == ["__error__"]:
        print("    (endpoint unreachable or exposed none of the watched series)")
        if "__error__" in after:
            print(f"    error: {after['__error__'][0][0]}")
        return
    for n in names:
        if n == "__error__":
            continue
        b = dict(before.get(n, []))
        a = dict(after.get(n, []))
        for lbl in sorted(set(b) | set(a)):
            bv, av = b.get(lbl), a.get(lbl)
            if bv is None and av is not None:
                state = f"ABSENT -> {av:g}   (series appeared)"
            elif av is None:
                state = "absent throughout"
            else:
                d = av - bv
                state = f"{bv:g} -> {av:g}   delta {d:+g}"
            print(f"    {n}{lbl}  {state}")
    missing = [n for n in WATCH if n not in after]
    if missing:
        print("    ABSENT (not zero — the family never appeared):")
        for n in missing:
            print(f"      {n}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True, help="NoETL server base URL")
    ap.add_argument("--expect-version", required=True,
                    help="REQUIRED. Version /api/health must report, or the run aborts.")
    ap.add_argument("--playbook", default="test/simple_loop", help="catalog path to execute")
    ap.add_argument("--rate", type=float, default=1.0, help="executions per second")
    ap.add_argument("--duration", type=float, default=60.0, help="seconds to run")
    ap.add_argument("--concurrency", type=int, default=8, help="max in-flight requests")
    ap.add_argument("--metrics", action="append", default=[],
                    metavar="NAME=URL", help="metrics endpoint to sample (repeatable)")
    ap.add_argument("--sample-every", type=float, default=10.0,
                    help="seconds between progress lines")
    ap.add_argument("--payload", default="{}", help="JSON payload merged into each execution")
    ap.add_argument("--allow-prod", action="store_true",
                    help="suppress the long-uptime warning; does NOT skip the version gate")
    ap.add_argument("--dry-run", action="store_true", help="pre-flight only, send nothing")
    a = ap.parse_args()

    try:
        payload = json.loads(a.payload)
    except json.JSONDecodeError as e:
        return int(bool(sys.stderr.write(f"--payload is not valid JSON: {e}\n"))) or 2

    endpoints = {}
    for spec in a.metrics:
        if "=" not in spec:
            return int(bool(sys.stderr.write(f"--metrics wants NAME=URL, got {spec!r}\n"))) or 2
        k, v = spec.split("=", 1)
        endpoints[k] = v

    total = int(a.rate * a.duration)
    print("NoETL synthetic load")
    print(f"  target      {a.url}")
    print(f"  playbook    {a.playbook}")
    print(f"  plan        {a.rate}/s for {a.duration}s  =  ~{total} executions, "
          f"concurrency {a.concurrency}")
    for k, v in endpoints.items():
        print(f"  metrics     {k} -> {v}")
    print()

    preflight(a.url, a.expect_version, a.allow_prod)

    if a.dry_run:
        print("\n  --dry-run: nothing sent.")
        return 0

    before = {k: scrape(v) for k, v in endpoints.items()}

    exec_url = a.url.rstrip("/") + "/api/execute"
    body = {"path": a.playbook, "payload": payload}
    codes: Counter[str] = Counter()
    lat: list[float] = []
    lock = threading.Lock()

    def fire(_i: int) -> None:
        if _stop.is_set():
            return
        t0 = time.monotonic()
        try:
            code, _txt = _post(exec_url, body)
            key = str(code)
        except Exception as e:                  # noqa: BLE001
            key = type(e).__name__
        dt = time.monotonic() - t0
        with lock:
            codes[key] += 1
            lat.append(dt)

    def on_sig(_s, _f):
        if not _stop.is_set():
            print("\n  stop requested — draining in-flight requests…")
            _stop.set()

    signal.signal(signal.SIGINT, on_sig)
    signal.signal(signal.SIGTERM, on_sig)

    started = time.monotonic()
    deadline = started + a.duration
    interval = 1.0 / a.rate if a.rate > 0 else 0.0
    nxt_report = started + a.sample_every
    sent = 0

    print(f"\n  running — Ctrl-C to stop cleanly\n")
    with ThreadPoolExecutor(max_workers=a.concurrency) as pool:
        while not _stop.is_set() and time.monotonic() < deadline:
            pool.submit(fire, sent)
            sent += 1
            now = time.monotonic()
            if now >= nxt_report:
                with lock:
                    ok = codes.get("200", 0) + codes.get("201", 0)
                    n = sum(codes.values())
                print(f"    t+{now - started:5.1f}s  submitted={sent:5d}  "
                      f"completed={n:5d}  ok={ok:5d}  "
                      f"p50={statistics.median(lat) * 1000:6.0f}ms" if lat else
                      f"    t+{now - started:5.1f}s  submitted={sent}")
                nxt_report = now + a.sample_every
            target = started + sent * interval
            slp = target - time.monotonic()
            if slp > 0:
                _stop.wait(slp)
        # ThreadPoolExecutor.__exit__ waits for in-flight work — that IS the drain.

    elapsed = time.monotonic() - started
    after = {k: scrape(v) for k, v in endpoints.items()}

    print(f"\n  === summary ===")
    print(f"  elapsed     {elapsed:.1f}s")
    print(f"  submitted   {sent}   ({sent / elapsed:.2f}/s actual)")
    print(f"  responses   {dict(codes)}")
    if lat:
        s = sorted(lat)
        print(f"  latency     p50={statistics.median(s)*1000:.0f}ms  "
              f"p95={s[int(len(s)*0.95)-1]*1000:.0f}ms  max={s[-1]*1000:.0f}ms")
    for k in endpoints:
        render_metrics(k, before.get(k, {}), after.get(k, {}))

    bad = sum(v for kk, v in codes.items() if not kk.startswith("2"))
    print(f"\n  {'⚠ ' if bad else ''}{bad} non-2xx/error response(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
