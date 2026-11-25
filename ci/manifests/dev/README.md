# Development / kind manifests — **NOT** applied to production

These files declare the **same object names** as their `…-prod.yaml` siblings in
`../noetl/`. They used to live alongside them, which made
`kubectl apply -f ci/manifests/noetl/` order-dependent: a directory apply runs in
filename order, so `server-rust-deployment.yaml` sorted *after*
`server-rust-deployment-prod.yaml` and **the dev variant won**.

A disaster-recovery re-apply would therefore have overwritten the production
control plane, user worker pool and system pool with development specs — while
every `-prod` file individually diffed clean, which is why per-file checking never
saw it (noetl/ai-meta#309).

They are separated rather than deleted because kind still uses them.
