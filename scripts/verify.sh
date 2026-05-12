#!/usr/bin/env bash
# =============================================================================
# scripts/verify.sh
# =============================================================================
# End-to-end verification of an installed OpenNIC Tier-2 resolver.
#
# Exits 0 if every check passes, 1 otherwise. Each check prints a single
# coloured line; failures explain what went wrong. Safe to run any time.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# shellcheck source=../lib/helpers.sh
source "$REPO_ROOT/lib/helpers.sh"
load_config
apply_config_defaults

PASS=0
FAIL=0
WARN=0

_check_ok()   { log_dim "  OK  $*"; PASS=$((PASS+1)); }
_check_fail() { log_error "FAIL $*"; FAIL=$((FAIL+1)); }
_check_warn() { log_warn "WARN $*"; WARN=$((WARN+1)); }

log_step "Verifying OpenNIC Tier-2 resolver at $RESOLVER_HOSTNAME ($RESOLVER_IPV4)"

# ---- Do53 -------------------------------------------------------------------

_test_do53() {
    local proto="$1" name="$2"
    local extra=()
    [[ "$proto" == tcp ]] && extra+=(+tcp)
    local out
    if out="$(dig "@$RESOLVER_IPV4" "$name" A +time=5 +tries=2 +short "${extra[@]}" 2>/dev/null)" \
       && [[ -n "$out" ]]; then
        _check_ok "Do53/$proto $name -> $(head -1 <<<"$out")"
    else
        _check_fail "Do53/$proto query for $name"
    fi
}

_test_do53 udp example.com
_test_do53 tcp example.com
_test_do53 udp grep.geek

# ---- DNSSEC AD flag (ICANN, recursive validation) ---------------------------

if dig "@$RESOLVER_IPV4" cloudflare.com A +time=5 +tries=2 \
        | grep -q 'flags:.*ad'; then
    _check_ok "ICANN DNSSEC validates (cloudflare.com has AD flag)"
else
    _check_fail "ICANN DNSSEC: cloudflare.com missing AD flag"
fi

# Recursive NXDOMAIN should also come back AD-flagged (proves the resolver
# isn't authoritative for the root). Only meaningful when SLAVE_OPENNIC_ROOT
# is false; the slaved-root layout serves these authoritatively without AD.
if [[ "${SLAVE_OPENNIC_ROOT:-false}" == "false" ]]; then
    if dig "@$RESOLVER_IPV4" nonexistent-zone.dnscrypt-test. A +time=5 +tries=2 \
            +adflag | grep -q 'flags:.*ad'; then
        _check_ok "ICANN DNSSEC NXDOMAIN validates (AD on recursive NXDOMAIN)"
    else
        _check_fail "ICANN DNSSEC NXDOMAIN: nonexistent-zone.dnscrypt-test. missing AD flag"
    fi
else
    _check_warn "skipping recursive-NXDOMAIN AD check (SLAVE_OPENNIC_ROOT=true, root served authoritatively)"
fi

# ---- DoT --------------------------------------------------------------------
# When LE_STAGING=true, the staging CA isn't in the system trust store, so
# strict validation fails. Fall back to opportunistic TLS (handshake check
# only) and warn the operator that the production cert hasn't been issued.

if command -v kdig >/dev/null 2>&1; then
    if [[ "${LE_STAGING:-false}" == "true" ]]; then
        out="$(kdig +tls "@$RESOLVER_IPV4" example.com A +short 2>&1 \
                | grep -E '^[0-9.]+$' | head -1)"
        if [[ -n "$out" ]]; then
            _check_warn "DoT (opportunistic - staging cert isn't browser-trusted) -> $out"
        else
            _check_fail "DoT TLS handshake to $RESOLVER_IPV4:853 failed"
        fi
    else
        out="$(kdig +tls +tls-hostname="$RESOLVER_HOSTNAME" +tls-ca \
                    "@$RESOLVER_IPV4" example.com A +short 2>&1 \
                | grep -E '^[0-9.]+$' | head -1)"
        if [[ -n "$out" ]]; then
            _check_ok "DoT $RESOLVER_HOSTNAME:853 (validated) -> $out"
        else
            _check_fail "DoT query failed (cert validation or handshake)"
        fi
    fi
else
    if echo "" | timeout 5 openssl s_client -connect "$RESOLVER_IPV4:853" \
                -servername "$RESOLVER_HOSTNAME" -alpn dot 2>/dev/null \
                | grep -q '^subject='; then
        _check_warn "DoT TLS handshake OK (install knot-dnsutils for full DoT verification)"
    else
        _check_fail "DoT TLS handshake to $RESOLVER_IPV4:853 failed"
    fi
fi

# ---- DoH --------------------------------------------------------------------

# RFC 8484 GET form. base64url-encoded DNS query for example.com A.
DOH_QUERY="AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"
DOH_TMP="$(mktemp)"
http_code="$(curl -ks -o "$DOH_TMP" -w '%{http_code}' \
    --resolve "$RESOLVER_HOSTNAME:443:$RESOLVER_IPV4" \
    -H 'Accept: application/dns-message' \
    "https://$RESOLVER_HOSTNAME/dns-query?dns=$DOH_QUERY" \
    -m 10 2>/dev/null || echo 000)"
sz=$(stat -c %s "$DOH_TMP" 2>/dev/null || echo 0)
rm -f "$DOH_TMP"
if [[ "$http_code" == "200" ]] && (( sz > 12 )); then
    _check_ok "DoH /dns-query -> 200 (${sz}B response)"
else
    _check_fail "DoH /dns-query: code=$http_code, size=${sz}B"
fi

# ---- DNSCrypt ---------------------------------------------------------------

if (echo > "/dev/tcp/$RESOLVER_IPV4/8443") 2>/dev/null; then
    _check_ok "DNSCrypt $RESOLVER_IPV4:8443 reachable (TCP probe)"
else
    _check_fail "DNSCrypt 8443 not reachable"
fi

# ---- info page --------------------------------------------------------------

http_code="$(curl -ks --resolve "$RESOLVER_HOSTNAME:443:$RESOLVER_IPV4" \
    -o /dev/null -w '%{http_code}' "https://$RESOLVER_HOSTNAME/" -m 5 || echo 000)"
if [[ "$http_code" == "200" ]]; then
    _check_ok "operator info page -> HTTP 200"
else
    _check_fail "operator info page returned $http_code"
fi

# ---- HTTP -> HTTPS redirect -------------------------------------------------

http_code="$(curl -s --resolve "$RESOLVER_HOSTNAME:80:$RESOLVER_IPV4" \
    -o /dev/null -w '%{http_code}' "http://$RESOLVER_HOSTNAME/" -m 5 || echo 000)"
if [[ "$http_code" == "301" ]]; then
    _check_ok "HTTP :80 -> 301 redirect"
else
    _check_warn "HTTP :80 returned $http_code (expected 301)"
fi

# ---- IPv6 (if configured) ---------------------------------------------------

if [[ -n "${RESOLVER_IPV6:-}" ]]; then
    if out="$(dig "@$RESOLVER_IPV6" example.com A +time=5 +tries=2 +short 2>/dev/null)" \
       && [[ -n "$out" ]]; then
        _check_ok "Do53 over IPv6 [$RESOLVER_IPV6] -> $(head -1 <<<"$out")"
    else
        _check_warn "IPv6 Do53 query failed (install.conf has RESOLVER_IPV6 set)"
    fi
fi

# ---- summary ----------------------------------------------------------------

printf '\n'
log_step "Verification summary: ${C_GREEN}${PASS} pass${C_RESET}, ${C_YELLOW}${WARN} warn${C_RESET}, ${C_RED}${FAIL} fail${C_RESET}"
exit $(( FAIL > 0 ? 1 : 0 ))
