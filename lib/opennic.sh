# shellcheck shell=bash
# OpenNIC infrastructure helpers: fetch the current Tier-1 nameserver list,
# the active TLD list, and the root KSK; render BIND zone config from them.
#
# Sources from $REPO_ROOT/data/opennic-snapshot.conf as a baseline. Tries a
# best-effort live refresh at install time; falls back to the snapshot if the
# wiki can't be reached or returns garbage.

: "${REPO_ROOT:?REPO_ROOT must be set before sourcing lib/opennic.sh}"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/helpers.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/data/opennic-snapshot.conf"

# After sourcing, $OPENNIC_TIER1_IPS, $OPENNIC_TLDS, $OPENNIC_ROOT_KSK_* are
# set from the snapshot. Live-refresh updates them in place.

# ---------- live verification of Tier-1 IPs -----------------------------------
# Probe each snapshot IP for SOA `.`. Return only those that respond. We don't
# bother with the wiki page parse during install - it's brittle and the snapshot
# is the operator's authoritative starting point. `refresh-opennic-config.sh`
# in scripts/ does the heavier wiki re-parse for offline updates.

opennic_filter_live_tier1() {
    local ip live=()
    for ip in "${OPENNIC_TIER1_IPS[@]}"; do
        if dig "@$ip" . SOA +time=3 +tries=1 +short >/dev/null 2>&1; then
            live+=("$ip")
        fi
    done
    if (( ${#live[@]} == 0 )); then
        log_error "no OpenNIC Tier-1 nameservers reachable from this host"
        log_error "check outbound DNS (53/udp+tcp) and try again"
        return 1
    fi
    if (( ${#live[@]} < 3 )); then
        log_warn "only ${#live[@]} of ${#OPENNIC_TIER1_IPS[@]} Tier-1 IPs reachable; resilience reduced"
    fi
    OPENNIC_TIER1_IPS_LIVE=("${live[@]}")
}

# ---------- fetch live root KSK -----------------------------------------------
# We extract the 257-flag DNSKEY records, pick the first reachable Tier-1 to
# query against, and parse the rdata. If multiple KSKs exist (mid-rollover),
# we emit a trust-anchors entry for each.

opennic_fetch_root_ksk() {
    local source_ip="" answer=""
    for ip in "${OPENNIC_TIER1_IPS_LIVE[@]}"; do
        if answer="$(dig "@$ip" . DNSKEY +noall +answer +tcp +time=10 +tries=2 2>/dev/null)" \
           && [[ -n "$answer" ]]; then
            source_ip="$ip"
            break
        fi
    done

    if [[ -z "$source_ip" ]]; then
        log_warn "could not fetch live OpenNIC root DNSKEY; using snapshot anchor (tag $OPENNIC_ROOT_KSK_TAG)"
        OPENNIC_KSK_RECORDS=("257 3 ${OPENNIC_ROOT_KSK_ALG} ${OPENNIC_ROOT_KSK_KEY}")
        OPENNIC_KSK_SOURCE="snapshot ($REPO_ROOT/data/opennic-snapshot.conf)"
        return 0
    fi

    # Each KSK line: ". TTL IN DNSKEY 257 3 <alg> <key...>"
    # We collect "257 3 <alg> <key>" tuples (possibly several mid-rollover).
    local ksks=()
    while IFS= read -r line; do
        # Extract everything from the literal "257 " onward.
        local tail="${line#*	257 }"
        if [[ "$tail" != "$line" ]]; then
            # Reassemble with the 257 prefix; collapse any leftover whitespace.
            local rec="257 $tail"
            # Some BIND outputs split the key over lines - dig +noall +answer
            # without +multiline keeps it single-line so we should be safe.
            ksks+=("$rec")
        fi
    done <<< "$answer"

    if (( ${#ksks[@]} == 0 )); then
        log_warn "live OpenNIC DNSKEY query returned no KSK; using snapshot"
        OPENNIC_KSK_RECORDS=("257 3 ${OPENNIC_ROOT_KSK_ALG} ${OPENNIC_ROOT_KSK_KEY}")
        OPENNIC_KSK_SOURCE="snapshot ($REPO_ROOT/data/opennic-snapshot.conf)"
        return 0
    fi

    OPENNIC_KSK_RECORDS=("${ksks[@]}")
    OPENNIC_KSK_SOURCE="dig DNSKEY . @${source_ip}"
    log_dim "fetched ${#ksks[@]} KSK record(s) from $source_ip"
}

# ---------- render named.conf.keys --------------------------------------------

opennic_render_keys() {
    local out="$1"
    local refreshed_at; refreshed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    {
        printf '// OpenNIC root DNSSEC trust anchor.\n'
        printf '// Refreshed: %s\n' "$refreshed_at"
        printf '// Source:    %s\n' "$OPENNIC_KSK_SOURCE"
        printf '//\n'
        printf '// To refresh after a key rollover:\n'
        printf '//     sudo /usr/local/sbin/opennic-update-trust-anchor\n'
        printf '//\n'
        printf '// IANA root KSK is handled by BIND'\''s built-in dnssec-validation auto.\n\n'
        printf 'trust-anchors {\n'
        local rec flags proto alg key
        for rec in "${OPENNIC_KSK_RECORDS[@]}"; do
            # rec format: "257 3 <alg> <key>" - split into fields, quote the key.
            read -r flags proto alg key <<< "$rec"
            printf '    . initial-key %s %s %s "%s";\n' "$flags" "$proto" "$alg" "$key"
        done
        printf '};\n'
    } > "$out.tmp"
    mv "$out.tmp" "$out"
}

# ---------- render named.conf.local -------------------------------------------

opennic_render_local() {
    local out="$1"
    local refreshed_at; refreshed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    {
        printf '// opennic-tier2-installer - slaved OpenNIC zones\n'
        printf '// Generated: %s\n' "$refreshed_at"
        printf '// Re-run install.sh, or scripts/refresh-opennic-config.sh, to regenerate.\n\n'

        printf 'masters opennic_tier1 {\n'
        local ip
        for ip in "${OPENNIC_TIER1_IPS_LIVE[@]}"; do
            printf '    %s;\n' "$ip"
        done
        printf '};\n\n'

        if [[ "${SLAVE_OPENNIC_ROOT:-false}" == "true" ]]; then
            # Canonical OpenNIC Tier-2 layout: slaved root contains both ICANN
            # delegations and OpenNIC TLDs. We answer root-level NXDOMAIN
            # authoritatively (AA flag), which trades the dnscrypt-proxy DNSSEC
            # check for full alt-root-replica fidelity.
            printf '// Slaved OpenNIC root.\n'
            printf 'zone "." {\n'
            printf '    type secondary;\n'
            printf '    file "/var/cache/bind/db.root.opennic";\n'
            printf '    primaries { opennic_tier1; };\n'
            printf '    notify no;\n'
            printf '};\n\n'
        else
            # Default layout: IANA root hints handle the root, slaved TLDs
            # handle OpenNIC, a forward zone covers OpenNIC infrastructure
            # under .glue. Yields AD-flagged NXDOMAIN on nonexistent root
            # labels because BIND recurses to the (signed) IANA root.
            printf '// Forward `.glue.` to OpenNIC Tier-1s for infrastructure-only\n'
            printf '// names (ns0.opennic.glue etc.). Light query volume; not a\n'
            printf '// general-purpose forwarder.\n'
            printf 'zone "glue" {\n'
            printf '    type forward;\n'
            printf '    forward only;\n'
            printf '    forwarders {\n'
            for ip in "${OPENNIC_TIER1_IPS_LIVE[@]}"; do
                printf '        %s;\n' "$ip"
            done
            printf '    };\n'
            printf '};\n\n'
        fi

        printf '// OpenNIC TLDs (slaved).\n'
        local tld
        for tld in "${OPENNIC_TLDS[@]}"; do
            printf 'zone "%s" {\n' "$tld"
            printf '    type secondary;\n'
            printf '    file "/var/cache/bind/db.opennic.%s";\n' "$tld"
            printf '    primaries { opennic_tier1; };\n'
            printf '    notify no;\n'
            printf '};\n'
        done
    } > "$out.tmp"
    mv "$out.tmp" "$out"
}
