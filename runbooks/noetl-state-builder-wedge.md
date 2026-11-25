# Runbook — off-server state-builder wedge

Alerts: `StateBuilderWedged`, `StateBuilderConsumerRecreateStorm`,
`StateBuilderConnectErrors`, `StateBuilderAbsent`
(`ci/manifests/noetl/vmrule-state-builder-wedge.yaml` +
`gmp/rules-state-builder-wedge.yaml`).

Tracks [noetl/ai-meta#163](https://github.com/noetl/ai-meta/issues/163).

## What this protects

The **system-pool worker** drains the `noetl_events` JetStream stream
into a pool-side WAL index (the off-server state-builder). The
off-server orchestrate drive reads that index to compute the next
commands for every execution. If the drain stops serving, the drive
computes `commands=0` and **every off-server drive wedges** — auth
login and the planner included. This is the recurring Muno login
outage (root cause memory
`161-nats-bounce-systempool-statebuilder-wedge`).

A NATS server bounce orphans the drain's JetStream consumer. Three
layers now defend against it:

1. **In-process self-heal** (noetl/worker ≥ v5.48.1): on a sustained
   dead-consumer signal the drain tears down + recreates the consumer
   with backoff. Metric: `noetl_worker_state_builder_consumer_recreate_total{reason="drain_dead"}`.
2. **Liveness backstop**: `/livez` fails after
   `NOETL_STATE_BUILDER_UNHEALTHY_SECS` (default 45s) of being unable to
   serve → Kubernetes restarts the pod. Metric:
   `noetl_worker_state_builder_healthy` (the `/livez` source).
3. **External watchdog** (`system/state_builder_watchdog` via
   `cronjob-state-builder-watchdog.yaml`): independently detects the
   wedge and issues a **bounded** `rollout restart` (cooldown + flap-stop).

The alerts fire when those layers have NOT cleared the condition.

## Quick triage

```bash
ctx=gke_noetl-demo-19700101_us-central1_noetl-cluster
kubectl --context $ctx -n noetl get pods -l app=noetl-worker-system-pool
# the smoking gun — should be ~0 on a healthy pool:
kubectl --context $ctx -n noetl logs deploy/noetl-worker-system-pool --tail=2000 | grep -c '503, None'
# the health gauge (1 healthy / 0 wedged):
kubectl --context $ctx -n noetl exec deploy/noetl-worker-system-pool -- \
  wget -qO- http://localhost:9090/metrics | grep state_builder_healthy
# server view — N=0 forever means wedged:
kubectl --context $ctx -n noetl logs deploy/noetl-server-rust --tail=300 | grep 'applied orchestrate result commands='
```

Creds-free login probe (mirrors the wedged auth drive):

```bash
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -X POST \
  https://<gateway-LB>/api/auth/validate \
  -H 'Content-Type: application/json' \
  -d '{"session_token":"muno-probe-'"$RANDOM"'"}'
# healthy: 200 in ~2s.  wedged: 503 at the 30s auth timeout.
```

## StateBuilderWedged (critical)

`state_builder_healthy == 0` for 2m — the self-heal + liveness restart
have NOT recovered it, so a rollout restart alone is not fixing it.

1. Check NATS: `kubectl --context $ctx -n nats get pods` — is `nats-0`
   healthy / recently restarted? Is JetStream up
   (`nats stream info noetl_events`)?
2. If NATS is down/recovering, fix NATS first; the worker self-heals
   once NATS returns.
3. If NATS is healthy but the pool is still wedged, manual restore (the
   #161 fix): `kubectl --context $ctx -n noetl rollout restart deploy/noetl-worker-system-pool`,
   then re-run the login probe (expect 200 ~2s).
4. Confirm recovery: `503, None` count drops to ~0, `state_builder_healthy`
   back to 1, `commands=` ≥ 1 flowing.

The watchdog auto-restarts but **flap-stops** after `max_attempts`
(default 3/hour) — a sustained alert means the watchdog hit its flap
guard (see `noetl.io/watchdog-flap-stopped-at` annotation on the
deployment). That is the escalation signal: a restart is not the cure.

## StateBuilderConsumerRecreateStorm (warning)

The consumer keeps getting orphaned and self-healed (drive recovers
each time, but NATS/JetStream is flapping). Investigate NATS server
stability (restarts, JetStream storage/health) before it escalates.

## StateBuilderConnectErrors (warning)

The drain cannot reconnect to NATS. Check NATS reachability + NATS
credentials from the system pool
(`NATS_URL`/`NATS_USER`/`NATS_PASSWORD`). The `/livez` backstop will
restart the pod if it stays down past the unhealthy window.

## StateBuilderAbsent (critical)

No `noetl_worker_state_builder_*` metrics are being scraped — the
system pool isn't running or its `/metrics` (:9090) is down. Restore
the deployment; confirm the PodMonitoring scrape.

## Bounds / safety of the auto-remediation

`system/state_builder_watchdog` is **restart-only** and bounded:
cooldown (≤1 restart / `cooldown_seconds`, default 10m), flap-stop
(≤`max_attempts` / `flap_window_seconds`, default 3/hour) → then it
STOPS and this alert pages a human instead of thrashing. It never
deletes, scales, or touches data / result_store / OQ5 / IAM / secrets /
the tail-attach flag. Audit trail: the CronJob pod logs +
`noetl.io/watchdog-*` annotations on the deployment.
