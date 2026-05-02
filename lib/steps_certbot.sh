# shellcheck shell=bash
# Certbot step: issue Let's Encrypt cert for $RESOLVER_HOSTNAME. HTTP-01 with
# standalone is the default; DNS-01 with Cloudflare is the supported alternate.
# Renewals run on certbot.timer.

: "${REPO_ROOT:?REPO_ROOT must be set before sourcing lib/steps_certbot.sh}"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/helpers.sh"

# Path to the LE live dir for our hostname.
_le_live_dir() { printf '/etc/letsencrypt/live/%s' "$RESOLVER_HOSTNAME"; }

step_certbot_install_package() {
    local pkgs=(certbot)
    if [[ "$ACME_CHALLENGE" == "dns-01" ]]; then
        case "$DNS_PROVIDER" in
            cloudflare) pkgs+=(python3-certbot-dns-cloudflare) ;;
        esac
    fi
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if (( ${#missing[@]} > 0 )); then
        log_info "installing: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive run_quiet apt-get install -y -q "${missing[@]}"
    else
        log_dim "certbot packages already installed"
    fi
}

step_certbot_install_deploy_hook() {
    local dst=/etc/letsencrypt/renewal-hooks/deploy/opennic-tier2-installer.sh
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    # Render the hook with RESOLVER_HOSTNAME baked in.
    local rendered; rendered="$(mktemp)"
    RESOLVER_HOSTNAME="$RESOLVER_HOSTNAME" \
        envsubst '${RESOLVER_HOSTNAME}' \
        < "$REPO_ROOT/configs/certbot/deploy-hook.sh.template" \
        > "$rendered"
    install -m 0755 -o root -g root "$rendered" "$dst"
    rm -f "$rendered"
    log_dim "deploy hook installed at $dst"
}

step_certbot_install_dns_credentials() {
    [[ "$ACME_CHALLENGE" == "dns-01" ]] || return 0
    [[ "$DNS_PROVIDER" == "cloudflare" ]] || return 0

    local dst=/etc/letsencrypt/cloudflare.ini
    local rendered; rendered="$(mktemp)"
    DNS_PROVIDER_API_TOKEN="$DNS_PROVIDER_API_TOKEN" \
        envsubst '${DNS_PROVIDER_API_TOKEN}' \
        < "$REPO_ROOT/configs/certbot/cloudflare.ini.template" \
        > "$rendered"
    install -m 0600 -o root -g root "$rendered" "$dst"
    shred -u "$rendered" 2>/dev/null || rm -f "$rendered"
    log_dim "Cloudflare credentials installed at $dst (mode 0600)"
}

# Stop anything listening on port 80 before we run --standalone, and remember
# what we stopped so we can put it back.
_stop_port_80() {
    PORT80_RESTART_LIST=()
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl stop nginx
        PORT80_RESTART_LIST+=("nginx")
        log_dim "stopped nginx temporarily for HTTP-01"
    fi
}

_restart_port_80_holders() {
    for svc in "${PORT80_RESTART_LIST[@]:-}"; do
        [[ -z "$svc" ]] && continue
        log_dim "restarting $svc"
        systemctl start "$svc" || true
    done
    PORT80_RESTART_LIST=()
}

step_certbot_issue() {
    local le_dir; le_dir="$(_le_live_dir)"
    if [[ -f "$le_dir/fullchain.pem" && -f "$le_dir/privkey.pem" ]]; then
        # Existing cert. Re-use unless caller forced us to redo this step.
        # certbot's renew loop handles upcoming expiry; here we just install.
        local subj; subj="$(openssl x509 -in "$le_dir/fullchain.pem" -noout -subject 2>/dev/null || true)"
        log_dim "cert already present for $RESOLVER_HOSTNAME ($subj)"
        return 0
    fi

    local args=(certonly --non-interactive --agree-tos --email "$CERTBOT_EMAIL"
                -d "$RESOLVER_HOSTNAME")
    if [[ "$LE_STAGING" == "true" ]]; then
        args+=(--server https://acme-staging-v02.api.letsencrypt.org/directory)
        log_warn "using Let's Encrypt STAGING - certs will not be browser-trusted"
    fi

    case "$ACME_CHALLENGE" in
        http-01)
            log_info "issuing certificate via HTTP-01 (standalone on port 80)"
            _stop_port_80
            args+=(--standalone --http-01-port 80
                   --preferred-challenges http)
            local rc=0
            certbot "${args[@]}" || rc=$?
            _restart_port_80_holders
            if [[ "$rc" -ne 0 ]]; then
                log_error "certbot failed (rc=$rc); see /var/log/letsencrypt/letsencrypt.log"
                return "$rc"
            fi
            ;;
        dns-01)
            log_info "issuing certificate via DNS-01 ($DNS_PROVIDER)"
            case "$DNS_PROVIDER" in
                cloudflare)
                    args+=(--dns-cloudflare
                           --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini
                           --dns-cloudflare-propagation-seconds 30)
                    ;;
                *)
                    log_error "DNS provider '$DNS_PROVIDER' not implemented"
                    return 1
                    ;;
            esac
            certbot "${args[@]}"
            ;;
    esac

    if [[ ! -f "$le_dir/fullchain.pem" ]]; then
        log_error "certbot reported success but $le_dir/fullchain.pem is missing"
        return 1
    fi
    log_ok "issued cert for $RESOLVER_HOSTNAME"

    # Reconfigure renewal to use webroot once nginx is up. Until nginx exists
    # the standalone method is what we have; the webroot switch happens in
    # step_certbot_switch_renewal_to_webroot, called after nginx step.
}

# After nginx is configured to serve /.well-known/acme-challenge/ from
# /var/www/acme/, switch the renewal authenticator from standalone to webroot
# so future renewals don't need to bounce nginx.
step_certbot_switch_renewal_to_webroot() {
    [[ "$ACME_CHALLENGE" == "http-01" ]] || return 0
    local conf="/etc/letsencrypt/renewal/$RESOLVER_HOSTNAME.conf"
    [[ -f "$conf" ]] || { log_warn "renewal config not found at $conf; skipping renewal-method switch"; return 0; }

    install -d -m 0755 /var/www/acme

    if grep -q '^authenticator = webroot' "$conf"; then
        log_dim "renewal already on webroot method"
        return 0
    fi

    # Replace authenticator + drop standalone-specific options + add webroot
    # config. Idempotent thanks to the sed -i pattern.
    sed -i -E \
        -e 's|^authenticator = standalone$|authenticator = webroot|' \
        -e '/^pref_challs = /d' \
        -e '/^http01_port = /d' \
        -e '/^webroot_path = /d' \
        -e '/^webroot_map = /d' \
        -e '/^\[\[webroot_map\]\]/,$d' \
        "$conf"

    {
        printf 'webroot_path = /var/www/acme,\n'
        printf '[[webroot_map]]\n'
        printf '%s = /var/www/acme\n' "$RESOLVER_HOSTNAME"
    } >> "$conf"

    log_ok "switched LE renewal to webroot mode (path: /var/www/acme)"
}

# Trigger the deploy hook by hand for the freshly-issued cert so that nginx
# and dnsdist immediately have material in /etc/dnsdist/tls/. The hook is
# defensive about unset env vars; we simulate the certbot deploy environment.
step_certbot_run_deploy_hook() {
    local le_dir; le_dir="$(_le_live_dir)"
    [[ -f "$le_dir/fullchain.pem" ]] || { log_warn "no cert to deploy"; return 0; }
    RENEWED_LINEAGE="$le_dir" RENEWED_DOMAINS="$RESOLVER_HOSTNAME" \
        bash /etc/letsencrypt/renewal-hooks/deploy/opennic-tier2-installer.sh
}

step_certbot() {
    step_certbot_install_package
    step_certbot_install_dns_credentials
    step_certbot_install_deploy_hook
    step_certbot_issue
    step_certbot_run_deploy_hook
}
