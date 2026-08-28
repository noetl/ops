# Secret **shape** templates — never applied, never carry real values

These files describe the *structure* of the Secrets the platform expects. They are
deliberately outside every applied manifest directory, and their values are
placeholders.

## Why they are not in `ci/manifests/noetl/`

Two reasons, both learned the hard way (noetl/ai-meta#309, noetl/ai-meta#310):

1. **Applying them would overwrite live credentials.** `secret.yaml` carried a
   `NOETL_ENCRYPTION_KEY` that differed from the live one. Applying it would not
   have failed loudly — it would have made every stored credential undecryptable,
   because that key is what the credential store is encrypted *with*.
2. **They are a Secret, in a public repository.** Committed literal values are
   world-readable the moment they land, and remain so in history.

## Where the real values live

Production reads all three bootstrap secrets from **GCP Secret Manager**, projected
as files by the CSI driver (noetl/ai-meta#267 Tier 2 stage 5) — see
`../noetl/secretproviderclass-server-secrets-prod.yaml`. No workload reads these
templates.

For local development, supply your own values; do not reuse anything from a
deployed environment.
