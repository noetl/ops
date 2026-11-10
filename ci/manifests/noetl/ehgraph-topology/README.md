# Topology-writer standup: embedded ehgraph in the prod server

**Status: staged, NOT applied.** This turns on the embedded `noetl-cluster` ehgraph inside
noetl-server (ehgraph decision E4) and the instance registry's topology writer (build plan
item 9, `NOETL_EHGRAPH_TOPOLOGY_WRITER`), which projects registered instances, their peers,
pools and offered playbooks into the graph's `topology` namespace.

Kind result (`kind_validate.sh`, server 3.156.0-arm64, the same scripts): **11/11**. The run
covered phase a, phase b, a trusted instance's node read back from the graph, a stranger
refused with 403, rollback b (the graph keeps serving), rollback a with purge, and the
deployment restored as found.

## What changes in prod

| piece | value |
|---|---|
| GSM `noetl-ehgraph-config` | `config.template.toml` rendered with a fresh token (never committed, never printed) |
| GSM `noetl-ehgraph-topology-token` | the same token, alone, for the writer |
| IAM | `roles/secretmanager.secretAccessor` for `noetl-result-tier@` (the server KSA's GSA), on both |
| SecretProviderClass `noetl/noetl-server-secrets` | +2 entries → `/var/secrets/sm/ehgraph-config.toml`, `/var/secrets/sm/ehgraph-topology-token` |
| sts `noetl-server-rust-embedded` phase a | `NOETL_EHGRAPH_EMBEDDED=true`, `NOETL_EHGRAPH_CONFIG=/var/secrets/sm/ehgraph-config.toml`, `NOETL_EHGRAPH_HOST_REPLICAS=1`, `NOETL_EHGRAPH_HOST_ORDINAL=0` |
| sts phase b | `NOETL_EHGRAPH_TOPOLOGY_WRITER=true`, `NOETL_EHGRAPH_TOPOLOGY_TOKEN_FILE=/var/secrets/sm/ehgraph-topology-token` |
| data | `/data/ehgraph/{data,backup}` on the existing 10Gi `ehdb-embedded` PVC (8% used on 2026-11-10) |

The image is unchanged. Each phase is one restart of the single server replica, which means a
short API outage, as with any server roll. Memory: the graph is capped at 10% of the 1Gi limit
(the server used 130Mi on 2026-11-10).

The topology writer only has something to write once an instance can register. Until
`NOETL_INSTANCE_TRUSTED_IDS` is set (see `../interop-config/`), prod admits nobody, so phase b
is live but writes nothing.

## Apply (one approval, about 10 minutes, attended)

```bash
cd ops
# 0. preflight: no standalone ehgraph-noetl-cluster may exist (README in noetl/ehgraph deploy/instances)
kubectl --context noetl-prod get sts,deploy,svc -A | grep -i ehgraph   # expect nothing
# 1. secrets (GSM + IAM). Idempotent; never rotates an existing token.
CONFIRM=yes ci/manifests/noetl/ehgraph-topology/stage-secrets.sh
# 2. phase a: SPC entries + embedded ehgraph; smoked; rolls itself back on a failed smoke
CONFIRM=yes ci/manifests/noetl/ehgraph-topology/apply.sh a
# 3. phase b: topology writer; smoked; rolls itself back on a failed smoke
CONFIRM=yes ci/manifests/noetl/ehgraph-topology/apply.sh b
```

`apply.sh` saves the StatefulSet and SecretProviderClass JSON to `.snap-<ts>/` before
changing anything, and prints the image pin.

## Smoke (`smoke.sh a|b`, run by apply.sh)

- `/ehgraph/noetl-cluster/healthz` reports `state: serving`, `mode: embedded`.
- `graph.node` in `topology` with the grant is authorized. With no token, or a wrong one, it
  returns `UNAUTHORIZED`. ehgraph answers `initialize` and `tools/list` without a token by
  design and enforces the grant on every `tools/call`.
- Phase b: no `NOETL_EHGRAPH_TOPOLOGY_WRITER=true but …` error in the server log.
- App smokes (`ci/prod-smoke/`): server health; ranch `shastaranch/concierge/turn` with
  `room_cards`; travel `muno/playbooks/itinerary-planner`; a guest concierge turn through the
  public gateway.

## Rollback

```bash
CONFIRM=yes ci/manifests/noetl/ehgraph-topology/rollback.sh b              # writer off, graph stays
CONFIRM=yes ci/manifests/noetl/ehgraph-topology/rollback.sh a              # graph off too (env as before)
CONFIRM=yes PURGE=yes ci/manifests/noetl/ehgraph-topology/rollback.sh a    # and delete /data/ehgraph
```

Each is one restart, followed by a smoke. The SecretProviderClass entries and the GSM secrets
stay; mounted files that nothing reads change nothing. To abandon the standup completely:

```bash
kubectl --context noetl-prod -n noetl replace -f ci/manifests/noetl/ehgraph-topology/.snap-<ts>/spc.json
gcloud secrets delete noetl-ehgraph-config --project shastaratech-noetl-prod
gcloud secrets delete noetl-ehgraph-topology-token --project shastaratech-noetl-prod
```

⚠ An embedded graph rolls back WITH the server image. `compaction = false` keeps the manifests
at format 1, so every server build since the ehgraph pin can reopen the graph (ehgraph E9).

## Open decisions (not blockers)

- **Backup target.** `backup_prefix` is on the same PVC, so a lost volume loses the graph. The
  graph is soft state: every live instance re-registers within one TTL and rebuilds it. A
  `gs://` prefix with `auth = "metadata"` is the follow-up once a bucket is named.
- **Rotating the token.** Add a new version to both secrets together, then restart the server.
  `stage-secrets.sh` deliberately never rotates.
