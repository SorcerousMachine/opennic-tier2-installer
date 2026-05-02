# shellcheck shell=bash
# BIND9 step: install package, generate config, slave OpenNIC zones, validate.

: "${REPO_ROOT:?REPO_ROOT must be set before sourcing lib/steps_bind.sh}"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/helpers.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/opennic.sh"

step_bind_install_package() {
    if dpkg -s bind9 >/dev/null 2>&1; then
        log_dim "bind9 already installed"
    else
        log_info "installing bind9"
        DEBIAN_FRONTEND=noninteractive run_quiet apt-get install -y -q \
            bind9 bind9-dnsutils bind9-doc dns-root-data
    fi
}

step_bind_generate_config() {
    log_info "fetching live OpenNIC infrastructure data"
    opennic_filter_live_tier1
    opennic_fetch_root_ksk

    local stage; stage="$(mktemp -d)"
    log_dim "rendering BIND config in $stage"

    # 1. Top-level named.conf
    cp "$REPO_ROOT/configs/bind/named.conf.template" "$stage/named.conf"

    # 2. options
    cp "$REPO_ROOT/configs/bind/named.conf.options.template" "$stage/named.conf.options"

    # 3. keys (trust anchors)
    opennic_render_keys "$stage/named.conf.keys"

    # 4. local (zones)
    opennic_render_local "$stage/named.conf.local"

    # 5. empty root-hints (the slaved root replaces the hint zone)
    {
        printf '// Intentionally empty.\n'
        printf '// opennic-tier2-installer slaves the root zone from OpenNIC instead\n'
        printf '// of using ICANN root hints; see /etc/bind/named.conf.local.\n'
    } > "$stage/named.conf.root-hints"

    # Install all four files.
    install -m 0644 -o root -g bind "$stage/named.conf"             /etc/bind/named.conf
    install -m 0644 -o root -g bind "$stage/named.conf.options"     /etc/bind/named.conf.options
    install -m 0644 -o root -g bind "$stage/named.conf.keys"        /etc/bind/named.conf.keys
    install -m 0644 -o root -g bind "$stage/named.conf.local"       /etc/bind/named.conf.local
    install -m 0644 -o root -g bind "$stage/named.conf.root-hints"  /etc/bind/named.conf.root-hints

    rm -rf "$stage"

    # /var/cache/bind must be writable by the bind user (it is by default,
    # but ensure that's still true).
    install -d -o bind -g bind -m 0775 /var/cache/bind

    # Stale slaved zone files from a previous install (if any) become invalid
    # once the masters list or zones change. Remove them so BIND re-AXFRs fresh.
    rm -f /var/cache/bind/db.root.opennic /var/cache/bind/db.opennic.* \
          /var/cache/bind/managed-keys.bind /var/cache/bind/managed-keys.bind.jnl

    log_info "validating config with named-checkconf"
    if ! named-checkconf -z 2>&1 | grep -v 'loaded serial' >&2; then
        : # named-checkconf returned 0; informational lines went to stderr above
    fi
    if ! named-checkconf >/dev/null 2>&1; then
        log_error "named-checkconf failed - see /etc/bind/ for the offending file"
        named-checkconf || true
        return 1
    fi
    log_ok "BIND config syntactically valid"
}

step_bind_start() {
    log_info "(re)starting bind9"
    systemctl enable --now named >/dev/null 2>&1 || true
    systemctl restart named

    if ! wait_for_dns_udp 127.0.0.1 5353 30; then
        log_error "BIND did not start listening on 127.0.0.1:5353 within 30s"
        systemctl status named --no-pager | sed -n '1,15p' >&2 || true
        return 1
    fi
    log_ok "BIND listening on 127.0.0.1:5353"
}

step_bind_verify() {
    # Wait for AXFRs to finish. grep.geek is the long-standing OpenNIC canary.
    log_info "waiting for OpenNIC zones to load (AXFR; up to 90s)"
    local end=$(( SECONDS + 90 ))
    local out
    while (( SECONDS < end )); do
        if out="$(dig @127.0.0.1 -p 5353 grep.geek A +time=5 +tries=1 +short 2>/dev/null)" \
           && [[ -n "$out" ]]; then
            break
        fi
        sleep 2
    done
    if [[ -z "${out:-}" ]]; then
        log_error "OpenNIC zone resolution failed: grep.geek did not resolve"
        log_error "check journalctl -u named for AXFR errors"
        return 1
    fi
    log_dim "grep.geek -> $(echo "$out" | head -1)"

    # ICANN recursion via the slaved OpenNIC root can SERVFAIL transiently
    # during the first few seconds while BIND finishes priming. Retry until
    # it works, or up to 30s.
    log_info "verifying ICANN resolution + DNSSEC (AD flag) - up to 30s"
    local response end ok=0
    end=$(( SECONDS + 30 ))
    while (( SECONDS < end )); do
        response="$(dig @127.0.0.1 -p 5353 cloudflare.com A +time=5 +tries=2 2>/dev/null)"
        if grep -q 'status: NOERROR' <<< "$response" \
           && grep -q 'flags:.*ad' <<< "$response"; then
            ok=1; break
        fi
        sleep 2
    done
    if (( ok != 1 )); then
        log_error "cloudflare.com did not validate within 30s; ICANN DNSSEC chain broken"
        log_error "last response:"
        log_error "$response"
        return 1
    fi
    log_dim "cloudflare.com -> $(awk '$4=="A" {print $5; exit}' <<< "$response")  (AD flag set)"

    # OpenNIC zones are answered authoritatively (AA flag) - BIND doesn't set
    # AD on its own auth data. We instead confirm the zone is signed by
    # checking for an RRSIG on +dnssec.
    log_info "verifying OpenNIC zone is signed (RRSIG present)"
    if ! dig @127.0.0.1 -p 5353 grep.geek A +dnssec +time=5 +tries=2 \
            | grep -q 'IN[[:space:]]*RRSIG[[:space:]]*A '; then
        log_warn "grep.geek answer carried no RRSIG - data is unsigned or zone load failed"
    else
        log_ok "OpenNIC zone signed and serving from local slave"
    fi

    log_ok "BIND end-to-end verification passed"
}

# Convenience aggregator for `install.sh` to call as a single step.
step_bind() {
    step_bind_install_package
    step_bind_generate_config
    step_bind_start
    step_bind_verify
}
