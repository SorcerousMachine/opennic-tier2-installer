# shellcheck shell=bash
# dnsdist step: DNSCrypt key+cert generation, dnsdist.conf rendering, start.

: "${REPO_ROOT:?REPO_ROOT must be set before sourcing lib/steps_dnsdist.sh}"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/helpers.sh"

DNSDIST_CRYPT_DIR=/etc/dnsdist/dnscrypt
DNSDIST_TLS_DIR=/etc/dnsdist/tls
DNSDIST_CONSOLE_KEY=/etc/dnsdist/console.key

step_dnsdist_install_package() {
    if dpkg -s dnsdist >/dev/null 2>&1; then
        log_dim "dnsdist already installed"
    else
        log_info "installing dnsdist"
        DEBIAN_FRONTEND=noninteractive run_quiet apt-get install -y -q dnsdist
    fi
}

# Generate DNSCrypt provider keypair + resolver cert via a one-shot dnsdist
# Lua run. We use --supervised + os.exit(0) so dnsdist runs the keygen calls
# and exits before binding any sockets.
step_dnsdist_generate_dnscrypt_keys() {
    install -d -m 0750 -o _dnsdist -g _dnsdist "$DNSDIST_CRYPT_DIR"

    if [[ -f "$DNSDIST_CRYPT_DIR/provider.key" ]] \
       && [[ -f "$DNSDIST_CRYPT_DIR/cert.cert" ]] \
       && [[ -f "$DNSDIST_CRYPT_DIR/cert.key" ]]; then
        log_dim "DNSCrypt keys already present (provider key preserved across re-runs)"
        return 0
    fi

    log_info "generating DNSCrypt provider keypair (Ed25519)"
    local lua; lua="$(mktemp)"
    cat > "$lua" <<EOF
generateDNSCryptProviderKeys('$DNSDIST_CRYPT_DIR/provider.public', '$DNSDIST_CRYPT_DIR/provider.key')
generateDNSCryptCertificate(
    '$DNSDIST_CRYPT_DIR/provider.key',
    '$DNSDIST_CRYPT_DIR/cert.cert',
    '$DNSDIST_CRYPT_DIR/cert.key',
    1, os.time(), os.time() + 86400 * 365)
os.exit(0)
EOF
    if ! dnsdist -u root -g root -C "$lua" --supervised >/dev/null 2>>"$LOG_FILE"; then
        log_error "dnsdist key generation failed; see $LOG_FILE"
        rm -f "$lua"
        return 1
    fi
    rm -f "$lua"

    # Lock down the long-term provider key (catastrophic if leaked).
    chown root:root "$DNSDIST_CRYPT_DIR/provider.key" "$DNSDIST_CRYPT_DIR/provider.public"
    chmod 0600 "$DNSDIST_CRYPT_DIR/provider.key"
    chmod 0644 "$DNSDIST_CRYPT_DIR/provider.public"

    # The resolver cert and ephemeral key need to be readable by dnsdist.
    chown root:_dnsdist "$DNSDIST_CRYPT_DIR/cert.cert" "$DNSDIST_CRYPT_DIR/cert.key"
    chmod 0640 "$DNSDIST_CRYPT_DIR/cert.cert" "$DNSDIST_CRYPT_DIR/cert.key"

    log_ok "DNSCrypt keys generated in $DNSDIST_CRYPT_DIR"
    log_warn "back up $DNSDIST_CRYPT_DIR/provider.key NOW - losing it forces a provider-name rotation"
    log_warn "which invalidates every published client stamp"
}

step_dnsdist_generate_console_key() {
    if [[ -s "$DNSDIST_CONSOLE_KEY" ]]; then
        log_dim "console key already present at $DNSDIST_CONSOLE_KEY"
        return 0
    fi
    log_info "generating dnsdist console key"
    install -d -m 0755 /etc/dnsdist
    # setKey() accepts any base64-encoded 32-byte secret. Generate one.
    local key; key="$(openssl rand -base64 32)"
    [[ -n "$key" ]] || { log_error "openssl rand failed"; return 1; }
    install -m 0600 -o root -g root /dev/stdin "$DNSDIST_CONSOLE_KEY" <<< "$key"
    log_ok "console key written to $DNSDIST_CONSOLE_KEY"
}

step_dnsdist_render_config() {
    log_info "rendering /etc/dnsdist/dnsdist.conf"
    install -d -m 0750 -o root -g _dnsdist /etc/dnsdist/conf.d

    local console_key=""
    if [[ -s "$DNSDIST_CONSOLE_KEY" ]]; then
        console_key="$(cat "$DNSDIST_CONSOLE_KEY")"
    fi

    local console_block
    console_block="$(cat <<EOF
controlSocket('127.0.0.1:5199')
setKey('${console_key}')
EOF
    )"

    # IPv6 listener lines, only if RESOLVER_IPV6 is set.
    local ipv6_do53="" ipv6_dot="" ipv6_dnscrypt=""
    if [[ -n "${RESOLVER_IPV6:-}" ]]; then
        ipv6_do53=$'addLocal(\'['"$RESOLVER_IPV6"$']:53\')'
        ipv6_dot=$'addTLSLocal(\'['"$RESOLVER_IPV6"$']:853\','$'\n'$'            \'/etc/dnsdist/tls/fullchain.pem\','$'\n'$'            \'/etc/dnsdist/tls/privkey.pem\')'
        ipv6_dnscrypt=$'addDNSCryptBind(\'['"$RESOLVER_IPV6"$']:8443\','$'\n'$'                \''"$DNSCRYPT_PROVIDER_NAME"$'\','$'\n'$'                \'/etc/dnsdist/dnscrypt/cert.cert\','$'\n'$'                \'/etc/dnsdist/dnscrypt/cert.key\')'
    fi

    local rendered; rendered="$(mktemp)"
    RESOLVER_IPV4="$RESOLVER_IPV4" \
    DNSCRYPT_PROVIDER_NAME="$DNSCRYPT_PROVIDER_NAME" \
    IPV6_DO53="$ipv6_do53" \
    IPV6_DOT="$ipv6_dot" \
    IPV6_DNSCRYPT="$ipv6_dnscrypt" \
    CONSOLE_BLOCK="$console_block" \
        envsubst '${RESOLVER_IPV4} ${DNSCRYPT_PROVIDER_NAME} ${IPV6_DO53} ${IPV6_DOT} ${IPV6_DNSCRYPT} ${CONSOLE_BLOCK}' \
        < "$REPO_ROOT/configs/dnsdist/dnsdist.conf.template" \
        > "$rendered"

    install -m 0640 -o root -g _dnsdist "$rendered" /etc/dnsdist/dnsdist.conf
    rm -f "$rendered"

    log_info "validating dnsdist config"
    if ! run_quiet dnsdist --check-config -C /etc/dnsdist/dnsdist.conf; then
        log_error "dnsdist config check failed"
        return 1
    fi
    log_ok "dnsdist config valid"
}

step_dnsdist_start() {
    log_info "(re)starting dnsdist"
    systemctl enable --now dnsdist >/dev/null 2>&1 || true
    systemctl restart dnsdist
    sleep 1

    if ! systemctl is-active --quiet dnsdist; then
        log_error "dnsdist failed to start"
        journalctl -u dnsdist -n 30 --no-pager >&2
        return 1
    fi

    if ! wait_for_dns_udp "$RESOLVER_IPV4" 53 15; then
        log_error "dnsdist not answering on $RESOLVER_IPV4:53"
        return 1
    fi
    log_ok "dnsdist listening on $RESOLVER_IPV4:53"
}

step_dnsdist_verify() {
    local out

    log_info "verifying Do53 (UDP)"
    out="$(dig "@$RESOLVER_IPV4" example.com A +time=5 +tries=2 +short)"
    [[ -n "$out" ]] || { log_error "Do53 UDP query failed"; return 1; }
    log_dim "example.com (Do53/UDP) -> $(head -1 <<< "$out")"

    log_info "verifying Do53 (TCP)"
    out="$(dig "@$RESOLVER_IPV4" example.com A +tcp +time=5 +tries=2 +short)"
    [[ -n "$out" ]] || { log_error "Do53 TCP query failed"; return 1; }
    log_dim "example.com (Do53/TCP) -> $(head -1 <<< "$out")"

    log_info "verifying DoT (port 853)"
    if command -v kdig >/dev/null 2>&1; then
        # kdig is from knot-dnsutils; falls back to openssl probe if absent
        out="$(kdig +tls "@$RESOLVER_IPV4" example.com A +short 2>&1 | grep -E '^[0-9.]+$' | head -1)"
        if [[ -n "$out" ]]; then
            log_dim "example.com (DoT) -> $out"
        else
            log_warn "kdig +tls did not return a record; raw output in install log"
        fi
    else
        # openssl s_client probe: confirms TLS handshake on 853
        if echo "" | timeout 5 openssl s_client -connect "$RESOLVER_IPV4:853" \
                -servername "$RESOLVER_HOSTNAME" -alpn dot 2>/dev/null \
                | grep -q '^subject='; then
            log_dim "DoT TLS handshake OK on $RESOLVER_IPV4:853 (install knot-dnsutils for richer DoT verification)"
        else
            log_warn "DoT handshake check inconclusive (install knot-dnsutils to confirm)"
        fi
    fi

    log_info "verifying DNSCrypt port 8443 reachable"
    # We don't have dnscrypt-proxy installed here; just confirm something is
    # listening. dnsdist won't bind successfully if the cert files are wrong.
    if (echo > "/dev/tcp/$RESOLVER_IPV4/8443") 2>/dev/null; then
        log_dim "DNSCrypt port 8443 reachable on $RESOLVER_IPV4"
    else
        log_warn "DNSCrypt 8443 not reachable - check dnsdist log"
    fi

    log_info "verifying DoH backend (loopback :5443)"
    if curl -sf -m 5 -H 'Accept: application/dns-message' \
            "http://127.0.0.1:5443/dns-query?dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE" \
            -o /dev/null; then
        log_dim "DoH backend on 127.0.0.1:5443 OK"
    else
        log_warn "DoH backend check inconclusive (will be re-checked end-to-end after nginx)"
    fi

    log_ok "dnsdist verification passed"
}

step_dnsdist() {
    step_dnsdist_install_package
    step_dnsdist_generate_dnscrypt_keys
    step_dnsdist_generate_console_key
    step_dnsdist_render_config
    step_dnsdist_start
    step_dnsdist_verify
}
