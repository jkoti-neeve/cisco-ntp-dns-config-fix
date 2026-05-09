#!/usr/bin/env bash
# Render runtime configuration for the DNS+DHCP+NTP simulation rig from .env.
#
# Outputs (under `out/render/`):
#   dns/dnsmasq.conf         — dnsmasq DNS + DHCP config
#   dns/zones/seed.hosts     — DNS records (NTP A-record only when NTP_TARGET is FQDN)
#   ntp/chrony.conf          — chrony authoritative-server config
#   host/aliases.txt         — IPs to bind on the cabled host NIC
#   host/bindings.txt        — service/IP/port/proto tuples (audit trail)
#
# Validation:
#   - Required keys present (incl. DHCP_RANGE_START/END/LEASE_TIME)
#   - DNS_PRIMARY_IP / DNS_SECONDARY_IP / NTP_BIND_IP / DHCP_RANGE_* /
#     DHCP_GATEWAY_IP are valid IPv4 dotted-quads
#   - NTP_TARGET is either a valid IPv4 OR a valid FQDN
#   - When NTP_TARGET is an IP, it must equal NTP_BIND_IP
#   - DHCP_RANGE_START <= DHCP_RANGE_END (numerically)
#   - DHCP_LEASE_TIME is <N>{m|h|d} or 'infinite'
#
# Usage:
#   bash scripts/render-config.sh                # reads ./.env
#   ENV_FILE=/path/to/.env bash scripts/render-config.sh
#
# Exit codes:
#   0 — success
#   1 — validation failure or missing dependency

set -euo pipefail

# ── Locations ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
OUT="$REPO_ROOT/out/render"

# ── Helpers ─────────────────────────────────────────────────────────
die() {
    printf 'render-config: error: %s\n' "$1" >&2
    exit 1
}

is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local oct
    for oct in "${BASH_REMATCH[@]:1:4}"; do
        ((oct >= 0 && oct <= 255)) || return 1
    done
    return 0
}

is_fqdn() {
    # At least one dot, labels of 1–63 chars, TLD letters-only of 2+ chars.
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

is_lease_time() {
    # dnsmasq accepts <N>{m|h|d}, plain seconds (no suffix), or 'infinite'.
    [[ "$1" == "infinite" || "$1" =~ ^[0-9]+[mhd]?$ ]]
}

ip_to_int() {
    # Print a 32-bit unsigned integer for a dotted-quad IPv4. Used for
    # ordering comparisons (e.g. range start <= end).
    local IFS=.
    # shellcheck disable=SC2086
    set -- $1
    printf '%d\n' "$(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || die "missing dependency: $1 (install with 'apt install gettext-base' or equivalent)"
}

# ── Pre-flight ──────────────────────────────────────────────────────
require_cmd envsubst
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Copy .env.example to .env and fill in values."

# Load .env (export every assignment so envsubst sees them).
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# ── Validate required keys ─────────────────────────────────────────
: "${DNS_PRIMARY_IP:?DNS_PRIMARY_IP must be set in $ENV_FILE}"
: "${NTP_TARGET:?NTP_TARGET must be set in $ENV_FILE}"
: "${NTP_BIND_IP:?NTP_BIND_IP must be set in $ENV_FILE}"
: "${HOST_NIC_NAME:?HOST_NIC_NAME must be set in $ENV_FILE}"
: "${NODE_SUBNET:?NODE_SUBNET must be set in $ENV_FILE}"
: "${DHCP_RANGE_START:?DHCP_RANGE_START must be set in $ENV_FILE (Q-IP closed as DHCP)}"
: "${DHCP_RANGE_END:?DHCP_RANGE_END must be set in $ENV_FILE}"
: "${DHCP_LEASE_TIME:?DHCP_LEASE_TIME must be set in $ENV_FILE (e.g. 10m)}"

# Optional — normalize empty/unset to empty.
DNS_SECONDARY_IP="${DNS_SECONDARY_IP:-}"
DHCP_GATEWAY_IP="${DHCP_GATEWAY_IP:-}"
DHCP_DOMAIN_NAME="${DHCP_DOMAIN_NAME:-}"

# ── Validate values ────────────────────────────────────────────────
is_ipv4 "$DNS_PRIMARY_IP"   || die "DNS_PRIMARY_IP is not a valid IPv4: $DNS_PRIMARY_IP"
is_ipv4 "$NTP_BIND_IP"      || die "NTP_BIND_IP is not a valid IPv4: $NTP_BIND_IP"
is_ipv4 "$DHCP_RANGE_START" || die "DHCP_RANGE_START is not a valid IPv4: $DHCP_RANGE_START"
is_ipv4 "$DHCP_RANGE_END"   || die "DHCP_RANGE_END is not a valid IPv4: $DHCP_RANGE_END"
is_lease_time "$DHCP_LEASE_TIME" \
    || die "DHCP_LEASE_TIME must match <N>{m|h|d} or 'infinite' (got: $DHCP_LEASE_TIME)"

[[ "$(ip_to_int "$DHCP_RANGE_START")" -le "$(ip_to_int "$DHCP_RANGE_END")" ]] \
    || die "DHCP_RANGE_START ($DHCP_RANGE_START) must be <= DHCP_RANGE_END ($DHCP_RANGE_END)"

[[ -n "$DNS_SECONDARY_IP" ]] && {
    is_ipv4 "$DNS_SECONDARY_IP" || die "DNS_SECONDARY_IP is not a valid IPv4: $DNS_SECONDARY_IP"
    [[ "$DNS_SECONDARY_IP" != "$DNS_PRIMARY_IP" ]] || die "DNS_SECONDARY_IP must differ from DNS_PRIMARY_IP"
}

[[ -n "$DHCP_GATEWAY_IP" ]] && {
    is_ipv4 "$DHCP_GATEWAY_IP" || die "DHCP_GATEWAY_IP is not a valid IPv4: $DHCP_GATEWAY_IP"
}

[[ -n "$DHCP_DOMAIN_NAME" ]] && {
    is_fqdn "$DHCP_DOMAIN_NAME" \
        || die "DHCP_DOMAIN_NAME is not a valid domain (e.g., wbg.org): $DHCP_DOMAIN_NAME"
}

if is_ipv4 "$NTP_TARGET"; then
    NTP_TARGET_KIND="ip"
    [[ "$NTP_TARGET" == "$NTP_BIND_IP" ]] \
        || die "NTP_TARGET is an IP literal ($NTP_TARGET) but does not equal NTP_BIND_IP ($NTP_BIND_IP) — set them to the same value"
elif is_fqdn "$NTP_TARGET"; then
    NTP_TARGET_KIND="fqdn"
else
    die "NTP_TARGET is neither a valid IPv4 nor a valid FQDN: $NTP_TARGET"
fi

# ── Compute derived values ─────────────────────────────────────────

# Default DHCP_GATEWAY_IP to DNS_PRIMARY_IP — the rig pretends to be the
# gateway so the device doesn't try to off-link route somewhere we can't
# reach. Operator can override in .env if a specific IP is needed.
[[ -z "$DHCP_GATEWAY_IP" ]] && DHCP_GATEWAY_IP="$DNS_PRIMARY_IP"

# DNS_LISTEN_LINES — newline-separated `listen-address=...` for the
# dnsmasq.conf. One line per DNS IP.
if [[ -n "$DNS_SECONDARY_IP" ]]; then
    DNS_LISTEN_LINES=$(printf 'listen-address=%s\nlisten-address=%s' "$DNS_PRIMARY_IP" "$DNS_SECONDARY_IP")
    DHCP_DNS_SERVERS="$DNS_PRIMARY_IP,$DNS_SECONDARY_IP"
else
    DNS_LISTEN_LINES="listen-address=$DNS_PRIMARY_IP"
    DHCP_DNS_SERVERS="$DNS_PRIMARY_IP"
fi

if [[ "$NTP_TARGET_KIND" == "fqdn" ]]; then
    NTP_RECORD_LINE="$NTP_BIND_IP $NTP_TARGET"
else
    NTP_RECORD_LINE="# NTP_TARGET is an IP literal ($NTP_TARGET) — no DNS A-record needed."
fi

if [[ -n "$DHCP_DOMAIN_NAME" ]]; then
    DHCP_DOMAIN_LINE="dhcp-option=option:domain-name,$DHCP_DOMAIN_NAME"
else
    DHCP_DOMAIN_LINE="# DHCP_DOMAIN_NAME not set — option 15 (domain-name) omitted."
fi

export DNS_PRIMARY_IP DNS_SECONDARY_IP NTP_TARGET NTP_BIND_IP HOST_NIC_NAME NODE_SUBNET
export DHCP_RANGE_START DHCP_RANGE_END DHCP_LEASE_TIME DHCP_GATEWAY_IP DHCP_DOMAIN_NAME
export DNS_LISTEN_LINES DHCP_DNS_SERVERS NTP_RECORD_LINE NTP_TARGET_KIND DHCP_DOMAIN_LINE

# ── Render ─────────────────────────────────────────────────────────
rm -rf "$OUT"
mkdir -p "$OUT/dns/zones" "$OUT/ntp" "$OUT/host"

envsubst '${DNS_LISTEN_LINES} ${HOST_NIC_NAME} ${DHCP_RANGE_START} ${DHCP_RANGE_END} ${DHCP_LEASE_TIME} ${DHCP_DNS_SERVERS} ${DHCP_GATEWAY_IP} ${DHCP_DOMAIN_LINE}' \
    < "$REPO_ROOT/docker/dns/dnsmasq.conf.tmpl" > "$OUT/dns/dnsmasq.conf"

envsubst '${NTP_RECORD_LINE}' \
    < "$REPO_ROOT/docker/dns/zones/seed.hosts.tmpl" > "$OUT/dns/zones/seed.hosts"

envsubst '${NTP_BIND_IP} ${NODE_SUBNET}' \
    < "$REPO_ROOT/docker/ntp/chrony.conf.tmpl" > "$OUT/ntp/chrony.conf"

# Host-side outputs — NIC alias list (consumed by scripts/setup-host-nic.sh).
# Every rig-bound IP must be an alias on the Linux host's NIC: the DNS
# listener IP(s) AND the NTP listener IP, since containers run with
# `network_mode: host` and bind directly on the host's interface.
{
    printf '# Generated from %s — IPs to bind as aliases on host NIC %q\n' \
        "$ENV_FILE" "$HOST_NIC_NAME"
    printf '%s\n' "$DNS_PRIMARY_IP"
    [[ -n "$DNS_SECONDARY_IP" ]] && printf '%s\n' "$DNS_SECONDARY_IP"
    printf '%s\n' "$NTP_BIND_IP"
    # DHCP_GATEWAY_IP only needs aliasing if it's distinct from the DNS
    # listeners (often it's the same as DNS_PRIMARY_IP — already aliased).
    if [[ "$DHCP_GATEWAY_IP" != "$DNS_PRIMARY_IP" \
       && "$DHCP_GATEWAY_IP" != "$DNS_SECONDARY_IP" \
       && "$DHCP_GATEWAY_IP" != "$NTP_BIND_IP" ]]; then
        printf '%s\n' "$DHCP_GATEWAY_IP"
    fi
} > "$OUT/host/aliases.txt"

# Host-side outputs — abstract bindings (audit trail).
{
    printf '# Generated from %s — service bindings the rig surfaces on the cabled NIC.\n' "$ENV_FILE"
    printf '# Format: SERVICE\\tBIND_IP\\tPORT\\tPROTO\n'
    printf 'DNS\t%s\t53\tudp\n' "$DNS_PRIMARY_IP"
    [[ -n "$DNS_SECONDARY_IP" ]] && printf 'DNS\t%s\t53\tudp\n' "$DNS_SECONDARY_IP"
    printf 'NTP\t%s\t123\tudp\n' "$NTP_BIND_IP"
    printf 'DHCP\t%s\t67\tudp\n' "(broadcast on $HOST_NIC_NAME)"
} > "$OUT/host/bindings.txt"

# ── Report ─────────────────────────────────────────────────────────
printf 'render-config: rendered %s\n' "$OUT"
printf '  DNS listen      : %s\n' "$(echo "$DNS_LISTEN_LINES" | sed 's/listen-address=//' | tr '\n' ' ')"
printf '  NTP target kind : %s\n' "$NTP_TARGET_KIND"
if [[ "$NTP_TARGET_KIND" == "fqdn" ]]; then
    printf '  NTP A-record    : %s -> %s\n' "$NTP_TARGET" "$NTP_BIND_IP"
else
    printf '  NTP A-record    : (none — NTP_TARGET is IP literal)\n'
fi
printf '  NTP listen      : %s (allow %s)\n' "$NTP_BIND_IP" "$NODE_SUBNET"
printf '  DHCP pool       : %s..%s, lease %s\n' "$DHCP_RANGE_START" "$DHCP_RANGE_END" "$DHCP_LEASE_TIME"
printf '  DHCP option 6   : DNS = %s\n' "$DHCP_DNS_SERVERS"
printf '  DHCP option 3   : router = %s\n' "$DHCP_GATEWAY_IP"
if [[ -n "$DHCP_DOMAIN_NAME" ]]; then
    printf '  DHCP option 15  : domain-name = %s\n' "$DHCP_DOMAIN_NAME"
else
    printf '  DHCP option 15  : (omitted — DHCP_DOMAIN_NAME not set)\n'
fi
printf '  Host NIC        : %s (alias IPs: see %s)\n' "$HOST_NIC_NAME" "$OUT/host/aliases.txt"
