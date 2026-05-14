# opennic-tier2-installer

A reusable bash installer that turns a fresh **Debian 13 (trixie)** host into a fully-functional **OpenNIC Tier-2 DNS resolver** speaking **Do53**, **DoT**, **DoH**, **DoQ**, and **DNSCrypt**, with **DNSSEC validation against both IANA and OpenNIC root keys**, and a strict **no-logs** posture throughout.

```
                       ┌──────────────────────────────────────┐
   Public users        │         Public IPv4/IPv6             │
   ──────────────►     │                                      │
   :53  Do53 UDP/TCP   │  ┌───────────┐                       │
   :853 DoT (TCP)      │  │  dnsdist  │ ──► 127.0.0.1:5353    │
   :853 DoQ (UDP)      │  └───────────┘     (BIND9)           │
   :8443 DNSCrypt      │                                      │
   :443 DoH+HTTPS      │                                      │
                       │  ┌───────────┐                       │
                       │  │   nginx   │ ──► 127.0.0.1:5443    │
                       │  │  TLS term │     (dnsdist DoH)     │
                       │  └───────────┘                       │
                       │       │                              │
                       │       └──► /var/www/<host>/          │
                       └──────────────────────────────────────┘
```

A typical fresh-host install completes in **~10–15 minutes** (the bulk is the source build of dnsdist + quiche; see [Configuration](#configuration-reference) for version pinning) and is fully **idempotent** — re-run `install.sh` any time, every step is skip-safe.

---

## What you get

- **BIND9** as the recursive resolver. ICANN names recurse normally; OpenNIC TLDs and the OpenNIC root are slaved from official Tier-1 nameservers (the OpenNIC-recommended Tier-2 method). DNSSEC validation against IANA's auto-managed root anchor *and* the live OpenNIC root KSK.
- **dnsdist** terminating Do53, DoT, DoQ, and DNSCrypt directly on the public IP. Per-IP rate limiting, ANY-query refusal, non-recursive query refusal. Built from upstream `PowerDNS/pdns` source against `cloudflare/quiche` so DoQ + DoH3 work out of the box without third-party apt repos. Build deps are auto-installed, marked auto, and `apt-get autoremove --purge`'d after the binary is in place; `/opt/dnsdist` is the only persistent footprint.
- **nginx** owning :443 — TLS-terminates the operator info page on `/` and reverse-proxies DoH on `/dns-query` to dnsdist on `127.0.0.1:5443`. `trustForwardedForHeader=true` keeps per-IP rate limits accurate.
- **Let's Encrypt** certificate via certbot (HTTP-01 standalone for issuance, webroot for renewals; DNS-01 with Cloudflare also supported). Renewal deploy hook re-deploys cert material to nginx and dnsdist automatically.
- **unattended-upgrades** for security patches with a configurable reboot policy.
- **A static, JS-free operator info page** that respects the visitor's `prefers-color-scheme`, lists endpoints + DNSCrypt/DoH stamps, and surfaces the operator's abuse / security contacts.

**No logs anywhere.** BIND query logging is off, dnsdist is verbose-off and never invokes a logging action, nginx has `access_log off` on every server. Operational events go to syslog only and contain no client data.

---

## Prerequisites

- A **Debian 13 (trixie)** host. LXC, VM, or bare metal all work. (LXC: ensure the host kernel has `nf_conntrack_max=524288` and `net.core.{r,w}mem_max=4194304` if you expect public-internet load.)
- A **publicly-routable IPv4** address (and optionally IPv6) reachable on:
  - `:53/udp+tcp` — Do53
  - `:80/tcp` — Let's Encrypt HTTP-01 challenge (initial issuance and renewals when using the default `http-01` mode)
  - `:443/tcp` — nginx (HTTPS info page + DoH)
  - `:853/tcp` — DoT
  - `:853/udp` — DoQ (RFC 9250)
  - `:8443/udp+tcp` — DNSCrypt
- An **A record** (and optionally **AAAA**) pointing the resolver hostname at the host *before* you run the installer. Certbot will refuse to issue otherwise.
- **Root** on the host (`sudo bash install.sh`).

If port 80 is blocked at your provider's edge or you need wildcard certs, switch `ACME_CHALLENGE` to `dns-01` (Cloudflare is the bundled provider; see [Adding DNS providers](#adding-dns-providers)).

---

## Quick start

```bash
git clone https://github.com/SorcerousMachine/opennic-tier2-installer.git
cd opennic-tier2-installer
cp install.conf.example install.conf
$EDITOR install.conf          # set RESOLVER_HOSTNAME, RESOLVER_IPV4, etc.
sudo bash install.sh
```

That's it. The installer prints the DNSCrypt and DoH server stamps at the end. **Back up `/etc/dnsdist/dnscrypt/provider.key` immediately** — losing it forces a provider-name rotation, which invalidates every stamp anyone has stored.

While iterating on a new host, set `LE_STAGING="true"` in `install.conf` to use Let's Encrypt's staging endpoint. Switch it back to `"false"` and re-run `install.sh` once you're ready to go live; the installer detects the staging cert and re-issues against production.

---

## After install

1. **Back up the DNSCrypt provider key** to somewhere off-host:
   ```bash
   sudo cp /etc/dnsdist/dnscrypt/provider.key /secure-offsite-location/
   ```
   This is the catastrophic-loss file. The installer reminds you about it loudly.

2. **Apply for an OpenNIC Tier-2 listing**: <https://wiki.opennic.org/opennic/tier2>. The OpenNIC team will check your resolver and add it to the public list.

3. **Submit your DNSCrypt + DoH stamps to the public DNSCrypt registry**: <https://github.com/DNSCrypt/dnscrypt-resolvers>.

4. **Subscribe to the OpenNIC mailing list** (or watch the wiki) so you're notified about trust-anchor rollovers and infrastructure changes.

If you ever need to print the stamps again, run:
```bash
sudo bash scripts/print-stamps.sh
```

---

## Configuration reference

All operator-tunable values live in **`install.conf`** (gitignored). Copy `install.conf.example` and edit. The installer refuses to run if any required value is missing or still equals its placeholder.

### Required

| Variable                 | Description |
| ------------------------ | ----------- |
| `RESOLVER_HOSTNAME`      | Public hostname, e.g. `dns.example.org`. Must already have an A (and optionally AAAA) record. |
| `RESOLVER_IPV4`          | Public IPv4 address the world sees you on. |
| `CERTBOT_EMAIL`          | Used by Let's Encrypt for expiry notifications. |
| `OPERATOR_NAME`          | Shown on the info page. |
| `OPERATOR_ABUSE_EMAIL`   | Required for the OpenNIC Tier-2 listing. Must be a real, monitored mailbox. |
| `OPERATOR_SECURITY_EMAIL`| Required for responsible disclosure. |

### Optional

| Variable                  | Default                                 | Description |
| ------------------------- | --------------------------------------- | ----------- |
| `RESOLVER_IPV6`           | *(empty)*                               | Public IPv6. Empty disables v6 listeners. |
| `ACME_CHALLENGE`          | `http-01`                               | `http-01` (port 80 reachable) or `dns-01`. |
| `DNS_PROVIDER`            | `cloudflare`                            | DNS-01 provider. `cloudflare` ships; others need a small patch (see below). |
| `DNS_PROVIDER_API_TOKEN`  | *(empty)*                               | Cloudflare token scoped Zone:DNS:Edit on the parent zone. |
| `LE_STAGING`              | `false`                                 | `true` uses LE staging (untrusted cert; safe to retry). |
| `DNSCRYPT_PROVIDER_NAME`  | `2.dnscrypt-cert.<RESOLVER_HOSTNAME>`   | Pick once and don't change — every published stamp embeds it. |
| `OPERATOR_REGION`         | *(empty)*                               | Free-text region/datacenter for the info page. |
| `OPERATOR_HOMEPAGE_URL`   | `https://<RESOLVER_HOSTNAME>/`          | Linked from the info page footer. |
| `AUTO_REBOOT_TIME`        | `now`                                   | Reboot policy for unattended-upgrades. `now`, `HH:MM`, or empty (disable). |
| `SLAVE_OPENNIC_ROOT`      | `false`                                 | `true` slaves the OpenNIC root in addition to the 16 TLDs. See below. |
| `DNSDIST_VERSION`         | *(empty = latest stable)*               | Optional pin for the source-built dnsdist tag (e.g. `"2.0.5"`). Empty resolves the latest `dnsdist-2.0.x` tag on PowerDNS/pdns. |
| `QUICHE_VERSION`          | *(empty = latest stable)*               | Optional pin for the cloudflare/quiche tag (e.g. `"0.28.0"`). Empty resolves the latest `0.x.y` tag. |

### The DNSSEC-vs-altroot-fidelity tradeoff (`SLAVE_OPENNIC_ROOT`)

The default (`false`) uses IANA root hints. ICANN names recurse through the IANA hierarchy and produce real AD-flagged DNSSEC responses end-to-end, including for NXDOMAIN. OpenNIC TLDs are still served authoritatively from local slaved zones; a small forward zone for `glue.` covers the OpenNIC infrastructure namespace (`ns0.opennic.glue` etc.).

Setting `true` adopts the canonical OpenNIC Tier-2 layout from the OpenNIC wiki: the entire OpenNIC root is slaved in addition to the TLDs, giving a complete alt-root replica. The trade-off is that root-level NXDOMAIN responses are now authoritative (`AA` flag, no `AD`), which is correct per RFC 6840 but breaks `dnscrypt-proxy`'s DNSSEC self-check — it probes `*.dnscrypt-test.` expecting NXDOMAIN with `AD`. Pick `true` only if you specifically want the alt-root-replica property and don't care about a strict DNSSEC check by DNSCrypt clients.

### The security-vs-uptime auto-reboot tradeoff

`AUTO_REBOOT_TIME=now` reboots the host immediately when a kernel/glibc/openssl update lands that requires it. **You're patched fast, but resolution drops for ~30–60 seconds** while the host comes back. This is the right default for a public Tier-2: the alternative is to leave a privilege-escalation or RCE flaw exposed for arbitrary days.

If you have multiple resolvers behind a load balancer, set this to a quiet hour (`AUTO_REBOOT_TIME=04:30`) and stagger the times so they don't all reboot at once. If you handle reboots manually, set it to empty (`AUTO_REBOOT_TIME=""`). Either way, **don't disable `unattended-upgrades` itself** — the security patches still need to land.

---

## Helper scripts

All in `scripts/`. Each is a one-shot, idempotent operation.

| Script                              | Purpose |
| ----------------------------------- | ------- |
| `verify.sh`                         | End-to-end smoke test (Do53, DoT, DoH, DNSCrypt, info page, IPv6 if configured). Exit 0 on full pass. |
| `print-stamps.sh`                   | Re-print DNSCrypt + DoH stamps in case the install summary scrolled away. |
| `refresh-opennic-config.sh`         | Re-pull current OpenNIC Tier-1 IPs + TLD list, regenerate BIND config, reload BIND. Run after OpenNIC adds a TLD or rotates infrastructure. |
| `update-opennic-trust-anchor.sh`    | Re-fetch the OpenNIC root KSK and update BIND's trust anchor. Run after OpenNIC announces a key rollover. |
| `uninstall.sh`                      | Clean removal. `--packages` also `apt purge`s installed packages; `--le-account` deletes the LE account state. Always backs up `provider.key` to `/root/` first. |

---

## Optional integrations

In `scripts/integrations/`. These are deliberately separate from the main installer — operators run them only if they want the corresponding capability. Each is purely additive: enabling one does not change behavior for clients of the existing transports.

### DNS-over-I2P (DoI)

Exposes this resolver as a hidden service inside the [I2P](https://geti2p.net/) anonymity network, reachable at a persistent `<destination>.b32.i2p` address. Same resolver, same posture (no logs, no filtering, DNSSEC-validating). Just a fifth transport alongside Do53/DoT/DoH/DNSCrypt for users who want their query traffic to traverse I2P rather than clearnet.

**Architecture:**

```
I2P client → i2pd server tunnel → 127.0.0.1:53 (dnsdist) → 127.0.0.1:5353 (BIND)
```

i2pd terminates the I2P tunnel locally and forwards both TCP and UDP DNS to dnsdist on loopback. Because every DoI client appears to dnsdist as `127.0.0.1`, the per-IP rate limit explicitly **exempts loopback** — otherwise one busy I2P client would starve every other I2P client out of a single shared 50-qps bucket. Anti-abuse for I2P-side traffic is delegated to i2pd's own tunnel-level controls; clearnet sources still get the per-IP cap with their real source addresses.

**Enable:**

```bash
sudo bash scripts/integrations/enable-doi.sh
```

The script installs `i2pd`, drops a tunnels config at `/etc/i2pd/tunnels.conf.d/opennic-dns.conf`, starts i2pd, and saves the generated `.b32.i2p` address to `/var/lib/opennic-tier2-install/i2p-address.txt`. First-time tunnel establishment takes 5-15 minutes after i2pd starts while it bootstraps into the I2P network — `sudo journalctl -u i2pd -f` shows progress.

**Operational notes:**

- **Back up `/var/lib/i2pd/opennic-dns.dat`** — that file holds the persistent destination keypair. Same "lose-it-and-the-address-changes" property as the DNSCrypt provider key. Anyone with the old address would silently fail until they rediscover the new one.
- **Latency over I2P is significantly higher than clearnet** (typically 300ms–2s of extra round-trip). I2P is not a low-latency transport. Clients that care about query speed should use one of the clearnet transports.
- **What's not done by the script:** publishing the `.b32.i2p` address. That's an editorial decision. Reasonable venues if you want discovery: your operator info page, the I2P forum's services subforum, `r/i2p`, the `#i2p` IRC channel on Libera Chat, and the description field of your OpenNIC Tier-2 listing. The script prints client-side tunnel configuration that operators of other i2pd installs can paste straight into their `tunnels.conf` to reach you.
- **What this script does NOT do:** make `.i2p` names resolvable from a regular browser. That's the inverse direction (DNS resolver as I2P client rather than I2P-accessible service) and is out of scope by design — bridging `.i2p` content out to clearnet defeats the anonymity guarantees the I2P transport provides, and the I2P community generally pushes back on outproxy-style integrations that go the other way.

To unwind: `sudo systemctl disable --now i2pd && sudo apt-get purge i2pd`. The `.dat` keypair file is left in `/var/lib/i2pd/` in case you change your mind; remove it manually if you want a clean slate.

---

## Maintenance

**Weekly** — nothing. The installer runs `unattended-upgrades` on the systemd timer; certbot runs its own renewal timer. As long as both are healthy you're fine.

**Monthly** — `sudo bash scripts/verify.sh`. Catches anything that broke silently (provider blocked port 853, cert renewal failed because port 80 is blocked, etc.).

**Quarterly** — `sudo bash scripts/refresh-opennic-config.sh`. Refreshes the Tier-1 IP list and the TLD list. OpenNIC infrastructure rarely changes, but when it does, slaved zones can fall behind silently.

**Annually** — Watch for OpenNIC trust anchor rollover announcements. Run `sudo bash scripts/update-opennic-trust-anchor.sh` when one happens. RFC 5011 will manage routine rollovers automatically (the `initial-key` stanza), but if OpenNIC publishes a one-shot key change without a rollover overlap, the manual fetch is what gets you back to validating.

---

## Recovery

### "I lost the DNSCrypt provider key"

This is the bad case. The provider keypair is what signs short-term resolver certificates; clients pin the *provider name + provider public key* in their stamp. If the private key is gone, you cannot generate new resolver certs that match the published stamp.

The only recovery is:
1. Pick a new `DNSCRYPT_PROVIDER_NAME` (e.g., bump `2.` to `3.`).
2. Re-run `install.sh` — new keypair generated.
3. Publish the new stamps.
4. Notify users of the change. Old stamps will fail.

This is why the installer reminds you to back up `/etc/dnsdist/dnscrypt/provider.key` loudly. Do it on day one.

### "Certificate renewal failed"

Check `journalctl -u certbot` and `/var/log/letsencrypt/letsencrypt.log`. The most common causes:
- **Port 80 blocked**: your provider added a firewall rule, or some other service grabbed `:80`. With HTTP-01 webroot, nginx must continue to serve `/.well-known/acme-challenge/`. Check `nginx -T | grep acme`.
- **DNS A record changed**: certbot validates against your hostname's current A record. If you moved hosts and forgot to update DNS, validation fails.
- **Account locked**: hitting LE rate limits during testing. Switch to `LE_STAGING=true` and try again, or wait.

To force a manual renewal: `sudo certbot renew --force-renewal`.

### "OpenNIC names stopped resolving"

```bash
sudo journalctl -u named --since "1 hour ago" | grep -E '(transfer|DNSSEC|managed-keys)'
```

Look for AXFR failures (Tier-1 server unreachable) or DNSSEC validation failures (trust anchor stale). Run `sudo bash scripts/refresh-opennic-config.sh` to re-pull, or `sudo bash scripts/update-opennic-trust-anchor.sh` if it's the trust anchor.

### "Public can't reach me but localhost works"

```bash
sudo bash scripts/verify.sh    # tests against the public IP from the host itself
```

If the local-host-as-public-client tests pass but external clients still time out, it's network-layer: provider firewall, upstream router ACLs, ISP blocking inbound :53, etc. None of these are fixable from inside the resolver — talk to your provider.

---

## Adding DNS providers

`dns-01` ships only Cloudflare. Adding a new provider takes ~10 lines:

1. Update `install.conf.example` to document the new provider name.
2. In `lib/helpers.sh::validate_config`, add the provider to the `case "$DNS_PROVIDER"` allowlist.
3. In `lib/steps_certbot.sh::step_certbot_install_package`, add the apt package (e.g., `python3-certbot-dns-route53` for Route 53).
4. In `lib/steps_certbot.sh::step_certbot_install_dns_credentials`, add a branch that writes the provider's credentials file to `/etc/letsencrypt/<provider>.ini`.
5. In `lib/steps_certbot.sh::step_certbot_issue`, add a `case` entry that passes the right `--dns-<provider>` flags to certbot.

PRs welcome.

---

## Security

Where to report security issues: the operator running the resolver should set this in their `install.conf`'s `OPERATOR_SECURITY_EMAIL`, and it shows on the public info page. For issues in the **installer itself**, file a GitHub issue on this repo (or, if it's sensitive, the contact in the upstream's security policy).

The installer never writes secrets to its own log (`/var/log/opennic-tier2-install.log`). Cloudflare API tokens, dnsdist console keys, the DNSCrypt provider private key — none touch the log. If you find a path where one does, that's a bug; please report it.

---

## Disclosure

Built with substantial AI assistance under human direction. See
[Sorcerous Machine — Practices](https://sorcerousmachine.com/about#practices)
for the full disclosure on AI usage and commit attribution.

---

## License

[MIT](LICENSE).
