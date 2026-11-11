#!/usr/bin/env python3
"""Emit the misbehaving plug-in modules the guardrail e2e runs (no toolchain needed).

Both speak the worker's byte ABI: export `memory`, `alloc(i32)->i32`,
`run(i32, i32)->i64`.

  spin.wasm     run() loops forever            (fuel / wall-clock limit)
  balloon.wasm  run() grows memory until refused, then traps  (memory cap)

Usage: make_modules.py OUT_DIR
"""
import os
import sys


def leb(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def section(sid, payload):
    return bytes([sid]) + leb(len(payload)) + payload


def vec(items):
    return leb(len(items)) + b"".join(items)


def name(s):
    return leb(len(s)) + s.encode()


def module(run_body):
    types = vec([
        b"\x60\x01\x7f\x01\x7f",          # (i32) -> i32        alloc
        b"\x60\x02\x7f\x7f\x01\x7e",      # (i32, i32) -> i64   run
    ])
    funcs = vec([b"\x00", b"\x01"])
    memory = vec([b"\x00\x01"])           # min 1 page, no max
    exports = vec([
        name("memory") + b"\x02\x00",
        name("alloc") + b"\x00\x00",
        name("run") + b"\x00\x01",
    ])
    alloc = b"\x00" + b"\x41\x80\x08" + b"\x0b"   # no locals; i32.const 1024; end
    run = b"\x00" + run_body                      # no locals
    code = vec([leb(len(alloc)) + alloc, leb(len(run)) + run])
    return (b"\x00asm\x01\x00\x00\x00" + section(1, types) + section(3, funcs)
            + section(5, memory) + section(7, exports) + section(10, code))


SPIN = (b"\x03\x40"        # loop
        b"\x0c\x00"        #   br 0
        b"\x0b"            # end
        b"\x42\x00\x0b")   # i64.const 0; end
BALLOON = (b"\x03\x40"                 # loop
           b"\x41\x01\x40\x00"         #   memory.grow 1
           b"\x41\x7f\x46"             #   == -1 ?
           b"\x04\x40\x00\x0b"         #   if: unreachable
           b"\x0c\x00"                 #   br 0
           b"\x0b"                     # end
           b"\x42\x00\x0b")            # i64.const 0; end

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    for fname, body in (("spin.wasm", SPIN), ("balloon.wasm", BALLOON)):
        with open(os.path.join(out, fname), "wb") as f:
            f.write(module(body))
        print(os.path.join(out, fname))
