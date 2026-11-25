#!/usr/bin/env python3
"""automation/agents/mcp/hotelbeds.yaml: search_hotels reads hotel content (photos, room
photos, reviews, address) from our own copy in Firestore, never a live Content API call
per search (noetl/travel#166). The copy is kept by noetl/travel's
muno/playbooks/hotelbeds-content-sync. Runs the dispatch step's own code offline with every
HTTP call stubbed.

  python3 automation/agents/mcp/tests/hotelbeds_content_cache_test.py
"""
import base64
import io
import json
import os
import sys
import urllib.error
import urllib.request

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
PLAYBOOK = os.path.join(HERE, "..", "hotelbeds.yaml")
failures = []


def check(cond, label):
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        failures.append(label)


class Resp(io.BytesIO):
    def __init__(self, body):
        super().__init__(json.dumps(body).encode())
        self.status, self.headers = 200, {}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        pass


calls, routes = [], {}


def fake_urlopen(req, timeout=None):
    url = req.full_url
    body = json.loads(req.data.decode()) if getattr(req, "data", None) else None
    calls.append(url)
    for key, handler in routes.items():
        if key in url:
            out = handler(url, body)
            if isinstance(out, tuple):
                raise urllib.error.HTTPError(url, out[0], "err", {}, io.BytesIO(json.dumps(out[1]).encode()))
            return Resp(out)
    raise AssertionError("unexpected URL " + url)


urllib.request.urlopen = fake_urlopen
doc = yaml.safe_load(open(PLAYBOOK))
step = next(s for s in doc["workflow"] if (s.get("tool") or {}).get("kind") == "python")
CODE = step["tool"]["code"]

check(doc["workload"].get("hotel_content_source") == "cache" and doc["workload"].get("firestore_database") == "(default)",
      "the playbook reads content from the cache by default")
check("default('cache')" in step["tool"]["input"].get("hotel_content_source", "")
      and "firestore_database" in step["tool"]["input"],
      "the dispatch step receives hotel_content_source (default cache) and firestore_database")

CACHED = {"code": "12345", "city": "PARIS", "address": "12 Rue Exemple", "postalCode": "75004",
          "images": [{"path": "00/b.jpg", "order": 2, "roomCode": "DBL.ST"}, {"path": "00/a.jpg", "order": 1}],
          "reviews": [{"type": "HOTELBEDS", "rate": 4.3, "reviewCount": 812}]}
AVAIL = {"hotels": {"total": 2, "hotels": [
    {"code": 12345, "name": "Hotel Example", "currency": "EUR", "minRate": "400.00", "rooms": []},
    {"code": 999, "name": "Not Cached", "currency": "EUR", "minRate": "300.00", "rooms": []}]}}
SECRET = {"payload": {"data": base64.b64encode(json.dumps({"apikey": "k", "secret": "s"}).encode()).decode()}}


def search(source="cache", firestore=None):
    routes.clear()
    calls.clear()
    routes["metadata.google.internal"] = lambda u, b: {"access_token": "t"}
    routes["secretmanager.googleapis.com"] = lambda u, b: SECRET
    routes["hotel-api/1.0/hotels"] = lambda u, b: AVAIL
    routes["hotel-content-api/1.0/hotels"] = lambda u, b: {"hotels": [{"code": 12345, "images": [{"path": "live/x.jpg"}]}]}
    routes[":batchGet"] = firestore or (lambda u, b: [
        {"found": {"name": d, "fields": {"json": {"stringValue": json.dumps(CACHED)}}}} if d.endswith("/12345")
        else {"missing": d} for d in b["documents"]])
    g = dict(method="tools/call", tool="search_hotels", book_tolerance=15, max_hotels=20,
             arguments={"latitude": 48.85, "longitude": 2.35, "check_in": "2026-11-03", "check_out": "2026-11-07"},
             hotelbeds_env="test", hotelbeds_api_base="https://api.test.hotelbeds.com", google_project="proj",
             hotelbeds_secret_name="hotelbeds-hotels-test", hotel_content_source=source, firestore_database="(default)")
    exec(CODE, g)
    data = _as_dict(g["result"])
    inner = _as_dict(data.get("data"))
    inner = _as_dict(inner.get("data")) if "hotels" not in inner else inner
    return {str(h["code"]): h for h in inner.get("hotels", [])}, inner.get("meta") or {}, list(calls)


def _as_dict(v):
    return v if isinstance(v, dict) else {}


hotels, meta, seen = search()
check(hotels and not any("hotel-content-api" in u for u in seen), "a cached search makes no Content API request")
check(sum(u.endswith(":batchGet") for u in seen) == 1, "one Firestore batchGet per search")
h = hotels["12345"]
check(h["images"] == ["https://photos.hotelbeds.com/giata/bigger/00/a.jpg", "https://photos.hotelbeds.com/giata/bigger/00/b.jpg"],
      "hotel photos come from the copy, in HotelBeds' order, uncapped")
check(h["room_images"] == {"DBL.ST": ["https://photos.hotelbeds.com/giata/bigger/00/b.jpg"]}, "room photos by roomCode")
check(h["reviews"] == CACHED["reviews"], "reviews come from the copy")
check(h["city"] == "PARIS" and h["address"] == "12 Rue Exemple" and h["postalCode"] == "75004",
      "address, city and postal code ride along")
check(hotels["999"]["images"] == [] and hotels["999"]["room_images"] == {} and "city" not in hotels["999"],
      "a hotel not in the copy has no content, and no live fallback")
check(meta.get("content_cache") == {"source": "cache", "requested": 2, "hits": 1, "misses": 1, "error": None},
      "the search reports hits and misses: %s" % meta.get("content_cache"))

hotels, meta, seen = search(firestore=lambda u, b: (503, {"error": "down"}))
check(len(hotels) == 2 and all(x["images"] == [] for x in hotels.values()) and meta["content_cache"]["error"]
      and meta.get("images_error") == meta["content_cache"]["error"]
      and not any("hotel-content-api" in u for u in seen),
      "Firestore down: hotels still come back, without photos, with the reason, and no live call")
hotels, meta, seen = search(source="live")
check(any("hotel-content-api" in u for u in seen) and hotels["12345"]["images"] == ["https://photos.hotelbeds.com/giata/bigger/live/x.jpg"],
      "hotel_content_source=live is the old per-search call (rollback only)")
hotels, meta, seen = search(source="off")
check(not any("hotel-content-api" in u or u.endswith(":batchGet") for u in seen), "off fetches no content")

if failures:
    sys.exit("%d failure(s)" % len(failures))
