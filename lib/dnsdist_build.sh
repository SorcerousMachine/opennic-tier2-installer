# shellcheck shell=bash
# Source build for dnsdist with quiche (DNS-over-QUIC + DNS-over-HTTP/3).
#
# Builds quiche (Cloudflare) and dnsdist (PowerDNS) from upstream git tags
# into /opt/dnsdist on the live host. Build deps are installed via apt with
# `apt-mark auto` so a post-build `autoremove --purge` cleans them up. Runtime
# libs (libluajit, libsodium, libssl, libcap, libnghttp2, libsystemd) are
# installed as manual and survive the autoremove.
#
# State: /var/lib/opennic-tier2-install/dnsdist-build.meta records the built
# dnsdist tag and quiche tag plus apt before/after snapshots; re-runs that
# resolve to the same versions are no-ops.

: "${REPO_ROOT:?REPO_ROOT must be set before sourcing lib/dnsdist_build.sh}"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/helpers.sh"

DNSDIST_PREFIX=/opt/dnsdist
DNSDIST_BUILD_ROOT=/var/tmp/opennic-tier2-dnsdist-build
DNSDIST_BUILD_META="$STATE_DIR/dnsdist-build.meta"
DNSDIST_BUILD_DPKG_BEFORE="$STATE_DIR/dnsdist-build.dpkg-before"
DNSDIST_BUILD_DPKG_AFTER="$STATE_DIR/dnsdist-build.dpkg-after"

# Runtime libraries that must stay installed after autoremove. Listed
# explicitly (not just derived from -dev packages) because Debian package
# names don't always pair cleanly with their development counterparts.
DNSDIST_RUNTIME_PACKAGES=(
    libluajit-5.1-2
    libsodium23
    libcap2
    libnghttp2-14
    libsystemd0
    libssl3t64
    libedit2
    libfstrm0
    libre2-11
    libcdb1
)

# Build-only deps. Installed as auto (apt-mark auto) so autoremove --purge
# clears them after the build completes.
DNSDIST_BUILD_PACKAGES=(
    build-essential
    meson
    ninja-build
    pkg-config
    git
    ca-certificates
    rustc
    cargo
    cmake
    golang-go
    perl
    ragel
    python3-yaml
    libboost-context-dev
    libboost-program-options-dev
    libboost-system-dev
    libboost-test-dev
    libluajit-5.1-dev
    libsodium-dev
    libcap-dev
    libnghttp2-dev
    libsystemd-dev
    systemd-dev
    libssl-dev
    libedit-dev
    libfstrm-dev
    libre2-dev
    libcdb-dev
    python3-virtualenv
    python3-venv
)

# ---------- version resolution -----------------------------------------------

# Resolve "latest stable" tags via `git ls-remote`. Operators can pin via
# DNSDIST_VERSION / QUICHE_VERSION in install.conf; empty = follow latest.
dnsdist_build_resolve_versions() {
    if [[ -n "${DNSDIST_VERSION:-}" ]]; then
        DNSDIST_RESOLVED_VERSION="$DNSDIST_VERSION"
        log_dim "dnsdist version pinned to $DNSDIST_RESOLVED_VERSION"
    else
        log_info "resolving latest dnsdist 2.0.x tag"
        DNSDIST_RESOLVED_VERSION="$(
            git ls-remote --tags https://github.com/PowerDNS/pdns.git 'refs/tags/dnsdist-2.0.*' \
                2>/dev/null \
                | awk '{print $2}' \
                | sed 's|refs/tags/dnsdist-||; s|\^{}$||' \
                | sort -uV \
                | tail -1
        )"
        if [[ -z "$DNSDIST_RESOLVED_VERSION" ]]; then
            log_error "could not resolve latest dnsdist 2.0.x tag from github"
            return 1
        fi
        log_info "  -> dnsdist-$DNSDIST_RESOLVED_VERSION"
    fi

    if [[ -n "${QUICHE_VERSION:-}" ]]; then
        QUICHE_RESOLVED_VERSION="$QUICHE_VERSION"
        log_dim "quiche version pinned to $QUICHE_RESOLVED_VERSION"
    else
        log_info "resolving latest quiche 0.x tag"
        QUICHE_RESOLVED_VERSION="$(
            git ls-remote --tags https://github.com/cloudflare/quiche.git \
                2>/dev/null \
                | awk '{print $2}' \
                | sed 's|refs/tags/||; s|\^{}$||' \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
                | sort -uV \
                | tail -1
        )"
        if [[ -z "$QUICHE_RESOLVED_VERSION" ]]; then
            log_error "could not resolve latest quiche tag from github"
            return 1
        fi
        log_info "  -> quiche $QUICHE_RESOLVED_VERSION"
    fi

    export DNSDIST_RESOLVED_VERSION QUICHE_RESOLVED_VERSION
}

# Returns 0 if the build artifacts at /opt/dnsdist already match the
# resolved versions (no rebuild needed). Forces rebuild if anything is
# missing or version-mismatched.
dnsdist_build_is_current() {
    [[ -x "$DNSDIST_PREFIX/bin/dnsdist" ]] || return 1
    [[ -r "$DNSDIST_BUILD_META" ]] || return 1
    local built_dnsdist="" built_quiche=""
    # shellcheck disable=SC1090
    source "$DNSDIST_BUILD_META"
    [[ "$built_dnsdist" == "$DNSDIST_RESOLVED_VERSION" ]] || return 1
    [[ "$built_quiche"  == "$QUICHE_RESOLVED_VERSION"  ]] || return 1
    return 0
}

# ---------- apt orchestration ------------------------------------------------

dnsdist_build_snapshot_dpkg() {
    local dest="$1"
    dpkg --get-selections | awk '$2 == "install"{print $1}' | sort > "$dest"
}

dnsdist_build_install_runtime_deps() {
    log_info "installing dnsdist runtime libraries (manual; survive cleanup)"
    DEBIAN_FRONTEND=noninteractive run_quiet apt-get install -y -q --no-install-recommends \
        "${DNSDIST_RUNTIME_PACKAGES[@]}"
    # Belt-and-suspenders: any of these previously auto-installed (e.g. by the
    # distro dnsdist package) gets re-marked manual so autoremove leaves them
    # alone.
    apt-mark manual "${DNSDIST_RUNTIME_PACKAGES[@]}" >/dev/null 2>&1 || true
}

# Install build deps. We snapshot the apt-mark "manual" set *before* the
# install so we know which packages the operator had explicitly installed
# (e.g. a developer's pre-existing build-essential, git, or python3-venv).
# Anything from our build list that was NOT in that pre-existing manual set
# gets marked auto, so a later autoremove --purge reaps it. Packages the
# operator had installed manually before we touched the box are left alone.
dnsdist_build_install_build_deps() {
    log_info "installing dnsdist build dependencies"
    local pre_manual
    pre_manual="$(apt-mark showmanual 2>/dev/null)"

    DEBIAN_FRONTEND=noninteractive run_quiet apt-get install -y -q --no-install-recommends \
        "${DNSDIST_BUILD_PACKAGES[@]}"

    local pkg to_auto=()
    for pkg in "${DNSDIST_BUILD_PACKAGES[@]}"; do
        if ! grep -Fxq "$pkg" <<<"$pre_manual"; then
            to_auto+=("$pkg")
        fi
    done

    if (( ${#to_auto[@]} > 0 )); then
        log_info "marking ${#to_auto[@]} build packages auto (will be removed post-build)"
        apt-mark auto "${to_auto[@]}" >/dev/null 2>&1 || true
        printf '%s\n' "${to_auto[@]}" > "$STATE_DIR/dnsdist-build.auto-marked"
        chmod 0644 "$STATE_DIR/dnsdist-build.auto-marked"
    else
        log_dim "all build packages were already installed manually; nothing auto-marked"
        : > "$STATE_DIR/dnsdist-build.auto-marked"
    fi
}

# Post-build: remove anything marked auto and no longer needed. Runtime libs
# (marked manual above) are safe.
dnsdist_build_apt_cleanup() {
    log_info "removing build-only packages via apt-get autoremove --purge"
    DEBIAN_FRONTEND=noninteractive run_quiet apt-get autoremove --purge -y -q
}

# ---------- quiche build -----------------------------------------------------

dnsdist_build_quiche() {
    local src="$DNSDIST_BUILD_ROOT/quiche"
    log_info "cloning quiche $QUICHE_RESOLVED_VERSION (with submodules for BoringSSL)"
    rm -rf "$src"
    run_quiet git clone --depth 1 --branch "$QUICHE_RESOLVED_VERSION" \
        --recurse-submodules --shallow-submodules \
        https://github.com/cloudflare/quiche.git "$src" \
        || { log_error "quiche clone failed"; return 1; }

    log_info "building quiche (cargo build --release --features ffi; this takes a few minutes)"
    (
        cd "$src" && run_quiet cargo build --release --features ffi --package quiche
    ) || { log_error "quiche cargo build failed"; return 1; }

    local libdir="$DNSDIST_PREFIX/lib"
    local incdir="$DNSDIST_PREFIX/include"
    local pcdir="$libdir/pkgconfig"
    install -d -m 0755 "$libdir" "$incdir" "$pcdir"

    # Install the dynamic library, the public header, and a pkg-config file
    # so dnsdist's meson dependency('quiche') resolves cleanly.
    install -m 0644 "$src/target/release/libquiche.so" "$libdir/libquiche.so.0"
    ln -sf libquiche.so.0 "$libdir/libquiche.so"
    install -m 0644 "$src/quiche/include/quiche.h" "$incdir/quiche.h"

    cat > "$pcdir/quiche.pc" <<EOF
prefix=$DNSDIST_PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: quiche
Description: Cloudflare QUIC implementation
Version: $QUICHE_RESOLVED_VERSION
Libs: -L\${libdir} -lquiche
Cflags: -I\${includedir}
EOF

    ldconfig -n "$libdir"
    log_ok "quiche $QUICHE_RESOLVED_VERSION installed under $DNSDIST_PREFIX"
}

# ---------- dnsdist build ----------------------------------------------------

dnsdist_build_dnsdist() {
    local src="$DNSDIST_BUILD_ROOT/pdns"
    log_info "cloning dnsdist $DNSDIST_RESOLVED_VERSION from PowerDNS/pdns"
    rm -rf "$src"
    run_quiet git clone --depth 1 --branch "dnsdist-$DNSDIST_RESOLVED_VERSION" \
        https://github.com/PowerDNS/pdns.git "$src"

    log_info "configuring dnsdist (meson) with quiche + dnscrypt + DoH/DoT/DoQ/DoH3"
    # dnsdist's meson.build doesn't propagate quiche's cflags to the executable
    # target (assumes quiche is on a default search path). CPATH/LIBRARY_PATH
    # exported in the build subshells make the compiler/linker find quiche.h
    # and libquiche.so during the ninja build without patching upstream.
    (
        export CPATH="$DNSDIST_PREFIX/include${CPATH:+:$CPATH}"
        export LIBRARY_PATH="$DNSDIST_PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
        export PKG_CONFIG_PATH="$DNSDIST_PREFIX/lib/pkgconfig"
        cd "$src/pdns/dnsdistdist" && \
        run_quiet meson setup build \
            --prefix="$DNSDIST_PREFIX" \
            --buildtype=release \
            -Ddnscrypt=enabled \
            -Ddns-over-tls=enabled \
            -Ddns-over-https=enabled \
            -Ddns-over-quic=enabled \
            -Ddns-over-http3=enabled \
            -Dquiche=enabled \
            -Dnghttp2=enabled \
            -Dtls-libssl=enabled \
            -Dtls-gnutls=disabled \
            -Dlua=luajit \
            -Dlibsodium=enabled \
            -Dre2=enabled \
            -Dcdb=enabled \
            -Dlmdb=disabled \
            -Dh2o=disabled \
            -Dyaml=disabled \
            -Dsystemd-service=disabled
    ) || { log_error "dnsdist meson setup failed"; return 1; }

    # dnsdist.cc at -O3 needs ~1.5 GB of RAM per cc1plus process. Cap ninja
    # parallelism so we don't get OOM-killed on 2-4 GB VMs (the typical size
    # for a small Tier-2 resolver).
    local mem_mb cpu_count jobs
    mem_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)"
    cpu_count="$(nproc 2>/dev/null || echo 1)"
    jobs=$(( mem_mb / 1500 ))
    (( jobs < 1 )) && jobs=1
    (( jobs > cpu_count )) && jobs=$cpu_count
    log_info "compiling dnsdist (ninja -j$jobs based on ${mem_mb} MB RAM / $cpu_count CPUs; this takes a few minutes)"

    (
        export CPATH="$DNSDIST_PREFIX/include${CPATH:+:$CPATH}"
        export LIBRARY_PATH="$DNSDIST_PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
        cd "$src/pdns/dnsdistdist/build" && run_quiet ninja "-j$jobs"
    ) || { log_error "dnsdist ninja build failed"; return 1; }

    log_info "installing dnsdist to $DNSDIST_PREFIX"
    (cd "$src/pdns/dnsdistdist/build" && run_quiet ninja install) \
        || { log_error "dnsdist ninja install failed"; return 1; }

    # Tell the runtime loader where to find /opt/dnsdist/lib/libquiche.so so
    # dnsdist works without LD_LIBRARY_PATH gymnastics in the systemd unit.
    log_info "registering $DNSDIST_PREFIX/lib with the runtime loader (ld.so.conf.d)"
    install -d -m 0755 /etc/ld.so.conf.d
    printf '%s\n' "$DNSDIST_PREFIX/lib" > /etc/ld.so.conf.d/opennic-tier2-dnsdist.conf
    ldconfig

    log_ok "dnsdist $DNSDIST_RESOLVED_VERSION installed at $DNSDIST_PREFIX/bin/dnsdist"
}

# ---------- meta + verification ----------------------------------------------

dnsdist_build_record_meta() {
    cat > "$DNSDIST_BUILD_META" <<EOF
# Generated by opennic-tier2-installer; do not edit.
built_dnsdist=$DNSDIST_RESOLVED_VERSION
built_quiche=$QUICHE_RESOLVED_VERSION
built_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
prefix=$DNSDIST_PREFIX
EOF
    chmod 0644 "$DNSDIST_BUILD_META"
}

dnsdist_build_verify_binary() {
    local out
    out="$(LD_LIBRARY_PATH="$DNSDIST_PREFIX/lib" "$DNSDIST_PREFIX/bin/dnsdist" --version 2>&1 \
           | head -2)"
    log_info "$DNSDIST_PREFIX/bin/dnsdist --version:"
    while IFS= read -r line; do log_dim "  $line"; done <<< "$out"
    if ! grep -q "dns-over-quic" <<< "$out"; then
        log_error "built dnsdist does not advertise dns-over-quic in its feature list"
        return 1
    fi
    log_ok "dnsdist binary verified with DNS-over-QUIC enabled"
}

# ---------- orchestrator -----------------------------------------------------

step_dnsdist_build_from_source() {
    dnsdist_build_resolve_versions || return 1

    if dnsdist_build_is_current; then
        log_dim "dnsdist $DNSDIST_RESOLVED_VERSION + quiche $QUICHE_RESOLVED_VERSION already built"
        return 0
    fi

    ensure_state_dir
    log_info "build target: dnsdist-$DNSDIST_RESOLVED_VERSION + quiche $QUICHE_RESOLVED_VERSION"
    log_info "build root:   $DNSDIST_BUILD_ROOT"
    log_info "install root: $DNSDIST_PREFIX"

    dnsdist_build_snapshot_dpkg "$DNSDIST_BUILD_DPKG_BEFORE"

    dnsdist_build_install_runtime_deps || return 1
    dnsdist_build_install_build_deps   || return 1

    install -d -m 0755 "$DNSDIST_BUILD_ROOT"
    dnsdist_build_quiche  || return 1
    dnsdist_build_dnsdist || return 1

    dnsdist_build_verify_binary || return 1

    log_info "removing build tree at $DNSDIST_BUILD_ROOT"
    rm -rf "$DNSDIST_BUILD_ROOT"

    dnsdist_build_apt_cleanup
    dnsdist_build_snapshot_dpkg "$DNSDIST_BUILD_DPKG_AFTER"
    dnsdist_build_record_meta

    log_ok "dnsdist source build complete"
}
