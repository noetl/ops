# Lifecycle-fusion correctness proof (ai-meta#561)

Proves `NOETL_WORKER_FUSE_LIFECYCLE` leaves the event log and final state unchanged,
including multi-tool steps (different runtimes) and conditional jumps.

    ./proof.sh runs/off 5                                   # worker flag absent
    kubectl -n noetl set env deploy/noetl-worker-lat NOETL_WORKER_FUSE_LIFECYCLE=true
    ./proof.sh runs/on 5
    for i in 1 2 3 4 5; do ./canon.py runs/off/fuse_goto-$i.jsonl runs/on/fuse_goto-$i.jsonl; done
    ./orphans.sh runs/on   # steps entered by an orchestrate drive (pre-existing race; compare with off)

`canon.py` normalizes snowflake ids (by first appearance, so chain links stay
comparable), timestamps and worker ids; `NO_PARENT=1` also ignores
`parent_event_id` (the drive race). Known benign diff: `__context_bytes__` of a
command whose rendered context embeds a prior step's `duration_ms`.
Turn the flag off by REMOVING the variable (`NOETL_WORKER_FUSE_LIFECYCLE-`).
