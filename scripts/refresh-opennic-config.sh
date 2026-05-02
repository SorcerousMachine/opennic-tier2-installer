#!/usr/bin/env bash
# scripts/refresh-opennic-config.sh - re-fetch live OpenNIC infrastructure
# data and rebuild BIND's slaved-zone config. Use after OpenNIC adds/removes
# a TLD or rotates Tier-1 nameserver IPs. Reloads BIND on success.
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

log_info "verifying snapshot Tier-1 IPs are still reachable"
opennic_filter_live_tier1

log_info "fetching current OpenNIC root KSK"
opennic_fetch_root_ksk

log_info "re-rendering /etc/bind/named.conf.local + named.conf.keys"
opennic_render_keys /etc/bind/named.conf.keys
opennic_render_local /etc/bind/named.conf.local
chown root:bind /etc/bind/named.conf.keys /etc/bind/named.conf.local
chmod 0644 /etc/bind/named.conf.keys /etc/bind/named.conf.local

if ! named-checkconf; then
    log_error "named-checkconf failed; refusing to reload (left old config in place if reload fails)"
    exit 1
fi

log_info "reloading BIND"
systemctl reload named || systemctl restart named
log_ok "OpenNIC config refreshed"
log_dim "Note: BIND will re-AXFR all zones on next refresh interval; force with: rndc retransfer <zone>"
