# The digest ledger — where DR gets an image, now that the manifests do not

**Status: format + rationale. The recording step is not wired yet.**

## Why the manifests can't be the source

`ci/manifests/noetl/*.yaml` declares **shape**. It does not declare which image
runs, because that copy had no forcing function and was behind live on every
prod workload ([#323](https://github.com/noetl/ai-meta/issues/323)).

Removing it fixes the **re-apply** hazard completely: a server-side apply leaves
a field the manifest does not claim, proved by dry-run against live on all five
workloads.

It does **not** fix DR-from-nothing. A Deployment cannot be *created* without an
image, so a rebuild-from-empty-cluster still needs a digest from somewhere.

## The shape of the fix

Derive it from the thing that already knows. The release job resolves the AR
digest as a normal step — that value is correct **by construction**, not by
ritual. Appending it to a ledger costs one step:

```
# ci/manifests/noetl/ledger/<component>.tsv   (append-only)
# version	digest	released_at	git_sha
v3.104.3	sha256:646f2e30…	2026-09-06T17:29Z	3ba7dd57
v3.104.4	sha256:…	2026-09-07T06:2xZ	…
```

Append-only and dated, so it is a **record**, not a representation: it is
correct precisely by not updating. `representation-drift.md`'s exemption.

DR then reads the last row (or a named row, to rebuild at a point in time) and
supplies it to the apply:

```
kubectl apply -f server-rust-deployment-prod.yaml
kubectl set image deploy/noetl-server-rust noetl-server=<repo>@<digest-from-ledger>
```

## Why not have DR read the cluster instead

Preferable when the cluster exists — *prefer derivation over denormalization* —
but the DR case where it matters most is the one where the cluster is gone. The
ledger is the durable fallback for exactly that case, which is why the
recommendation is both and not either.

## What is deliberately not decided here

Which release job writes it, and whether the ledger lives in `ops` or beside
each component's releases. Wiring it means touching the release workflows in
`noetl/server` and `noetl/worker`, which is its own change with its own review.
