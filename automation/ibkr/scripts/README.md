# IBKR login scripts (vendored)

These were recovered from `noetl/noetl` at commit `a106d045`, the last commit that
still contained them. They were removed from that repo when it became a thin wrapper
around the Rust CLI and stopped carrying Python
([noetl/ai-meta#382](https://github.com/noetl/ai-meta/issues/382)).

They live here because **ops is what uses them**, and because the previous
arrangement had no tracked source of truth:

| file | role |
| :-- | :-- |
| `authenticate_gateway.py` | the implementation — drives the Gateway web login with `playwright.sync_api`, then confirms via `/v1/api/tickle`. Deliberately **not** IBeam. |
| `ibkr_login_job.py` | the NoETL script-tool entry point (JSON in `argv[1]`, credentials from `IBKR_*` env). **This is the source of truth for `gs://tradetrend/scripts/ibkr/ibkr_login_job.py`**, which `../login.yaml` fetches at runtime. |

## ⚠ The GCS copy and this copy can drift

`../login.yaml` runs the script from `gs://tradetrend/scripts/ibkr/ibkr_login_job.py`
(auth alias `tradetrend_noetl_sdavwe`). That bucket object is a **copy**. Nothing
forces it to agree with the file next to this README, so when you change
`ibkr_login_job.py` here, re-upload it:

```bash
gsutil cp automation/ibkr/scripts/ibkr_login_job.py gs://tradetrend/scripts/ibkr/ibkr_login_job.py
```

Switching `login.yaml` to run the vendored copy directly would remove the drift
entirely; it is left on the GCS path for now because that path works today and
changing it alters a flow nobody has asked to change. See
[noetl/ai-meta#383](https://github.com/noetl/ai-meta/issues/383).

## Not vendored: `login_tool.py`

The third script in the original directory was **not** brought over. It did:

```python
script_path = "/opt/noetl/scripts/ibkr/authenticate_gateway.py"
spec = importlib.util.spec_from_file_location("authenticate_gateway", script_path)
```

No Dockerfile in `noetl/noetl` and nothing in this repo provisions
`/opt/noetl/scripts` — verified across both repos. It was already broken by path
before the deletion, so vendoring it would re-import a dead artifact. Recover it from
`noetl/noetl@a106d045:scripts/ibkr/login_tool.py` if that path is ever created.

## Dependencies

`authenticate_gateway.py` imports `playwright.sync_api`. Install with
`pip install playwright && playwright install chromium`. The `ibkr` extra that used
to declare this in `noetl/noetl`'s pyproject went with the scripts.
