#!/usr/bin/env bash
# =============================================================================
# opennic-tier2-installer - main installer
# =============================================================================
# Stand up an OpenNIC Tier-2 DNS resolver on a fresh Debian 13 host.
#
#   1. Copy install.conf.example to install.conf and edit it.
#   2. sudo bash install.sh
#
# The installer is idempotent: re-run it any time. Each step records its
# completion in /var/lib/opennic-tier2-install/state and is skipped on the
# next run unless the state is cleared. Force a single step to re-run with
# `sudo FORCE=<step-id> bash install.sh`; force everything with FORCE=all.
#
# Logs go to stdout AND /var/log/opennic-tier2-install.log.

set -euo pipefail
shopt -s extglob

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# shellcheck source=lib/helpers.sh
source "$REPO_ROOT/lib/helpers.sh"
# shellcheck source=lib/steps_misc.sh
source "$REPO_ROOT/lib/steps_misc.sh"
# shellcheck source=lib/steps_bind.sh
source "$REPO_ROOT/lib/steps_bind.sh"
# shellcheck source=lib/steps_certbot.sh
source "$REPO_ROOT/lib/steps_certbot.sh"
# shellcheck source=lib/steps_dnsdist.sh
source "$REPO_ROOT/lib/steps_dnsdist.sh"
# shellcheck source=lib/steps_nginx.sh
source "$REPO_ROOT/lib/steps_nginx.sh"

ensure_log_file
ensure_state_dir

trap 'on_exit $?' EXIT

CURRENT_STEP=""

# Config is loaded unconditionally so steps that use $RESOLVER_* etc. work
# regardless of which steps are skipped via state. Preflight does the rest
# (root check, distro warn, DNS sanity) and is itself stateful.
require_root
load_config
validate_config
apply_config_defaults

# Detect install.conf changes and clear step state so the changes actually
# get applied on re-run (rather than skipped via state cache).
detect_config_change

# If the operator flipped LE_STAGING (e.g. true -> false to go live), force
# the certbot step to re-run so it replaces the staging cert with a real one.
_le_dir="/etc/letsencrypt/live/$RESOLVER_HOSTNAME"
if [[ -f "$_le_dir/fullchain.pem" ]]; then
    _issuer="$(openssl x509 -in "$_le_dir/fullchain.pem" -noout -issuer 2>/dev/null || echo "")"
    _cert_staging=0; [[ "$_issuer" == *STAGING* ]] && _cert_staging=1
    _want_staging=0; [[ "$LE_STAGING" == "true" ]]      && _want_staging=1
    if (( _cert_staging != _want_staging )); then
        log_warn "cert/LE_STAGING mismatch - clearing certbot step state to re-run"
        clear_step certbot
    fi
fi
unset _le_dir _issuer _cert_staging _want_staging

run_step preflight             "Preflight: root, distro, config" step_preflight
run_step system_prep           "System prep: apt update + base packages" step_system_prep
run_step unattended_upgrades   "Unattended-upgrades policy"      step_unattended_upgrades
run_step bind                  "BIND9: slaved OpenNIC zones + recursive resolver" step_bind
run_step certbot               "Let's Encrypt certificate"        step_certbot
run_step dnsdist               "dnsdist: Do53 / DoT / DNSCrypt / DoH backend" step_dnsdist
run_step nginx                 "nginx: TLS, info page, DoH proxy" step_nginx
run_step certbot_renewal_hook  "Switch LE renewal to webroot mode" step_certbot_switch_renewal_to_webroot
run_step timers                "Install maintenance timers (refresh, anchor, verify)" step_install_timers
run_step activate              "Final service activation + listener checks" step_activate_services
step_verify() {
    # Per spec: don't fail install if external verification fails (network
    # paths beyond the installer's control). Just print clear status.
    bash "$REPO_ROOT/scripts/verify.sh" || \
        log_warn "verify.sh reported failures; resolver may still be functional - investigate after install completes"
}
run_step verify                "End-to-end verification (scripts/verify.sh)" step_verify

# Summary always prints (not gated on state).
step_summary
