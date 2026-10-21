#!/usr/bin/env python3
"""automation/agents/mcp/hotelbeds.yaml: HotelBeds counts guests PER ROOM
(adiona/frontend#63), so search_hotels splits the party across rooms. The same code and
test as the itinerary planner's (noetl/travel, planner first). Offline; HTTP stubbed.

  python3 automation/agents/mcp/tests/hotelbeds_party_rooms_test.py
"""
import os
import base64
import io
import json
import sys
import urllib.error
import urllib.request
from datetime import date, timedelta

import yaml

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


sent = []
AVAIL = {"hotels": {"hotels": []}}


def fake_urlopen(req, timeout=None):
    url = req.full_url
    if "metadata.google.internal" in url:
        return Resp({"access_token": "t"})
    if "secretmanager" in url:
        return Resp({"payload": {"data": base64.b64encode(b'{"apikey":"k","secret":"s"}').decode()}})
    if "/hotel-api/1.0/hotels" in url:
        sent.append(json.loads(req.data.decode()))
        return Resp(AVAIL)
    if "hotel-content-api" in url or ":batchGet" in url:
        return Resp({"hotels": []} if "hotel-content-api" in url else [])
    raise AssertionError("unexpected URL " + url)


urllib.request.urlopen = fake_urlopen
CHECK_IN = (date.today() + timedelta(days=30)).isoformat()
CHECK_OUT = (date.today() + timedelta(days=34)).isoformat()


def run(code, **args):
    sent.clear()
    a = dict({"latitude": 48.85, "longitude": 2.35, "check_in": CHECK_IN, "check_out": CHECK_OUT}, **args)
    g = dict(method="tools/call", tool="search_hotels", arguments=a, book_tolerance=15, max_hotels=10,
             hotelbeds_env="test", hotelbeds_api_base="https://api.test.hotelbeds.com", google_project="p",
             hotelbeds_secret_name="s", hotel_content_source="off", firestore_database="(default)")
    exec(code, g)
    return g["result"], (sent[0]["occupancies"] if sent else None)


def hotels_of(result):
    found = []
    def walk(o):
        if isinstance(o, dict):
            if isinstance(o.get("hotels"), list) and o["hotels"] and isinstance(o["hotels"][0], dict) and "minRate" in o["hotels"][0]:
                found.append(o["hotels"])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(result)
    return found[0] if found else []


def suite(code, where):
    lib = {}
    exec(code[:code.index("method_name = ")], lib)
    split = lib["_room_occupancies"]

    _, occ = run(code, adults=2, children=2, children_ages=[8, 5], rooms=1)
    check(occ == [{"rooms": 1, "adults": 2, "children": 2,
                   "paxes": [{"type": "AD"}, {"type": "AD"}, {"type": "CH", "age": 5}, {"type": "CH", "age": 8}]}],
          "%s: one room is the whole party, as before" % where)
    _, occ = run(code, adults=4, rooms=2)
    check(occ == [{"rooms": 2, "adults": 2, "children": 0}],
          "%s: 4 adults in 2 rooms is 2 adults per room (it used to say 4 per room)" % where)
    _, occ = run(code, adults=2, children=2, children_ages=[8, 5], rooms=2)
    check(occ == [{"rooms": 1, "adults": 1, "children": 1, "paxes": [{"type": "AD"}, {"type": "CH", "age": 8}]},
                  {"rooms": 1, "adults": 1, "children": 1, "paxes": [{"type": "AD"}, {"type": "CH", "age": 5}]}],
          "%s: 2 adults + 2 children in 2 rooms: one adult and one child per room, each with its own paxes" % where)
    _, occ = run(code, adults=4, children=2, children_ages=[7, 7], rooms=2)
    check(occ == [{"rooms": 2, "adults": 2, "children": 1, "paxes": [{"type": "AD"}, {"type": "AD"}, {"type": "CH", "age": 7}]}],
          "%s: rooms with the same guests merge into one occupancy with rooms: 2" % where)
    _, occ = run(code, adults=3, children=1, children_ages=[6], rooms=2)
    check(occ == [{"rooms": 1, "adults": 2, "children": 0},
                  {"rooms": 1, "adults": 1, "children": 1, "paxes": [{"type": "AD"}, {"type": "CH", "age": 6}]}],
          "%s: an uneven party: the child goes to the emptier room" % where)
    res, occ = run(code, adults=2, rooms=3)
    check(occ is None and "3 rooms need at least 3 adults" in json.dumps(res),
          "%s: more rooms than adults is refused before calling HotelBeds" % where)

    # Every split keeps the whole party: the same guests, every room with an adult.
    ok = True
    for rooms in range(1, 5):
        for adults in range(rooms, 9):
            for kids in range(0, 5):
                ages = [(3 * i + 1) % 18 for i in range(kids)]
                occ, problem = split(rooms, adults, ages)
                total_rooms = sum(o["rooms"] for o in occ)
                total_adults = sum(o["rooms"] * o["adults"] for o in occ)
                got_ages = sorted(a for o in occ for p in o.get("paxes", []) if p["type"] == "CH"
                                  for a in [p["age"]] * o["rooms"])
                paxes_ok = all(len(o.get("paxes", [])) == (o["adults"] + o["children"] if o["children"] else 0) for o in occ)
                ok &= (not problem and total_rooms == rooms and total_adults == adults and got_ages == sorted(ages)
                       and all(o["adults"] >= 1 for o in occ) and paxes_ok)
    check(ok, "%s: for 1-4 rooms, 1-8 adults, 0-4 children: same rooms, adults and ages, an adult in every room" % where)

    # The party's price when its rooms differ.
    global AVAIL
    rate = lambda key, net, adults, children: {"rateKey": key, "net": net, "rooms": 1, "adults": adults, "children": children}
    AVAIL = {"hotels": {"hotels": [
        {"code": 1, "name": "Both priced", "currency": "USD", "minRate": "100.00",
         "rooms": [{"code": "DBL", "name": "Double", "rates": [rate("a", "180.00", 2, 0), rate("b", "150.00", 2, 0),
                                                              rate("c", "100.00", 1, 1), rate("d", "120.00", 1, 1)]}]},
        {"code": 2, "name": "One group unpriced", "currency": "USD", "minRate": "90.00",
         "rooms": [{"code": "DBL", "name": "Double", "rates": [rate("e", "90.00", 1, 1)]}]}]}}
    res, _ = run(code, adults=3, children=1, children_ages=[6], rooms=2)
    hs = {h["code"]: h for h in hotels_of(res)}
    check(hs[1]["minRate"] == "250.00" and hs[1]["party_priced"] is True,
          "%s: the party's price is the cheapest rate per room group, summed (150 + 100)" % where)
    check(hs[1]["party_rooms"] == [{"rooms": 1, "adults": 2, "children": 0}, {"rooms": 1, "adults": 1, "children": 1}],
          "%s: the room split rides along" % where)
    check(hs[2]["party_priced"] is False and hs[2]["minRate"] == "90.00",
          "%s: a hotel with no rate for one room group says so (party_priced false)" % where)
    res, _ = run(code, adults=2, rooms=1)
    check(all("party_priced" not in h for h in hotels_of(res)), "%s: a single-occupancy search is unchanged" % where)
    AVAIL = {"hotels": {"hotels": []}}


PLAYBOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hotelbeds.yaml")
step = next(s for s in yaml.safe_load(open(PLAYBOOK))["workflow"] if (s.get("tool") or {}).get("kind") == "python")
suite(step["tool"]["code"], "mirror")
if failures:
    sys.exit("%d failure(s)" % len(failures))
