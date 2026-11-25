# Image digest ledger — append-only

Format and rationale: `../RELEASE-LEDGER.md`. One TSV per component:

```
version<TAB>digest<TAB>released_at<TAB>git_sha<TAB>note
```

**Append-only and dated.** These rows are a *record*, not a representation —
they are correct precisely because they are never updated. A row that has gone
stale is still a true statement about what ran at that moment, which is the
whole point for DR and for rollback.

The release job does not write these yet (`RELEASE-LEDGER.md` §"What is
deliberately not decided here"). Until it does, rows are appended by hand at the
moment a digest is observed running in prod, and the `note` says who observed it
and why — a hand-written row with no provenance is worse than no row.

## Reading one back

```
kubectl -n noetl set image sts/noetl-server-rust-embedded \
  noetl-server=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@<digest>
```

The **rollback target is the row above the one currently running.**
