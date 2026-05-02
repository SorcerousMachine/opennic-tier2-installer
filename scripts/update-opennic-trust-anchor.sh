#!/usr/bin/env bash
# scripts/update-opennic-trust-anchor.sh - re-fetch the OpenNIC root KSK and
# update /etc/bind/named.conf.keys. Run after OpenNIC announces a key rollover.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# shellcheck source=../lib/helpers.sh
source "$REPO_ROOT/lib/helpers.sh"
# shellcheck source=../lib/opennic.sh
source "$REPO_ROOT/lib/opennic.sh"
ensure_log_file
require_root
load_config
apply_config_defaults

log_info "checking which Tier-1 IPs are live"
opennic_filter_live_tier1
log_info "fetching current OpenNIC root KSK"
opennic_fetch_root_ksk

# Show the operator what's about to be installed before doing it.
log_info "new trust-anchors block:"
TMP="$(mktemp)"
opennic_render_keys "$TMP"
sed 's/^/    /' "$TMP"

cp -a /etc/bind/named.conf.keys "/etc/bind/named.conf.keys.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
install -m 0644 -o root -g bind "$TMP" /etc/bind/named.conf.keys
rm -f "$TMP"

if ! named-checkconf; then
    log_error "named-checkconf failed; restore the .bak file"
    exit 1
fi

systemctl reload named || systemctl restart named
log_ok "trust anchor updated (RFC 5011 will manage further automatic rollovers via initial-key)"
