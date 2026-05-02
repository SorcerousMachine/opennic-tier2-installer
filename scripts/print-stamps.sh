#!/usr/bin/env bash
# scripts/print-stamps.sh - regenerate and print DNSCrypt + DoH stamps
# in case the install summary was lost. Reads the operator config and the
# DNSCrypt provider key file; needs root because /etc/dnsdist/dnscrypt is
# locked down.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# shellcheck source=../lib/helpers.sh
source "$REPO_ROOT/lib/helpers.sh"
require_root
load_config
apply_config_defaults

PROVIDER_PUB=/etc/dnsdist/dnscrypt/provider.public
if [[ ! -r "$PROVIDER_PUB" ]]; then
    echo "error: $PROVIDER_PUB not readable - run install.sh first" >&2
    exit 1
fi

flags=(--dnssec --no-logs --no-filter)

echo "Provider name: $DNSCRYPT_PROVIDER_NAME"
echo
echo "DNSCrypt stamp (IPv4):"
python3 "$REPO_ROOT/lib/make_stamp.py" dnscrypt \
    --addr "${RESOLVER_IPV4}:8443" \
    --provider-name "$DNSCRYPT_PROVIDER_NAME" \
    --public-key "$PROVIDER_PUB" "${flags[@]}"
echo

if [[ -n "${RESOLVER_IPV6:-}" ]]; then
    echo "DNSCrypt stamp (IPv6):"
    python3 "$REPO_ROOT/lib/make_stamp.py" dnscrypt \
        --addr "[${RESOLVER_IPV6}]:8443" \
        --provider-name "$DNSCRYPT_PROVIDER_NAME" \
        --public-key "$PROVIDER_PUB" "${flags[@]}"
    echo
fi

echo "DoH stamp:"
python3 "$REPO_ROOT/lib/make_stamp.py" doh \
    --hostname "$RESOLVER_HOSTNAME" \
    --path /dns-query "${flags[@]}"
echo
