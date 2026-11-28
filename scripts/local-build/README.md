# Local builds (AMD box + Mac Studio)

Owner decision 2026-11-27: NoETL is compiled on the Mount Shasta Ranch machines,
each one building what is native to it, instead of GitHub Actions / Google Cloud Build.

| Host | Builds | Notes |
|---|---|---|
| AMD box `kadyapam@10.50.0.89` (Linux Mint, x86_64, 32 cores) | `linux-x86_64` release binaries, `linux/amd64` images | no queue; build in your own clone/worktree |
| Mac Studio (M1 Max) | `darwin-arm64` release binaries, `linux/arm64` images for the Mac kind | heavy steps go through `~/.cargo-queue` automatically |

```bash
scripts/local-build/noetl-local-build.sh --repos server,worker,cli           # binaries -> ~/noetl-build/out/<platform>-<stamp>/
scripts/local-build/noetl-local-build.sh --repos server,worker --no-binaries --image   # podman image, native arch
scripts/local-build/noetl-local-build.sh --repos server,worker --image --kind-load noetl
scripts/local-build/noetl-local-build.sh --repos server,worker,cli --remote amd   # from the Mac: Linux build on the AMD box
scripts/local-build/noetl-local-build.sh --repos server --image --push ghcr.io/noetl   # explicit push (after podman login)
```

`--src-root` defaults to the directory holding `ops` (in ai-meta: `repos/`). Each run
writes `*.tar.gz`, `SHA256SUMS`, `build-times.tsv` and `build.log`. Tarball names follow
the GitHub release assets: `<repo>-<version>-g<sha>[-dirty]-<platform>.tar.gz`.

The script never cross-compiles and never pushes unless `--push` is given. Full kind
deploys keep using `automation/development/noetl.yaml`.

Policy for agents: noetl/ai-meta `agents/rules/build-placement.md`.
