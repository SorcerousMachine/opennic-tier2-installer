# shellcheck shell=bash
# nginx step: server block, info page, ACME webroot, reload.

: "${REPO_ROOT:?REPO_ROOT must be set before sourcing lib/steps_nginx.sh}"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/helpers.sh"

step_nginx_install_package() {
    if dpkg -s nginx >/dev/null 2>&1; then
        log_dim "nginx already installed"
    else
        log_info "installing nginx"
        DEBIAN_FRONTEND=noninteractive run_quiet apt-get install -y -q nginx
    fi
}

step_nginx_disable_default_site() {
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
        log_dim "removed Debian's default nginx site"
    fi
}

step_nginx_render_server_block() {
    log_info "rendering nginx server block"
    local site_avail=/etc/nginx/sites-available/opennic-resolver
    local site_enabl=/etc/nginx/sites-enabled/opennic-resolver

    local rendered; rendered="$(mktemp)"
    RESOLVER_HOSTNAME="$RESOLVER_HOSTNAME" \
        envsubst '${RESOLVER_HOSTNAME}' \
        < "$REPO_ROOT/configs/nginx/resolver.conf.template" \
        > "$rendered"
    install -m 0644 -o root -g root "$rendered" "$site_avail"
    rm -f "$rendered"
    ln -sfn "$site_avail" "$site_enabl"

    install -d -m 0755 -o root -g root /var/www/acme
    install -d -m 0755 -o root -g root "/var/www/$RESOLVER_HOSTNAME"

    log_info "validating nginx config"
    if ! run_quiet nginx -t; then
        log_error "nginx config check failed"
        return 1
    fi
    log_ok "nginx config valid"
}

step_nginx_render_info_page() {
    log_info "preparing operator info page"

    # The deployed page is the operator's source of truth. Render the seed
    # only on a clean install; if the page already exists, leave whatever
    # the operator has put there alone. Stamps are still regenerated below
    # so scripts/print-stamps.sh and the install summary stay current.
    local target="/var/www/$RESOLVER_HOSTNAME/index.html"
    local skip_render=0
    if [[ -f "$target" ]]; then
        log_dim "info page already present at $target; preserving operator edits"
        log_dim "(delete it and re-run if you want the generic template back)"
        skip_render=1
    fi

    # Build optional fragments.
    local region_suffix=""
    [[ -n "${OPERATOR_REGION:-}" ]] && region_suffix=", from ${OPERATOR_REGION}"

    local endpoint_ipv6_do53="" endpoint_ipv6_dnscrypt=""
    if [[ -n "${RESOLVER_IPV6:-}" ]]; then
        endpoint_ipv6_do53=" / [${RESOLVER_IPV6}]:53"
        endpoint_ipv6_dnscrypt=" / [${RESOLVER_IPV6}]:8443"
    fi

    # Posture text varies with SLAVE_OPENNIC_ROOT. The two paragraphs that
    # depend on the architecture choice are computed here and spliced in via
    # envsubst; everything else in the template stays static.
    local intro_dnssec posture_forwarding_li posture_dnssec_li
    if [[ "${SLAVE_OPENNIC_ROOT:-false}" == "true" ]]; then
        intro_dnssec='This resolver speaks four DNS transports and validates DNSSEC against both the IANA root and the OpenNIC root.'
        posture_forwarding_li='<li><strong>No upstream forwarding.</strong> Recursion is local. The OpenNIC root and 16 TLDs are slaved from official Tier-1 nameservers; ICANN names are resolved via standard recursion.</li>'
        posture_dnssec_li='<li><strong>DNSSEC validation.</strong> Both the IANA and OpenNIC root anchors are active trust anchors. Validation failures result in SERVFAIL, not silent acceptance.</li>'
    else
        intro_dnssec='This resolver speaks four DNS transports and validates DNSSEC end-to-end for ICANN names.'
        posture_forwarding_li='<li><strong>No upstream forwarding to public resolvers.</strong> Recursion is local. The 16 OpenNIC TLDs are served from local slaves of official Tier-1 nameservers; ICANN names are resolved via standard recursion.</li>'
        posture_dnssec_li='<li><strong>DNSSEC validation.</strong> ICANN names are validated end-to-end against the IANA root; the AD flag is set on positive and NXDOMAIN responses. The OpenNIC root anchor is also loaded. Validation failures result in SERVFAIL, not silent acceptance.</li>'
    fi

    # Stamps.
    local provider_pub=/etc/dnsdist/dnscrypt/provider.public
    if [[ ! -r "$provider_pub" ]]; then
        log_error "DNSCrypt provider public key not readable at $provider_pub"
        return 1
    fi
    local dc_v4 dc_v6="" doh_stamp ipv6_stamp_block=""
    dc_v4="$(python3 "$REPO_ROOT/lib/make_stamp.py" dnscrypt \
        --addr "${RESOLVER_IPV4}:8443" \
        --provider-name "$DNSCRYPT_PROVIDER_NAME" \
        --public-key "$provider_pub" \
        --dnssec --no-logs --no-filter)" || return 1

    if [[ -n "${RESOLVER_IPV6:-}" ]]; then
        dc_v6="$(python3 "$REPO_ROOT/lib/make_stamp.py" dnscrypt \
            --addr "[${RESOLVER_IPV6}]:8443" \
            --provider-name "$DNSCRYPT_PROVIDER_NAME" \
            --public-key "$provider_pub" \
            --dnssec --no-logs --no-filter)" || return 1
        ipv6_stamp_block="        <span class=\"stamp\" id=\"stamp-ipv6\">${dc_v6}</span>"
    fi

    doh_stamp="$(python3 "$REPO_ROOT/lib/make_stamp.py" doh \
        --hostname "$RESOLVER_HOSTNAME" \
        --path /dns-query \
        --dnssec --no-logs --no-filter)" || return 1

    local generated_at; generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

    if (( skip_render == 0 )); then
        local rendered; rendered="$(mktemp)"
        RESOLVER_HOSTNAME="$RESOLVER_HOSTNAME" \
        RESOLVER_IPV4="$RESOLVER_IPV4" \
        OPERATOR_NAME="$OPERATOR_NAME" \
        OPERATOR_ABUSE_EMAIL="$OPERATOR_ABUSE_EMAIL" \
        OPERATOR_SECURITY_EMAIL="$OPERATOR_SECURITY_EMAIL" \
        OPERATOR_HOMEPAGE_URL="$OPERATOR_HOMEPAGE_URL" \
        DNSCRYPT_PROVIDER_NAME="$DNSCRYPT_PROVIDER_NAME" \
        DNSCRYPT_STAMP_IPV4="$dc_v4" \
        DNSCRYPT_STAMP_IPV6_BLOCK="$ipv6_stamp_block" \
        DOH_STAMP="$doh_stamp" \
        REGION_SUFFIX="$region_suffix" \
        ENDPOINT_IPV6_DO53="$endpoint_ipv6_do53" \
        ENDPOINT_IPV6_DNSCRYPT="$endpoint_ipv6_dnscrypt" \
        INFOPAGE_GENERATED_AT="$generated_at" \
        INTRO_DNSSEC="$intro_dnssec" \
        POSTURE_FORWARDING_LI="$posture_forwarding_li" \
        POSTURE_DNSSEC_LI="$posture_dnssec_li" \
            envsubst '${RESOLVER_HOSTNAME} ${RESOLVER_IPV4} ${OPERATOR_NAME} ${OPERATOR_ABUSE_EMAIL} ${OPERATOR_SECURITY_EMAIL} ${OPERATOR_HOMEPAGE_URL} ${DNSCRYPT_PROVIDER_NAME} ${DNSCRYPT_STAMP_IPV4} ${DNSCRYPT_STAMP_IPV6_BLOCK} ${DOH_STAMP} ${REGION_SUFFIX} ${ENDPOINT_IPV6_DO53} ${ENDPOINT_IPV6_DNSCRYPT} ${INFOPAGE_GENERATED_AT} ${INTRO_DNSSEC} ${POSTURE_FORWARDING_LI} ${POSTURE_DNSSEC_LI}' \
            < "$REPO_ROOT/web/index.html.template" \
            > "$rendered"
        install -m 0644 -o root -g root "$rendered" "$target"
        rm -f "$rendered"
        log_ok "info page rendered at $target"
    fi

    # Save stamps to a file the print-stamps script can read.
    install -d -m 0755 /var/lib/opennic-tier2-install
    {
        printf 'DNSCRYPT_PROVIDER_NAME=%q\n' "$DNSCRYPT_PROVIDER_NAME"
        printf 'DNSCRYPT_STAMP_IPV4=%q\n' "$dc_v4"
        [[ -n "$dc_v6" ]] && printf 'DNSCRYPT_STAMP_IPV6=%q\n' "$dc_v6"
        printf 'DOH_STAMP=%q\n' "$doh_stamp"
        printf 'INFO_PAGE_URL=%q\n' "https://${RESOLVER_HOSTNAME}/"
    } > /var/lib/opennic-tier2-install/stamps.env
    chmod 0644 /var/lib/opennic-tier2-install/stamps.env
}

step_nginx_reload() {
    log_info "(re)loading nginx"
    if ! systemctl is-active --quiet nginx; then
        systemctl enable --now nginx
    else
        systemctl reload nginx
    fi
    sleep 1
    if ! wait_for_tcp "$RESOLVER_IPV4" 443 15; then
        log_error "nginx not listening on $RESOLVER_IPV4:443"
        return 1
    fi
    log_ok "nginx listening on :80 and :443"
}

step_nginx_verify() {
    log_info "verifying HTTPS info page"
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' "https://$RESOLVER_HOSTNAME/" --resolve "$RESOLVER_HOSTNAME:443:$RESOLVER_IPV4")"
    if [[ "$code" != "200" ]]; then
        log_error "https://$RESOLVER_HOSTNAME/ returned HTTP $code (expected 200)"
        return 1
    fi
    log_dim "info page -> HTTP 200"

    log_info "verifying HTTP -> HTTPS redirect"
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://$RESOLVER_IPV4/" -H "Host: $RESOLVER_HOSTNAME")"
    if [[ "$code" != "301" ]]; then
        log_warn "http:// did not return 301 (got $code); check server block"
    else
        log_dim "http:// -> 301 redirect"
    fi

    log_info "verifying DoH end-to-end"
    # RFC 8484 example query: example.com A
    local doh_query="AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"
    if curl -sk -m 5 \
            -H "Accept: application/dns-message" \
            "https://$RESOLVER_HOSTNAME/dns-query?dns=$doh_query" \
            --resolve "$RESOLVER_HOSTNAME:443:$RESOLVER_IPV4" \
            -o /tmp/doh-resp.bin -w '%{http_code}' \
            | grep -q '^200$'; then
        local sz; sz="$(stat -c %s /tmp/doh-resp.bin)"
        rm -f /tmp/doh-resp.bin
        if (( sz > 12 )); then
            log_dim "DoH /dns-query -> 200, ${sz}B response"
        else
            log_warn "DoH returned 200 but body too short ($sz B)"
        fi
    else
        log_warn "DoH check returned non-200 (see /tmp/doh-resp.bin if present)"
    fi

    log_ok "nginx verification passed"
}

step_nginx() {
    step_nginx_install_package
    step_nginx_disable_default_site
    step_nginx_render_server_block
    step_nginx_render_info_page
    step_nginx_reload
    step_nginx_verify
}
