# shellcheck shell=bash
# Common helpers for install.sh and scripts/*. Source this from a script that
# has already set `set -euo pipefail`.

# ---------- paths -------------------------------------------------------------

# REPO_ROOT is set by the caller (install.sh) before sourcing. Helper scripts
# that source this file directly should set it themselves.
: "${REPO_ROOT:?REPO_ROOT must be set before sourcing lib/helpers.sh}"

STATE_DIR="/var/lib/opennic-tier2-install"
STATE_FILE="$STATE_DIR/state"
LOG_FILE="/var/log/opennic-tier2-install.log"
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/install.conf}"

# ---------- colors ------------------------------------------------------------

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_BLUE=$'\033[34m'
    C_DIM=$'\033[2m'
else
    C_RESET="" C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_BLUE="" C_DIM=""
fi

# ---------- logging -----------------------------------------------------------
# All log_* functions write to stdout AND append to LOG_FILE. Color is only
# applied to stdout. The caller is responsible for ensuring LOG_FILE exists
# (see ensure_log_file).

ensure_log_file() {
    if [[ ! -f "$LOG_FILE" ]]; then
        install -m 0640 -o root -g adm /dev/null "$LOG_FILE" 2>/dev/null \
            || { mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"; chmod 0640 "$LOG_FILE"; }
    fi
}

_log_to_file() {
    # Strip any trailing newline, prefix with timestamp, append.
    local msg="$1"
    printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()  { local m="$*"; printf '%s[*]%s %s\n' "$C_BLUE"   "$C_RESET" "$m"; _log_to_file "[INFO]  $m"; }
log_ok()    { local m="$*"; printf '%s[+]%s %s\n' "$C_GREEN"  "$C_RESET" "$m"; _log_to_file "[OK]    $m"; }
log_warn()  { local m="$*"; printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$m" >&2; _log_to_file "[WARN]  $m"; }
log_error() { local m="$*"; printf '%s[x]%s %s\n' "$C_RED"    "$C_RESET" "$m" >&2; _log_to_file "[ERROR] $m"; }
log_step()  { local m="$*"; printf '\n%s== %s ==%s\n' "$C_BOLD" "$m" "$C_RESET"; _log_to_file "[STEP]  $m"; }
log_dim()   { local m="$*"; printf '%s    %s%s\n' "$C_DIM" "$m" "$C_RESET"; _log_to_file "[INFO]  $m"; }

# ---------- error trap --------------------------------------------------------
# Caller installs this with: trap 'on_exit $?' EXIT
on_exit() {
    local rc="${1:-0}"
    if [[ "$rc" -ne 0 ]]; then
        log_error "installer exited with status $rc"
        log_error "step in progress: ${CURRENT_STEP:-<unknown>}"
        log_error "see $LOG_FILE for details"
    fi
    return "$rc"
}

# ---------- idempotence: per-step state ---------------------------------------
# Each major step calls run_step <id> <description> <function-name>. If <id>
# is recorded in the state file, the step is skipped. The function is invoked
# with no arguments; on success the step id is recorded.

ensure_state_dir() {
    install -d -m 0750 "$STATE_DIR"
    [[ -f "$STATE_FILE" ]] || { touch "$STATE_FILE"; chmod 0640 "$STATE_FILE"; }
}

step_done() {
    local id="$1"
    [[ -f "$STATE_FILE" ]] && grep -qFx "$id" "$STATE_FILE"
}

mark_step_done() {
    local id="$1"
    ensure_state_dir
    step_done "$id" || printf '%s\n' "$id" >> "$STATE_FILE"
}

clear_step() {
    local id="$1"
    [[ -f "$STATE_FILE" ]] || return 0
    local tmp; tmp="$(mktemp)"
    grep -vFx "$id" "$STATE_FILE" > "$tmp" || true
    mv "$tmp" "$STATE_FILE"
}

run_step() {
    local id="$1" desc="$2" fn="$3"
    CURRENT_STEP="$id"
    if step_done "$id"; then
        log_step "$desc"
        log_dim "already complete (skipped); re-run with FORCE=$id to redo"
        if [[ "${FORCE:-}" == "$id" || "${FORCE:-}" == "all" ]]; then
            log_warn "FORCE set; re-running step $id"
            clear_step "$id"
        else
            CURRENT_STEP=""
            return 0
        fi
    else
        log_step "$desc"
    fi
    "$fn"
    mark_step_done "$id"
    CURRENT_STEP=""
}

# ---------- config loading and validation -------------------------------------

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "this script must be run as root (try: sudo bash $0)"
        exit 1
    fi
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "config file not found: $CONFIG_FILE"
        log_error "copy install.conf.example to install.conf and edit it"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

# Validates a string against a regex; logs and returns 1 on mismatch.
# Used by validate_config for hostnames/IPs/emails.
_match() {
    local name="$1" value="$2" pattern="$3"
    if [[ -z "$value" ]]; then
        log_error "config: $name is empty"
        return 1
    fi
    if ! [[ "$value" =~ $pattern ]]; then
        log_error "config: $name='$value' does not match expected format"
        return 1
    fi
    return 0
}

# Detects placeholder-y values from the example config so users can't run with
# unedited defaults.
_is_placeholder() {
    local v="$1"
    case "$v" in
        ""|"dns.example.org"|"203.0.113.10"|"hostmaster@example.org"|\
        "Example Tier-2 Operator"|"abuse@example.org"|"security@example.org")
            return 0 ;;
    esac
    return 1
}

validate_config() {
    local rc=0
    local required=(
        RESOLVER_HOSTNAME RESOLVER_IPV4 CERTBOT_EMAIL
        OPERATOR_NAME OPERATOR_ABUSE_EMAIL OPERATOR_SECURITY_EMAIL
    )
    for var in "${required[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "config: $var is required (set it in $CONFIG_FILE)"
            rc=1
        elif _is_placeholder "${!var}"; then
            log_error "config: $var still has its placeholder value '${!var}'"
            rc=1
        fi
    done

    # Hostname: lowercase letters, digits, dots, hyphens.
    _match RESOLVER_HOSTNAME "${RESOLVER_HOSTNAME:-}" '^[a-z0-9][a-z0-9.-]*[a-z0-9]$' || rc=1

    # IPv4 dotted quad. Loose check; full octet validation isn't needed because
    # the kernel will refuse to bind a malformed address later.
    _match RESOLVER_IPV4 "${RESOLVER_IPV4:-}" '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || rc=1

    # IPv6 only if non-empty.
    if [[ -n "${RESOLVER_IPV6:-}" ]]; then
        _match RESOLVER_IPV6 "$RESOLVER_IPV6" '^[0-9a-fA-F:]+$' || rc=1
    fi

    # Emails: trivial check.
    for var in CERTBOT_EMAIL OPERATOR_ABUSE_EMAIL OPERATOR_SECURITY_EMAIL; do
        _match "$var" "${!var:-}" '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$' || rc=1
    done

    # ACME challenge.
    case "${ACME_CHALLENGE:-http-01}" in
        http-01|dns-01) ;;
        *) log_error "config: ACME_CHALLENGE must be 'http-01' or 'dns-01' (got '${ACME_CHALLENGE}')"; rc=1 ;;
    esac

    if [[ "${ACME_CHALLENGE:-http-01}" == "dns-01" ]]; then
        case "${DNS_PROVIDER:-cloudflare}" in
            cloudflare) ;;
            *) log_error "config: DNS_PROVIDER='$DNS_PROVIDER' is not supported. Currently only 'cloudflare' is shipped; see CONTRIBUTING for adding more."; rc=1 ;;
        esac
        if [[ -z "${DNS_PROVIDER_API_TOKEN:-}" ]] || [[ "$DNS_PROVIDER_API_TOKEN" == "your-cloudflare-api-token" ]]; then
            log_error "config: DNS_PROVIDER_API_TOKEN is required when ACME_CHALLENGE=dns-01"
            rc=1
        fi
    fi

    if [[ "${LE_STAGING:-false}" != "true" && "${LE_STAGING:-false}" != "false" ]]; then
        log_error "config: LE_STAGING must be 'true' or 'false'"
        rc=1
    fi

    if [[ "${SLAVE_OPENNIC_ROOT:-false}" != "true" && "${SLAVE_OPENNIC_ROOT:-false}" != "false" ]]; then
        log_error "config: SLAVE_OPENNIC_ROOT must be 'true' or 'false'"
        rc=1
    fi

    return "$rc"
}

# Apply defaults for optional fields that other code expects to be set.
apply_config_defaults() {
    : "${RESOLVER_IPV6:=}"
    : "${ACME_CHALLENGE:=http-01}"
    : "${DNS_PROVIDER:=cloudflare}"
    : "${DNS_PROVIDER_API_TOKEN:=}"
    : "${LE_STAGING:=false}"
    : "${OPERATOR_REGION:=}"
    : "${AUTO_REBOOT_TIME:=now}"
    : "${SLAVE_OPENNIC_ROOT:=false}"
    : "${DNSDIST_VERSION:=}"
    : "${QUICHE_VERSION:=}"

    if [[ -z "${DNSCRYPT_PROVIDER_NAME:-}" ]]; then
        DNSCRYPT_PROVIDER_NAME="2.dnscrypt-cert.${RESOLVER_HOSTNAME}"
    fi
    if [[ -z "${OPERATOR_HOMEPAGE_URL:-}" ]]; then
        OPERATOR_HOMEPAGE_URL="https://${RESOLVER_HOSTNAME}/"
    fi

    export RESOLVER_HOSTNAME RESOLVER_IPV4 RESOLVER_IPV6
    export CERTBOT_EMAIL OPERATOR_NAME OPERATOR_ABUSE_EMAIL OPERATOR_SECURITY_EMAIL
    export OPERATOR_REGION OPERATOR_HOMEPAGE_URL
    export ACME_CHALLENGE DNS_PROVIDER DNS_PROVIDER_API_TOKEN LE_STAGING
    export DNSCRYPT_PROVIDER_NAME AUTO_REBOOT_TIME SLAVE_OPENNIC_ROOT
    export DNSDIST_VERSION QUICHE_VERSION
}

# ---------- install.conf change detection (idempotent re-runs) ----------------
# Compares the hash of the current install.conf against the one stored from
# the last successful install.sh run. If they differ, clears step state so
# all config-rendering steps re-run with the new values. The first run (no
# stored hash) just records the hash without clearing anything.
detect_config_change() {
    ensure_state_dir
    local hash_file="$STATE_DIR/install-conf.sha256"
    local current_hash; current_hash="$(sha256sum "$CONFIG_FILE" 2>/dev/null | cut -d' ' -f1)"
    local stored_hash=""
    [[ -r "$hash_file" ]] && stored_hash="$(cat "$hash_file" 2>/dev/null)"

    if [[ -n "$stored_hash" && "$current_hash" != "$stored_hash" ]]; then
        log_warn "install.conf changed since last run; reapplying all steps"
        if [[ -f "$STATE_FILE" ]]; then
            cp -p "$STATE_FILE" "$STATE_FILE.bak.$(date +%s)"
            : > "$STATE_FILE"
        fi
    fi

    printf '%s\n' "$current_hash" > "$hash_file"
    chmod 0640 "$hash_file"
}

# ---------- templating --------------------------------------------------------
# Substitutes ${VAR} references in a template with values from the environment.
# Uses envsubst so we can name a precise variable list and avoid touching any
# `$variable` strings the template embeds intentionally (e.g. nginx config).

render_template() {
    local src="$1" dst="$2"
    shift 2
    # Build the variable list as ${VAR1} ${VAR2} ... for envsubst.
    local vars=""
    for v in "$@"; do vars+="\${$v} "; done
    if [[ -z "$vars" ]]; then
        log_error "render_template: refusing to render with empty variable list (would expand all env vars)"
        return 1
    fi
    if [[ ! -f "$src" ]]; then
        log_error "render_template: missing source $src"
        return 1
    fi
    envsubst "$vars" < "$src" > "$dst.tmp"
    mv "$dst.tmp" "$dst"
}

# Atomically install a generated file to a system path with given mode/owner,
# only if its content has actually changed. Returns 0=unchanged, 1=installed.
install_file_if_changed() {
    local src="$1" dst="$2" mode="${3:-0644}" owner="${4:-root:root}"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        return 0
    fi
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dst"
    return 1
}

# ---------- shell utilities ---------------------------------------------------

# Run a command, capturing both streams to the install log; print stderr on
# failure. Use this for commands whose normal output is noise (apt, etc.) but
# whose failure mode you want to see clearly.
run_quiet() {
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    if (( rc != 0 )); then
        log_error "command failed: $*"
        printf '%s\n' "$out" >&2
        printf '%s\n' "$out" >> "$LOG_FILE" 2>/dev/null || true
        return "$rc"
    fi
    printf '%s\n' "$out" >> "$LOG_FILE" 2>/dev/null || true
    return 0
}

# Wait until a TCP port on a given host is reachable, with a timeout.
wait_for_tcp() {
    local host="$1" port="$2" timeout="${3:-30}"
    local end=$(( SECONDS + timeout ))
    while (( SECONDS < end )); do
        if (echo > "/dev/tcp/$host/$port") 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Wait until a UDP DNS server answers a SOA query for `.` with a timeout.
wait_for_dns_udp() {
    local host="$1" port="${2:-53}" timeout="${3:-30}"
    local end=$(( SECONDS + timeout ))
    while (( SECONDS < end )); do
        if dig "@$host" -p "$port" . SOA +time=1 +tries=1 +short >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}
