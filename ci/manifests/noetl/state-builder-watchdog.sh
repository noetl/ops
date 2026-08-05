#!/bin/sh
# state-builder watchdog (noetl/ai-meta#163) — deployable form.
#
# Same detect → cooldown → flap-stop → rollout-restart logic as the NoETL
# playbook playbooks/system/state_builder_watchdog.yaml, written as a
# standalone POSIX-sh script so the CronJob can run it on a plain
# `bitnami/kubectl` image (which has kubectl + sh + wget) — no noetl-cli
# image needed.  KEEP THE TWO IN SYNC.  Restart-only; bounded by cooldown
# + flap-stop; never deletes/scales/touches data.
#
# Config via env (CronJob sets these):
#   NS, DEPLOY, METRICS_URL, LIVEZ_URL, SAMPLES, SAMPLE_INTERVAL_SECONDS,
#   COOLDOWN_SECONDS, FLAP_WINDOW_SECONDS, MAX_ATTEMPTS,
#   FORCE_UNHEALTHY (test), DRY_RUN (test).
set -u

NS="${NS:-noetl}"
DEPLOY="${DEPLOY:-noetl-worker-system-pool}"
METRICS_URL="${METRICS_URL:-http://noetl-worker-system-pool-metrics.noetl.svc.cluster.local:9090/metrics}"
LIVEZ_URL="${LIVEZ_URL:-http://noetl-worker-system-pool-metrics.noetl.svc.cluster.local:9090/livez}"
SAMPLES="${SAMPLES:-3}"
INTERVAL="${SAMPLE_INTERVAL_SECONDS:-2}"
COOLDOWN="${COOLDOWN_SECONDS:-600}"
FLAP_WINDOW="${FLAP_WINDOW_SECONDS:-3600}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
FORCE_UNHEALTHY="${FORCE_UNHEALTHY:-false}"
DRY_RUN="${DRY_RUN:-false}"

# In-cluster: the pod SA + default context.  KC has no --context.
KC="kubectl -n $NS"
NOW=$(date +%s)
log() { echo "[watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# HTTP via curl or wget (whichever the image ships) — body for metrics,
# status code for livez.
if command -v curl >/dev/null 2>&1; then
  http_body() { curl -fsS --max-time 5 "$1" 2>/dev/null; }
  http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null; }
else
  http_body() { wget -qO- -T 5 "$1" 2>/dev/null; }
  http_code() { wget -S -qO /dev/null -T 5 "$1" 2>&1 | awk '/HTTP\//{c=$2} END{print c+0}'; }
fi

log "state-builder watchdog: deploy=$DEPLOY samples=$SAMPLES cooldown=${COOLDOWN}s max_attempts=$MAX_ATTEMPTS force=$FORCE_UNHEALTHY dry_run=$DRY_RUN"

# -------- 1. DETECT (sustained) --------
WEDGED=true
if [ "$FORCE_UNHEALTHY" = "true" ]; then
  log "FORCE_UNHEALTHY=true — bypassing detection (test affordance)"
else
  i=1
  while [ "$i" -le "$SAMPLES" ]; do
    HEALTHY=$(http_body "$METRICS_URL" | awk '/^noetl_worker_state_builder_healthy /{print $2}')
    LIVEZ=$(http_code "$LIVEZ_URL")
    log "probe $i/$SAMPLES: state_builder_healthy='${HEALTHY:-<absent>}' livez=$LIVEZ"
    if [ "$HEALTHY" = "1" ] || [ "$LIVEZ" = "200" ]; then WEDGED=false; break; fi
    if [ -z "$HEALTHY" ] && [ "$LIVEZ" != "503" ]; then
      log "metrics inconclusive (healthy absent, livez=$LIVEZ) — NOT-wedged (StateBuilderAbsent alert covers this)"
      WEDGED=false; break
    fi
    [ "$i" -lt "$SAMPLES" ] && sleep "$INTERVAL"
    i=$((i + 1))
  done
fi

if [ "$WEDGED" != "true" ]; then
  log "DECISION: HEALTHY — no remediation needed."
  exit 0
fi
log "DETECTED: state-builder WEDGED (healthy=0 sustained over $SAMPLES probes)."

# -------- 2. COOLDOWN guard --------
LAST=$($KC get deploy "$DEPLOY" -o jsonpath='{.metadata.annotations.noetl\.io/watchdog-last-remediation}' 2>/dev/null)
LAST=${LAST:-0}
if [ "$LAST" -gt 0 ] 2>/dev/null; then
  AGO=$((NOW - LAST))
  if [ "$AGO" -lt "$COOLDOWN" ]; then
    log "DECISION: COOLDOWN — last remediation ${AGO}s ago < ${COOLDOWN}s; skipping (no restart)."
    exit 0
  fi
fi

# -------- 3. FLAP-STOP guard --------
RAW=$($KC get deploy "$DEPLOY" -o jsonpath='{.metadata.annotations.noetl\.io/watchdog-remediations}' 2>/dev/null)
PRUNED=""; COUNT=0
OLDIFS="$IFS"; IFS=','
for ts in $RAW; do
  case "$ts" in ''|*[!0-9]*) continue ;; esac
  if [ $((NOW - ts)) -lt "$FLAP_WINDOW" ]; then
    PRUNED="${PRUNED:+$PRUNED,}$ts"; COUNT=$((COUNT + 1))
  fi
done
IFS="$OLDIFS"
log "flap window: ${COUNT} remediation(s) in last ${FLAP_WINDOW}s (max ${MAX_ATTEMPTS})"
if [ "$COUNT" -ge "$MAX_ATTEMPTS" ]; then
  log "DECISION: FLAP-STOP — ${COUNT} remediations >= max ${MAX_ATTEMPTS} in window; NOT restarting."
  log "ALERT: state-builder wedge NOT clearing after ${COUNT} rollout restarts — a restart is not fixing it (NATS down / deeper fault). ESCALATE (StateBuilderWedged alert)."
  $KC annotate deploy "$DEPLOY" "noetl.io/watchdog-flap-stopped-at=$NOW" --overwrite >/dev/null 2>&1 || true
  exit 0
fi

# -------- 4. REMEDIATE (restart only) --------
REASON="state_builder wedged: healthy=0 sustained over ${SAMPLES} probes"
if [ "$DRY_RUN" = "true" ]; then
  log "DRY_RUN: would 'rollout restart deploy/$DEPLOY' now (reason: $REASON). No action taken."
  exit 0
fi
log "REMEDIATE: kubectl rollout restart deploy/$DEPLOY (reason: $REASON)"
if ! $KC rollout restart "deployment/$DEPLOY"; then
  log "ERROR: rollout restart failed — leaving for the next tick / human."
  exit 1
fi
NEW_LIST="${PRUNED:+$PRUNED,}$NOW"
$KC annotate deploy "$DEPLOY" \
  "noetl.io/watchdog-last-remediation=$NOW" \
  "noetl.io/watchdog-remediations=$NEW_LIST" \
  "noetl.io/watchdog-last-reason=$REASON" --overwrite >/dev/null 2>&1 || true
$KC rollout status "deployment/$DEPLOY" --timeout=120s || \
  log "WARN: rollout status did not converge in 120s — next tick re-checks."
log "REMEDIATED: rollout restart issued at $NOW. attempts-in-window now $((COUNT + 1)). AUDIT: $REASON"
