#!/usr/bin/env python3
"""External Flight SQL client — kind validation for the EHDB external driver MVP.

Connects to the dedicated Flight SQL data-plane endpoint (noetl/ai-meta#184) as
an application *outside* the platform and runs a read-only projection-tier query.

It speaks Flight SQL directly: it packs a ``CommandStatementQuery`` into a
``google.protobuf.Any`` (hand-encoded, no protobuf runtime needed) so it
exercises exactly the two server methods the MVP implements —
``get_flight_info_statement`` and ``do_get_statement`` — plus the per-call
bearer-token auth header.

Usage:
    python3 ehdb_flightsql_client.py \
        --host 127.0.0.1 --port 8092 \
        --token "$EHDB_FLIGHT_TOKEN" \
        --sql "SELECT * FROM executions LIMIT 100"

    # loopback-unauth harness mode (no token required):
    python3 ehdb_flightsql_client.py --host 127.0.0.1 --port 8092 --no-auth \
        --sql "SELECT execution_id, status FROM executions"

Requires: pyarrow (pip install pyarrow).
"""
import argparse
import sys

import pyarrow.flight as flight


def _varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _len_delim(field_num: int, payload: bytes) -> bytes:
    # wire type 2 (length-delimited): (field_num << 3) | 2
    return bytes([(field_num << 3) | 2]) + _varint(len(payload)) + payload


def command_statement_query(sql: str) -> bytes:
    """Encode Any(CommandStatementQuery{query = sql}) as protobuf bytes.

    CommandStatementQuery.query is field 1 (string). The Any wrapper carries the
    standard Flight SQL type URL in field 1 and the encoded message in field 2.
    """
    inner = _len_delim(1, sql.encode("utf-8"))
    type_url = b"type.googleapis.com/arrow.flight.protocol.sql.CommandStatementQuery"
    return _len_delim(1, type_url) + _len_delim(2, inner)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8092)
    ap.add_argument("--token", default=None, help="scoped read-only bearer token")
    ap.add_argument("--no-auth", action="store_true", help="loopback harness mode")
    ap.add_argument("--sql", default="SELECT * FROM executions LIMIT 100")
    ap.add_argument("--tls", action="store_true", help="use grpc+tls")
    args = ap.parse_args()

    scheme = "grpc+tls" if args.tls else "grpc"
    location = f"{scheme}://{args.host}:{args.port}"
    client = flight.FlightClient(location)

    headers = []
    if not args.no_auth:
        if not args.token:
            print("ERROR: --token required unless --no-auth", file=sys.stderr)
            return 2
        headers.append((b"authorization", f"Bearer {args.token}".encode("utf-8")))
    options = flight.FlightCallOptions(headers=headers)

    descriptor = flight.FlightDescriptor.for_command(command_statement_query(args.sql))

    print(f"[client] connecting to {location}")
    print(f"[client] SQL: {args.sql}")
    info = client.get_flight_info(descriptor, options)
    print(f"[client] schema:\n{info.schema}")

    total_rows = 0
    for endpoint in info.endpoints:
        reader = client.do_get(endpoint.ticket, options)
        table = reader.read_all()
        total_rows += table.num_rows
        print(f"[client] got {table.num_rows} row(s):")
        print(table.to_pydict())

    print(f"[client] OK — {total_rows} row(s) total")
    return 0 if total_rows >= 0 else 1


if __name__ == "__main__":
    sys.exit(main())
