#!/usr/bin/env bash
# scripts/uninstall.sh - clean removal for testing iterations and operator
# wind-down. Removes configs, certs, keys, and (with confirmation) packages.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# shellcheck source=../lib/helpers.sh
source "$REPO_ROOT/lib/helpers.sh"
ensure_log_file
require_root

REMOVE_PACKAGES=0
REMOVE_LE_ACCOUNT=0
NON_INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --packages|--purge)  REMOVE_PACKAGES=1 ;;
        --le-account)        REMOVE_LE_ACCOUNT=1 ;;
        --yes|-y)            NON_INTERACTIVE=1 ;;
        --help|-h)
            cat <<EOF
Usage: sudo bash scripts/uninstall.sh [--packages] [--le-account] [--yes]

  --packages     also \`apt purge\` bind9, dnsdist, nginx, certbot
  --le-account   delete the LE account+private key (you'll re-register on next install)
  --yes          skip confirmation prompt
EOF
            exit 0 ;;
        *) log_error "unknown arg: $arg"; exit 2 ;;
    esac
done

if (( NON_INTERACTIVE == 0 )); then
    log_warn "This will REMOVE installed configs, certificates, keys, and slaved zone data."
    log_warn "  Packages removal: $([[ $REMOVE_PACKAGES == 1 ]] && echo YES || echo NO)"
    log_warn "  LE account wipe:  $([[ $REMOVE_LE_ACCOUNT == 1 ]] && echo YES || echo NO)"
    read -r -p "Type 'yes' to continue: " confirm
    [[ "$confirm" == "yes" ]] || { log_info "aborted"; exit 0; }
fi

log_step "stopping services"
for svc in nginx dnsdist named; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

log_step "removing nginx config"
rm -f /etc/nginx/sites-enabled/opennic-resolver
rm -f /etc/nginx/sites-available/opennic-resolver
# Restore Debian's default site if its sibling exists
[[ -f /etc/nginx/sites-available/default ]] && \
    ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

log_step "removing dnsdist config + DNSCrypt keys"
# Provider key is precious - we keep a backup in /root just in case.
if [[ -f /etc/dnsdist/dnscrypt/provider.key ]]; then
    backup="/root/opennic-tier2-provider-key.$(date +%Y%m%d-%H%M%S)"
    cp -p /etc/dnsdist/dnscrypt/provider.key "$backup"
    chmod 0600 "$backup"
    log_warn "provider.key backed up to $backup (delete by hand once you're sure)"
fi
rm -rf /etc/dnsdist/dnscrypt /etc/dnsdist/tls /etc/dnsdist/console.key /etc/dnsdist/dnsdist.conf

log_step "removing BIND custom config + cached slaved zones"
# Restore Debian's stock named.conf if we replaced it.
for f in named.conf named.conf.options named.conf.local named.conf.root-hints; do
    [[ -f "/etc/bind/$f" ]] && rm -f "/etc/bind/$f"
done
rm -f /etc/bind/named.conf.keys
rm -f /var/cache/bind/db.root.opennic /var/cache/bind/db.opennic.* /var/cache/bind/managed-keys.bind /var/cache/bind/managed-keys.bind.jnl

log_step "removing operator info page + ACME webroot"
rm -rf "/var/www/${RESOLVER_HOSTNAME:-}" /var/www/acme

log_step "removing certbot deploy hook + renewal config"
rm -f /etc/letsencrypt/renewal-hooks/deploy/opennic-tier2-installer.sh
if [[ -n "${RESOLVER_HOSTNAME:-}" ]]; then
    [[ -f "/etc/letsencrypt/renewal/${RESOLVER_HOSTNAME}.conf" ]] && \
        rm -f "/etc/letsencrypt/renewal/${RESOLVER_HOSTNAME}.conf"
    [[ -d "/etc/letsencrypt/live/${RESOLVER_HOSTNAME}" ]] && \
        certbot delete --cert-name "$RESOLVER_HOSTNAME" --non-interactive 2>/dev/null || true
fi
rm -f /etc/letsencrypt/cloudflare.ini

if (( REMOVE_LE_ACCOUNT == 1 )); then
    log_step "deleting Let's Encrypt account state"
    rm -rf /etc/letsencrypt/accounts
fi

log_step "removing installer state"
rm -rf /var/lib/opennic-tier2-install
rm -f /etc/apt/apt.conf.d/50unattended-upgrades.opennic-tier2 \
      /etc/apt/apt.conf.d/20auto-upgrades

if (( REMOVE_PACKAGES == 1 )); then
    log_step "purging packages"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -q \
        bind9 bind9-doc bind9-dnsutils \
        dnsdist nginx \
        certbot python3-certbot-dns-cloudflare \
        unattended-upgrades 2>&1 | tail -5 || true
    apt-get autoremove -y -q 2>&1 | tail -3 || true
fi

log_ok "uninstall complete"
log_info "to re-install: cp install.conf.example install.conf, edit, sudo bash install.sh"
