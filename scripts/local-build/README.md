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

## Apple Silicon / macOS release artifacts (Mac Studio)

Owner decision 2026-11-28 ("сборки под мак на мак"): the artifacts GitHub used to build on paid macOS and
arm64 runners are built on the Mac Studio with `noetl-publish-mac.sh` (Apple Silicon only):

```bash
# macOS cli binary -> noetl-v<ver>-darwin-arm64.tar.gz (+ .sha256), optionally attached to the GitHub release
scripts/local-build/noetl-publish-mac.sh --repo cli --latest                 # build only, nothing leaves the Mac
scripts/local-build/noetl-publish-mac.sh --repo cli --version 6.4.2 --upload # + gh release upload --clobber

# linux/arm64 images for server / worker (native in the podman VM) -> ghcr.io/noetl/<repo>:<ver>-arm64
scripts/local-build/noetl-publish-mac.sh --repo server --latest --push       # + push, then dispatch assemble-multiarch-manifest
```

- It clones the release tag fresh (never touches your working trees), stamps the version like `release.yml`, and
  runs heavy steps through `~/.cargo-queue`.
- Nothing is published unless `--upload` / `--push` is given. `--push` needs `podman login ghcr.io` with a token that
  has `write:packages`; `--upload` needs `gh auth login` (repo scope). No secret is ever read or printed.
- The release workflows skip these jobs on GitHub unless the repo variable `MACOS_BUILDS_ON_GITHUB` (cli) or
  `ARM_BUILDS_ON_GITHUB` (server, worker) is `true`. Set it to roll back.
- `:latest` of the server/worker image is only moved once both architectures exist
  (`assemble-multiarch-manifest.yml`, metadata only).
