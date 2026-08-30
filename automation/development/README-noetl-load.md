# `noetl_load.py` — synthetic execution load

Rate-controlled `POST /api/execute` traffic, so the paths that only exist under
load can actually be observed. Standard library only; no install step.

## Why it exists

Several behaviours cannot be validated on an idle cluster, because the series
that would show them are **absent until something drives traffic**:

| what it exercises | what to watch |
| :-- | :-- |
| D1 age-seal window bound (~5s) | `ehdb_l0_unreplicated_age_seconds` — should stay bounded near `NOETL_EHDB_SEAL_MAX_AGE_MS`, not grow with the run |
| catalog read-serve decision | `noetl_catalog_read_served_total{served_by=...}` |
| cross-store parity comparator | `noetl_ehdb_crossstore_events_compared_total`, `..._divergence_total` |

## Safety — the version gate

`--expect-version` is **required and has no default**. The tool reads
`GET /api/health`, prints the identity, and **aborts** if the version differs
from the one you declared.

This is not ceremony. `kubectl port-forward` **fails open**: if another process
already holds your local port, `http://localhost:8082` silently resolves to
whatever cluster owns that forward, and `--context` does not protect a plain
HTTP client. A session has already created a real production execution that
way. Declaring the version turns a silent misroute into a refusal.

Verified both directions:

```
--expect-version 3.98.0  ->  ABORT, exit 1   (kind reports 3.91.1)
--expect-version 3.91.1  ->  proceeds, exit 0
```

## Absent is not zero

Prometheus prunes metric families with no children, so a labelled series does
not appear until something increments it. A missing metric and a healthy zero
look identical to a naive scraper. The report separates them explicitly:

```
noetl_ehdb_crossstore_events_compared_total{tier="eventlog"}  0 -> 0   delta +0
ABSENT (not zero — the family never appeared):
  ehdb_l0_unreplicated_age_seconds
```

## Usage

```bash
# always dry-run first: pre-flight only, sends nothing
./noetl_load.py --url http://localhost:18099 --expect-version <v> --dry-run

# then the real run
./noetl_load.py \
  --url http://localhost:18099 \
  --expect-version <v> \
  --playbook tests/catalog-log/clean \
  --rate 2 --duration 60 --concurrency 4 \
  --metrics server=http://localhost:18099/metrics \
  --metrics writer=http://localhost:19106/metrics
```

Stop early with a single **Ctrl-C**: it stops submitting, drains in-flight
requests, prints the summary, and exits 0. Verified — a SIGINT at t+8s of a
300s plan finished all 40 submitted requests with none left hanging.

## Validated on kind (2026-08-30)

Against `kind-noetl`, server 3.91.1, playbook `tests/catalog-log/clean`
(a benign two-step python playbook already in the catalog):

```
submitted   40   (2.00/s actual)
responses   {'200': 40}
latency     p50=18ms  p95=31ms  max=49ms
0 non-2xx/error response(s)
```

⚠ **What kind could NOT validate.** `ehdb_l0_unreplicated_age_seconds` is
**absent** on kind — the deployed worker image predates the durability-window
metric. So the age-seal observation is unproven here; the tool reports it as
ABSENT rather than pretending it is 0. Watching that series needs a worker
build carrying the metric.

## Not run against production

Deliberately. Fire it only on explicit instruction, and expect
`--expect-version` to name the production server version at that moment.
