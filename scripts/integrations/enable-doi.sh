#!/usr/bin/env bash
# =============================================================================
# scripts/integrations/enable-doi.sh
# =============================================================================
# Optional integration: expose this resolver as a hidden service inside the
# I2P network. Adds DNS-over-I2P (DoI) as a fifth access transport alongside
# Do53/DoT/DoH/DNSCrypt - same resolver, same posture, same data, just one
# more way to reach it.
#
# After this script runs, your resolver is reachable from any host on the
# I2P network at <something>.b32.i2p (the address is generated on first
# i2pd start and saved to /var/lib/opennic-tier2-install/i2p-address.txt).
#
# This is purely additive. None of the existing transports change; clients
# that don't speak I2P see no difference.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
# shellcheck source=../../lib/helpers.sh
source "$REPO_ROOT/lib/helpers.sh"
ensure_log_file
require_root
load_config
apply_config_defaults

I2PD_TUNNELS_DIR=/etc/i2pd/tunnels.conf.d
I2PD_TUNNEL_FILE="$I2PD_TUNNELS_DIR/opennic-dns.conf"
I2PD_KEYS_DIR=/var/lib/i2pd
I2PD_KEYS_FILE="$I2PD_KEYS_DIR/opennic-dns.dat"
I2P_ADDR_FILE=/var/lib/opennic-tier2-install/i2p-address.txt

step_doi_preflight() {
    log_info "preflight checks"

    # Confirm dnsdist is already exposing Do53 on 127.0.0.1:53. If not, the
    # main installer hasn't run, or has run on an old version that predates
    # the loopback listener. Either way, refuse rather than silently produce
    # a broken setup.
    if ! ss -tln 'sport = :53' 2>/dev/null | awk '{print $4}' | grep -qE '^127\.0\.0\.1:53$'; then
        log_error "dnsdist is not listening on 127.0.0.1:53"
        log_error "this script expects the main installer (with the loopback Do53"
        log_error "listener) to have already run. Run 'sudo bash install.sh' first,"
        log_error "or 'sudo FORCE=dnsdist bash install.sh' if it's already installed."
        return 1
    fi
    log_dim "dnsdist is listening on 127.0.0.1:53 ✓"

    # Confirm BIND is healthy too - DoI traffic still walks the same path,
    # so a sick BIND would mean DoI clients see SERVFAIL.
    if ! dig @127.0.0.1 -p 5353 grep.geek A +time=3 +tries=1 +short >/dev/null 2>&1; then
        log_error "BIND on 127.0.0.1:5353 isn't resolving cleanly"
        return 1
    fi
    log_dim "BIND is healthy on 127.0.0.1:5353 ✓"

    log_ok "preflight passed"
}

step_doi_install_i2pd() {
    if dpkg -s i2pd >/dev/null 2>&1; then
        log_dim "i2pd already installed"
    else
        log_info "installing i2pd"
        DEBIAN_FRONTEND=noninteractive run_quiet apt-get install -y -q i2pd
    fi
}

step_doi_render_tunnels() {
    log_info "configuring i2pd server tunnels for DNS"
    install -d -m 0755 -o root -g root "$I2PD_TUNNELS_DIR"
    install -m 0644 -o root -g root \
        "$REPO_ROOT/configs/i2pd/opennic-dns-tunnels.conf.template" \
        "$I2PD_TUNNEL_FILE"
    log_dim "wrote $I2PD_TUNNEL_FILE"
}

step_doi_start_i2pd() {
    log_info "(re)starting i2pd"
    systemctl enable --now i2pd >/dev/null 2>&1 || true
    systemctl restart i2pd
    sleep 2
    if ! systemctl is-active --quiet i2pd; then
        log_error "i2pd failed to start"
        journalctl -u i2pd -n 30 --no-pager >&2 || true
        return 1
    fi
    log_ok "i2pd is running"
}

# i2pd generates a fresh keypair the first time the tunnel is loaded, then
# persists it. We need to wait until that file appears, then derive the
# .b32.i2p destination from the public part. There is no shipped CLI helper
# in Debian's i2pd package, so we compute the address inline: it's the
# base32 (lowercase, RFC 4648 alphabet, no padding) of sha256 of the
# destination's serialized public payload.
step_doi_extract_destination() {
    log_info "waiting for i2pd to generate destination keys (up to 90s)"
    local end=$(( SECONDS + 90 ))
    while (( SECONDS < end )); do
        if [[ -s "$I2PD_KEYS_FILE" ]]; then
            break
        fi
        sleep 2
    done
    if [[ ! -s "$I2PD_KEYS_FILE" ]]; then
        log_error "i2pd never wrote $I2PD_KEYS_FILE - check journalctl -u i2pd"
        return 1
    fi

    # Derive the .b32.i2p address. The keys file layout is:
    #   destination (variable length, ends with 7-byte certificate) |
    #   private signing key | private encryption key
    # The destination's "ident" (what gets hashed for .b32.i2p) is the full
    # destination structure: pub_enc(256) | pub_sign(128) | cert(min 7).
    # i2pd stores the destination at the start of the file. We hash everything
    # up to and including the cert, which is variable-length.
    local b32
    b32="$(python3 - <<PY
import base64, hashlib, sys, struct

with open("$I2PD_KEYS_FILE", "rb") as f:
    data = f.read()

# Destination structure starts at byte 0:
#   pub_enc:    256 bytes
#   pub_sign:   128 bytes (may be padded; actual signing-key bytes depend on type)
#   cert:       3 bytes header (type, len_hi, len_lo) + payload (len bytes)
i = 256 + 128
cert_type = data[i]
cert_len = struct.unpack(">H", data[i+1:i+3])[0]
dest_end = i + 3 + cert_len
dest = data[:dest_end]

# .b32.i2p = base32(sha256(dest)) lowercased, no padding
h = hashlib.sha256(dest).digest()
b32 = base64.b32encode(h).decode("ascii").lower().rstrip("=")
print(b32 + ".b32.i2p")
PY
)"

    install -d -m 0755 /var/lib/opennic-tier2-install
    printf '%s\n' "$b32" > "$I2P_ADDR_FILE"
    chmod 0644 "$I2P_ADDR_FILE"

    log_ok "I2P destination: $b32"
    log_dim "saved to $I2P_ADDR_FILE"

    # Stash for the summary
    DOI_B32="$b32"
}

step_doi_summary() {
    cat <<EOF

${C_BOLD}========================================================================
  DNS-over-I2P enabled
========================================================================${C_RESET}

This resolver is now reachable from inside the I2P network at:

  ${C_BOLD}${DOI_B32:-(see $I2P_ADDR_FILE)}${C_RESET}

To use it, an I2P client needs a client tunnel pointed at this destination.
For i2pd users, the client-side tunnels.conf entries look like:

  [opennic-dns-tcp]
  type = client
  address = 127.0.0.1
  port = 53053
  destination = ${DOI_B32:-<b32-address>}

  [opennic-dns-udp]
  type = udpclient
  address = 127.0.0.1
  port = 53053
  destination = ${DOI_B32:-<b32-address>}

After reloading i2pd, the client can ${C_BOLD}dig @127.0.0.1 -p 53053 example.com${C_RESET}
and the query traverses the I2P network to this resolver.

${C_BOLD}${C_YELLOW}A few things worth knowing:${C_RESET}

  - First-time tunnel establishment can take 5-15 minutes after i2pd starts
    while it bootstraps into the I2P network. ${C_BOLD}sudo journalctl -u i2pd -f${C_RESET}
    shows progress.

  - The destination address is persistent: it's tied to the keypair in
    $I2PD_KEYS_FILE. ${C_BOLD}Back up that file${C_RESET}; losing it means a new address
    and any clients with the old one will fail.

  - Latency over I2P is significantly higher than clearnet (typically
    300ms-2s extra round-trip). I2P is not a low-latency transport.

  - Publish the .b32.i2p address wherever your clearnet endpoints are
    listed (operator info page, dns-operations announcement, OpenNIC
    Tier-2 listing description). I2P-aware users won't find you without it.

${C_BOLD}${C_YELLOW}NEXT STEPS:${C_RESET}

  1. Back up $I2PD_KEYS_FILE off-host.
  2. Watch ${C_BOLD}sudo journalctl -u i2pd -f${C_RESET} for tunnel-established lines.
  3. Once tunnels are green, publish the .b32.i2p where I2P-aware users
     will find it: your operator info page, the I2P forum services
     subforum, r/i2p, the #i2p IRC channel on Libera Chat, or the
     description of your OpenNIC Tier-2 listing.

EOF
}

step_doi_preflight
step_doi_install_i2pd
step_doi_render_tunnels
step_doi_start_i2pd
step_doi_extract_destination
step_doi_summary
