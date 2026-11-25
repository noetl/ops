#!/usr/bin/env python3
"""canon.py A.jsonl B.jsonl — canonicalize two executions' noetl.event rows and diff.
Volatile values are normalized: every snowflake-sized integer (>=1e15, or inside a
string) becomes #k by first appearance (so chain links prev/parent stay comparable),
created_at/worker_id/timings dropped. Exit 0 iff identical."""
import json,re,sys
SNOW=re.compile(r'\d{15,}')
TS=re.compile(r'\d{4}-\d\d-\d\dT[\d:.]+(Z|[+-]\d\d:\d\d)?')
import os
DROP={'emitted_at','created_at','worker_id','duration_ms','elapsed_ms','duration','started_at','completed_at','timestamp','pid'}
if os.environ.get('NO_PARENT'): DROP.add('parent_event_id')
def canon(rows):
    ids={}
    def m(x):
        k=str(x)
        if k not in ids: ids[k]=f"#{len(ids)}"
        return ids[k]
    def walk(v,key=None):
        if isinstance(v,dict): return {k:walk(x,k) for k,x in sorted(v.items()) if k not in DROP}
        if isinstance(v,list): return [walk(x) for x in v]
        if isinstance(v,bool) or v is None: return v
        if isinstance(v,int) and abs(v)>=10**15: return m(v)
        if isinstance(v,str):
            if 'noetl-worker' in v: return '<worker>'
            if TS.fullmatch(v): return '<ts>'
            return SNOW.sub(lambda g:m(g.group(0)),v)
        return v
    return [walk(r) for r in rows]
def load(p): return [json.loads(l) for l in open(p) if l.strip()]
a,b=canon(load(sys.argv[1])),canon(load(sys.argv[2]))
if a==b:
    print(f"IDENTICAL {len(a)} events"); sys.exit(0)
print(f"DIFF: {len(a)} vs {len(b)} events")
for i,(x,y) in enumerate(zip(a,b)):
    if x!=y:
        print(f" first diff at #{i}:\n  A {json.dumps(x)[:600]}\n  B {json.dumps(y)[:600]}"); break
else:
    print(" one is a prefix of the other; extra:", json.dumps((a[len(b):] or b[len(a):])[:2])[:600])
sys.exit(1)
