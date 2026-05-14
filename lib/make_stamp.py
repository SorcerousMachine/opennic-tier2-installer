#!/usr/bin/env python3
"""
Generate dnscrypt.info-format `sdns://` server stamps.

Spec: https://dnscrypt.info/stamps-specifications

Usage:
    make_stamp.py dnscrypt --addr 1.2.3.4:8443 \
        --provider-name 2.dnscrypt-cert.example.com \
        --public-key /path/to/provider.public \
        [--no-logs] [--no-filter] [--dnssec]

    make_stamp.py doh --addr 1.2.3.4 \
        --hostname example.com \
        --path /dns-query \
        [--no-logs] [--no-filter] [--dnssec]

The output is the stamp string only (no trailing newline). Errors go to stderr
with non-zero exit.
"""
from __future__ import annotations

import argparse
import base64
import struct
import sys
from pathlib import Path


PROTO_DNSCRYPT = 0x01
PROTO_DOH = 0x02
PROTO_DOQ = 0x04

FLAG_DNSSEC = 1 << 0
FLAG_NO_LOGS = 1 << 1
FLAG_NO_FILTER = 1 << 2


def _lp(b: bytes) -> bytes:
    """Length-prefix: 1 byte length followed by the bytes themselves."""
    if len(b) > 0xFF:
        raise ValueError(f"LP value too long: {len(b)} bytes")
    return bytes([len(b)]) + b


def _b64url_no_pad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _read_public_key(path: Path) -> bytes:
    pk = path.read_bytes()
    if len(pk) != 32:
        raise ValueError(f"DNSCrypt provider public key must be 32 bytes, got {len(pk)}")
    return pk


def _flags_from_args(args: argparse.Namespace) -> int:
    flags = 0
    if args.dnssec:
        flags |= FLAG_DNSSEC
    if args.no_logs:
        flags |= FLAG_NO_LOGS
    if args.no_filter:
        flags |= FLAG_NO_FILTER
    return flags


def make_dnscrypt_stamp(args: argparse.Namespace) -> str:
    flags = _flags_from_args(args)
    pk = _read_public_key(Path(args.public_key))
    body = b""
    body += bytes([PROTO_DNSCRYPT])
    body += struct.pack("<Q", flags)
    body += _lp(args.addr.encode("ascii"))
    body += _lp(pk)
    body += _lp(args.provider_name.encode("ascii"))
    return "sdns://" + _b64url_no_pad(body)


def make_doh_stamp(args: argparse.Namespace) -> str:
    flags = _flags_from_args(args)
    body = b""
    body += bytes([PROTO_DOH])
    body += struct.pack("<Q", flags)
    body += _lp(args.addr.encode("ascii") if args.addr else b"")
    # No certificate hashes - clients use the system trust store. The hash
    # list is encoded as VLP (vector of LPs), where multi-hash uses 0x80
    # high-bit on the length byte. An empty hash list is just 0x00.
    body += b"\x00"
    body += _lp(args.hostname.encode("ascii"))
    body += _lp(args.path.encode("ascii"))
    # bootstrap_ips is optional and entirely omitted when empty (per spec
    # `0x02 || props || LP(addr) || VLP(hashes) || LP(host) || LP(path) [|| VLP(bootstrap_ips)]`).
    # Encoding it as an empty LP/VLP byte trips strict parsers like dnscrypt-proxy.
    return "sdns://" + _b64url_no_pad(body)


def make_doq_stamp(args: argparse.Namespace) -> str:
    flags = _flags_from_args(args)
    body = b""
    body += bytes([PROTO_DOQ])
    body += struct.pack("<Q", flags)
    body += _lp(args.addr.encode("ascii") if args.addr else b"")
    # Empty hash list (clients use system trust store).
    body += b"\x00"
    body += _lp(args.hostname.encode("ascii"))
    return "sdns://" + _b64url_no_pad(body)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="proto", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dnssec", action="store_true", help="set DNSSEC flag")
    common.add_argument("--no-logs", action="store_true", help="set no-logs flag")
    common.add_argument("--no-filter", action="store_true", help="set no-filter flag")

    p_dc = sub.add_parser("dnscrypt", parents=[common])
    p_dc.add_argument("--addr", required=True, help='ip:port, e.g. "1.2.3.4:8443"')
    p_dc.add_argument("--provider-name", required=True)
    p_dc.add_argument("--public-key", required=True, help="path to 32-byte raw provider public key")

    p_doh = sub.add_parser("doh", parents=[common])
    p_doh.add_argument("--addr", default="", help="optional ip[:port] override; empty = use DNS")
    p_doh.add_argument("--hostname", required=True)
    p_doh.add_argument("--path", default="/dns-query")

    p_doq = sub.add_parser("doq", parents=[common])
    p_doq.add_argument("--addr", default="", help='optional ip[:port] override; empty = use DNS')
    p_doq.add_argument("--hostname", required=True)

    args = parser.parse_args(argv)
    try:
        if args.proto == "dnscrypt":
            print(make_dnscrypt_stamp(args), end="")
        elif args.proto == "doh":
            print(make_doh_stamp(args), end="")
        elif args.proto == "doq":
            print(make_doq_stamp(args), end="")
        else:
            parser.error(f"unknown protocol {args.proto}")
            return 2
    except Exception as exc:
        print(f"make_stamp: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
