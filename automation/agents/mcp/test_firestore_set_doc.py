"""Tests for the Firestore MCP provider's ``set_doc`` write semantics.

Run with no third-party dependency beyond PyYAML::

    python3 -m unittest discover -s automation/agents/mcp -p 'test_*.py' -v

The provider's ``firestore_dispatch`` code is extracted from ``firestore.yaml`` and
executed with ``method: tools/list`` (no network), then ``_request`` is replaced by a
recorder so each test sees the exact HTTP call ``_set_doc`` would make.

The load-bearing test is :class:`EmptyMergeIsNotAWipe`. Firestore treats a ``PATCH``
without ``updateMask`` as a FULL REPLACE, and the provider only adds the mask when
``data`` is non-empty — so ``set_doc(merge=true, data={})`` used to overwrite the whole
document with zero fields. ``muno/playbooks/profile`` sent exactly that on every login
before its ``read_only`` routing (noetl/travel#133), emptying the user's profile.
"""

import os
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))


def load_provider():
    with open(os.path.join(HERE, "firestore.yaml")) as fh:
        doc = yaml.safe_load(fh)
    step = next(s for s in doc["workflow"] if s["step"] == "firestore_dispatch")
    ns = {
        "method": "tools/list", "tool": "", "arguments": {},
        "gcp_project": "p", "firestore_database": "(default)",
        "firestore_api_base": "https://firestore.googleapis.com/v1",
    }
    exec(step["tool"]["code"], ns)
    calls = []

    def fake_request(http_method, url, payload=None, params=None):
        calls.append({"method": http_method, "url": url, "payload": payload, "params": params or {}})
        if http_method == "GET":
            return True, 200, {"name": "projects/p/databases/(default)/documents/users/u1",
                               "fields": {"keep": {"stringValue": "me"}}}
        return True, 200, {"name": "projects/p/databases/(default)/documents/users/u1",
                           "fields": (payload or {}).get("fields", {})}

    ns["_request"] = fake_request
    return ns, calls


class EmptyMergeIsNotAWipe(unittest.TestCase):
    def test_empty_merge_sends_no_patch(self):
        ns, calls = load_provider()
        out = ns["_set_doc"]({"path": "users/u1", "data": {}, "merge": True})
        self.assertFalse(out["isError"])
        self.assertEqual([c["method"] for c in calls if c["method"] != "GET"], [],
                         "a merge of nothing must not PATCH: without updateMask it replaces the doc")
        self.assertTrue(out["data"]["noop"])

    def test_empty_merge_reports_what_the_store_holds(self):
        ns, _ = load_provider()
        out = ns["_set_doc"]({"path": "users/u1", "data": {}, "merge": True})
        self.assertEqual(out["data"]["document"]["data"], {"keep": "me"})

    def test_missing_data_with_merge_is_also_a_noop(self):
        ns, calls = load_provider()
        ns["_set_doc"]({"path": "users/u1", "merge": True})
        self.assertNotIn("PATCH", [c["method"] for c in calls])


class NonObjectDataIsRefused(unittest.TestCase):
    def test_string_data_is_an_error_not_an_empty_write(self):
        # `_as_dict` used to coerce this to {} — and an empty write is a wipe.
        ns, calls = load_provider()
        out = ns["_set_doc"]({"path": "users/u1", "data": '{"a": 1}', "merge": True})
        self.assertTrue(out["isError"])
        self.assertEqual(calls, [])

    def test_list_data_is_an_error(self):
        ns, calls = load_provider()
        out = ns["_set_doc"]({"path": "users/u1", "data": [1], "merge": False})
        self.assertTrue(out["isError"])
        self.assertEqual(calls, [])


class UnchangedBehaviour(unittest.TestCase):
    def test_merge_masks_top_level_keys(self):
        ns, calls = load_provider()
        ns["_set_doc"]({"path": "users/u1", "data": {"a": 1, "b": {"c": 2}}, "merge": True})
        (patch,) = calls
        self.assertEqual(patch["method"], "PATCH")
        self.assertEqual(sorted(patch["params"]["updateMask.fieldPaths"]), ["a", "b"])

    def test_non_merge_is_a_full_replace(self):
        ns, calls = load_provider()
        ns["_set_doc"]({"path": "users/u1", "data": {"a": 1}})
        (patch,) = calls
        self.assertNotIn("updateMask.fieldPaths", patch["params"])

    def test_explicit_empty_replace_still_allowed(self):
        # merge=false with {} is an explicit "clear this document" — keep it possible.
        ns, calls = load_provider()
        ns["_set_doc"]({"path": "users/u1", "data": {}, "merge": False})
        self.assertEqual([c["method"] for c in calls], ["PATCH"])

    def test_batch_set_docs_goes_through_the_same_guard(self):
        ns, calls = load_provider()
        ns["_batch_set_docs"]({"items": [{"path": "users/u1", "doc": {}, "merge": True}]})
        self.assertNotIn("PATCH", [c["method"] for c in calls])


if __name__ == "__main__":
    unittest.main()
