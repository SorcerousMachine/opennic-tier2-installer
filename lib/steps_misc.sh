# shellcheck shell=bash
# Miscellaneous steps: preflight checks, system prep, unattended-upgrades,
# final activation, summary.

: "${REPO_ROOT:?REPO_ROOT must be set before sourcing lib/steps_misc.sh}"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/helpers.sh"

# ---------- preflight ---------------------------------------------------------

step_preflight() {
    # require_root, load_config, validate_config, and apply_config_defaults
    # are run unconditionally by install.sh before any step. This step does
    # the system-shape checks that benefit from being state-tracked.

    log_info "checking Debian release"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        local id version_id; id="$(. /etc/os-release; echo "$ID")"
        version_id="$(. /etc/os-release; echo "$VERSION_ID")"
        if [[ "$id" != "debian" ]]; then
            log_warn "this installer targets Debian; you are on '$id' - proceed at your own risk"
        elif [[ "${version_id%%.*}" != "13" ]]; then
            log_warn "this installer targets Debian 13 (trixie); you are on '$version_id'"
        else
            log_dim "Debian $version_id ✓"
        fi
    else
        log_warn "/etc/os-release not readable; cannot identify distro"
    fi

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt; virt="$(systemd-detect-virt 2>/dev/null || echo none)"
        log_dim "virtualization: $virt"
        if [[ "$virt" == "lxc" ]]; then
            log_warn "running in LXC: ensure host has tuned sysctls (nf_conntrack_max=524288, net.core.{r,w}mem_max=4194304)"
        fi
    fi

    log_dim "RESOLVER_HOSTNAME=$RESOLVER_HOSTNAME RESOLVER_IPV4=$RESOLVER_IPV4 LE_STAGING=$LE_STAGING"

    # Confirm DNS already points at us. We tolerate failure (operator may run
    # this in an air-gapped lab), but warn loudly.
    log_info "checking that $RESOLVER_HOSTNAME resolves to $RESOLVER_IPV4"
    local actual; actual="$(dig +short +time=3 +tries=2 @1.1.1.1 "$RESOLVER_HOSTNAME" A 2>/dev/null | head -1)"
    if [[ -z "$actual" ]]; then
        log_warn "$RESOLVER_HOSTNAME has no A record at 1.1.1.1; HTTP-01 will fail until you add one"
    elif [[ "$actual" != "$RESOLVER_IPV4" ]]; then
        log_warn "$RESOLVER_HOSTNAME resolves to $actual but install.conf says $RESOLVER_IPV4"
    else
        log_dim "DNS A record points correctly"
    fi
    log_ok "preflight passed"
}

# ---------- system prep ------------------------------------------------------

step_system_prep() {
    log_info "apt update"
    DEBIAN_FRONTEND=noninteractive run_quiet apt-get update

    log_info "apt upgrade (security + recommended)"
    DEBIAN_FRONTEND=noninteractive run_quiet apt-get upgrade -y -q

    log_info "ensuring base packages installed"
    local base=(curl jq ca-certificates dnsutils python3 gettext-base openssl
                unattended-upgrades knot-dnsutils)
    DEBIAN_FRONTEND=noninteractive run_quiet apt-get install -y -q "${base[@]}"
}

# ---------- unattended-upgrades ----------------------------------------------

step_unattended_upgrades() {
    log_info "configuring unattended-upgrades policy"
    local reboot_line=""
    local reboot_time_line=""

    case "${AUTO_REBOOT_TIME}" in
        "now")
            reboot_line='Unattended-Upgrade::Automatic-Reboot "true";'
            reboot_time_line='Unattended-Upgrade::Automatic-Reboot-WithUsers "true";'
            ;;
        "")
            reboot_line='Unattended-Upgrade::Automatic-Reboot "false";'
            ;;
        *)
            # Validate HH:MM format.
            if [[ "$AUTO_REBOOT_TIME" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
                reboot_line='Unattended-Upgrade::Automatic-Reboot "true";'
                reboot_time_line="Unattended-Upgrade::Automatic-Reboot-Time \"${AUTO_REBOOT_TIME}\";"
            else
                log_warn "AUTO_REBOOT_TIME='$AUTO_REBOOT_TIME' is not 'now' or HH:MM; disabling auto-reboot"
                reboot_line='Unattended-Upgrade::Automatic-Reboot "false";'
            fi
            ;;
    esac

    local rendered; rendered="$(mktemp)"
    AUTO_REBOOT_LINE="$reboot_line" \
    AUTO_REBOOT_TIME_LINE="$reboot_time_line" \
    CERTBOT_EMAIL="$CERTBOT_EMAIL" \
        envsubst '${AUTO_REBOOT_LINE} ${AUTO_REBOOT_TIME_LINE} ${CERTBOT_EMAIL}' \
        < "$REPO_ROOT/configs/unattended-upgrades/50unattended-upgrades.template" \
        > "$rendered"
    install -m 0644 -o root -g root "$rendered" /etc/apt/apt.conf.d/50unattended-upgrades
    rm -f "$rendered"

    # Activate the timer.
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    chmod 0644 /etc/apt/apt.conf.d/20auto-upgrades

    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    log_ok "unattended-upgrades configured (reboot policy: ${AUTO_REBOOT_TIME:-disabled})"
}

# ---------- service activation ------------------------------------------------

step_activate_services() {
    log_info "ensuring services are enabled and running"
    local svc
    for svc in named dnsdist nginx certbot.timer unattended-upgrades; do
        if ! systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl enable "$svc" >/dev/null 2>&1 || true
        fi
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl start "$svc" || true
        fi
    done

    log_info "verifying expected listeners"
    # Tuples of "<bind>:<port>/<proto>/<service>". Bind matches either the
    # specific address or 0.0.0.0/[::] wildcard for that port.
    local listeners=(
        "127.0.0.1:5353/udp/named"
        "$RESOLVER_IPV4:53/tcp/dnsdist"
        "$RESOLVER_IPV4:853/tcp/dnsdist"
        "$RESOLVER_IPV4:8443/tcp/dnsdist"
        "127.0.0.1:5443/tcp/dnsdist"
        "*:80/tcp/nginx"
        "*:443/tcp/nginx"
    )
    local all_ok=1 entry addr port proto svc
    for entry in "${listeners[@]}"; do
        local spec="${entry%%/*}"
        port="${spec##*:}"
        addr="${spec%:*}"
        local rest="${entry#*/}"
        proto="${rest%%/*}"
        svc="${rest##*/}"

        local flag
        case "$proto" in tcp) flag="-tln" ;; udp) flag="-uln" ;; *) flag="" ;; esac
        local listening; listening="$(ss "$flag" 2>/dev/null | awk -v p=":$port" 'NR>1 && index($4, p) {print $4}')"

        local matched=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # `*` matches any bind address; otherwise compare directly or
            # against the wildcard bind for the same port.
            if [[ "$addr" == "*" ]] \
               || [[ "$line" == "$addr:$port" ]] \
               || [[ "$line" == "0.0.0.0:$port" ]] \
               || [[ "$line" == "[::]:$port" ]] \
               || [[ "$line" == "*:$port" ]]; then
                matched=1
                break
            fi
        done <<< "$listening"

        if (( matched == 1 )); then
            log_dim "$entry ✓"
        else
            log_warn "$entry not listening (saw: $(tr '\n' ' ' <<< "$listening"))"
            all_ok=0
        fi
    done
    (( all_ok == 1 )) && log_ok "all expected listeners are up"
}

# ---------- summary ----------------------------------------------------------

step_summary() {
    local stamps_env=/var/lib/opennic-tier2-install/stamps.env
    [[ -r "$stamps_env" ]] && source "$stamps_env"

    cat <<EOF

${C_BOLD}========================================================================
  opennic-tier2-installer - installation complete
========================================================================${C_RESET}

${C_BOLD}Resolver hostname:${C_RESET}     $RESOLVER_HOSTNAME
${C_BOLD}Public IPv4:${C_RESET}           $RESOLVER_IPV4${RESOLVER_IPV6:+
${C_BOLD}Public IPv6:${C_RESET}           $RESOLVER_IPV6}
${C_BOLD}Operator info page:${C_RESET}    https://$RESOLVER_HOSTNAME/

${C_BOLD}Endpoints:${C_RESET}
  Do53      $RESOLVER_IPV4:53${RESOLVER_IPV6:+, [$RESOLVER_IPV6]:53}
  DoT       $RESOLVER_HOSTNAME:853
  DoH       https://$RESOLVER_HOSTNAME/dns-query
  DNSCrypt  $RESOLVER_IPV4:8443${RESOLVER_IPV6:+, [$RESOLVER_IPV6]:8443}

${C_BOLD}DNSCrypt provider name:${C_RESET}
  ${DNSCRYPT_PROVIDER_NAME:-2.dnscrypt-cert.$RESOLVER_HOSTNAME}

${C_BOLD}DNSCrypt server stamp (IPv4):${C_RESET}
  ${DNSCRYPT_STAMP_IPV4:-(unavailable; run scripts/print-stamps.sh)}
${DNSCRYPT_STAMP_IPV6:+
${C_BOLD}DNSCrypt server stamp (IPv6):${C_RESET}
  $DNSCRYPT_STAMP_IPV6
}
${C_BOLD}DoH server stamp:${C_RESET}
  ${DOH_STAMP:-(unavailable; run scripts/print-stamps.sh)}

${C_BOLD}${C_YELLOW}NEXT STEPS:${C_RESET}
  1. ${C_BOLD}Back up /etc/dnsdist/dnscrypt/provider.key NOW.${C_RESET}
     If you lose it, you'll have to rotate the provider name, which
     invalidates every stamp anyone has stored.

  2. Apply for OpenNIC Tier-2 listing:
       https://wiki.opennic.org/opennic/tier2

  3. Submit DNSCrypt + DoH stamps to the public DNSCrypt registry:
       https://github.com/DNSCrypt/dnscrypt-resolvers

  4. Subscribe to the OpenNIC mailing list to get notified about trust
     anchor rollovers and infrastructure changes.

  5. Run ${C_BOLD}sudo bash $REPO_ROOT/scripts/verify.sh${C_RESET} from time to
     time to confirm everything still works.

${C_BOLD}If LE_STAGING is currently true, switch it to false in install.conf
and re-run install.sh to issue a real (publicly-trusted) certificate.${C_RESET}

EOF
}
