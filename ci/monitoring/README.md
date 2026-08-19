# Cloud Monitoring alerting, as code

**[noetl/ai-meta#238](https://github.com/noetl/ai-meta/issues/238).**

## Which path actually pages

Prod has **two** alerting paths and only one of them delivers. This matters more
than any individual rule, because the inert one looks exactly like the working
one from inside a repository.

| path | object | state |
| :-- | :-- | :-- |
| **Cloud Monitoring alert policies** → notification channels | `ci/monitoring/alertpolicies.json` | **WORKING.** Every policy is attached to a channel and pages. |
| GMP `Rules` → managed Alertmanager | `ci/manifests/noetl/gmp/rules-*.yaml` | **INERT.** See below. |

The GMP `OperatorConfig` in `gmp-public` references
`configSecret: {name: alertmanager, key: alertmanager.yaml}` — and **namespace
`gmp-public` contains no secrets at all**. Five `Rules` objects are applied in
namespace `noetl` and evaluate happily; their alerts have nowhere to go.

So the `rules-*.yaml` files are **documentation and kind-parity, not a
production paging surface**. Anything that must reach a human belongs in
`alertpolicies.json` until an Alertmanager receiver exists — and configuring one
needs an SMTP, Slack or PagerDuty credential that has not been provisioned.

## Why this file exists at all

Before it, prod's alerting was **entirely undeclared**: eight alert policies and
two notification channels lived only in the running project, in no repository.
A project rebuild would have lost every one of them, silently. That is the same
shape as [#267](https://github.com/noetl/ai-meta/issues/267), where the
deployment manifests omit 84 live env vars — infrastructure that exists but is
described nowhere.

The eight were exported from the live project on 2026-08-19 and are now
declared alongside six new ones for the async event-log mirror
([#155](https://github.com/noetl/ai-meta/issues/155)).

⚠ **The issue's own premise was wrong and is worth not re-inheriting.** #238
says "0 GMP rules, 0 alertPolicies, 0 notificationChannels". At the time of
writing this, prod had 5 Rules objects, 8 alert policies and 2 channels, and the
server *was* being scraped. The real defect was narrower and one layer down: the
policies were undeclared, and the GMP path had no receiver.

## Applying

```bash
./ci/monitoring/apply-alertpolicies.sh --dry-run   # show what would change
./ci/monitoring/apply-alertpolicies.sh             # apply
```

Idempotent — matches on `displayName`, PATCHes what exists, POSTs what does not.
It **never deletes**: a policy dropped from the JSON stays live and is reported
at the end, because silently removing a paging rule is a worse failure than
leaving a stale one.

⚠ Use `shastaratech@gmail.com`. `kadyapam@gmail.com` owns the **old** project and
produces a confusing permission error here
([#204](https://github.com/noetl/ai-meta/issues/204)).

## Notification channels

| id | type | destination | used by |
| :-- | :-- | :-- | :-- |
| `8780236184765331124` | email | `shastaratech@gmail.com` | every policy in this file |
| `6930211842535753236` | email | `akuksin@gmail.com` | nothing |

The second channel is deliberately **not** wired. Adding it is a one-line change
to `notificationChannels` in the JSON, but routing is an owner decision and
should be made explicitly rather than inherited from whoever ran the script.

⚠ **Channel verification could not be confirmed from the API** —
`verificationStatus` is absent from the `notificationChannels.get` response and
the field is not selectable. An unverified email channel accepts configuration
and silently fails to deliver, which is #238 one layer deeper. The only
conclusive test is to make a policy fire and confirm the mail arrives; do that
after any channel change rather than assuming attachment implies delivery.
