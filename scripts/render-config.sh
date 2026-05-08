#!/usr/bin/env bash
# Render runtime configuration for the DNS+NTP simulation rig from .env.
#
# Outputs (under `out/render/`):
#   dns/Corefile             — CoreDNS config
#   dns/zones/seed.hosts     — DNS records (NTP A-record only when NTP_TARGET is FQDN)
#   ntp/chrony.conf          — chrony authoritative-server config
#   host/aliases.txt         — IPs to bind on the cabled Windows NIC
#   host/bindings.txt        — service/IP/port/proto tuples to surface (routing TBD per spike)
#
# Validation:
#   - Required keys present
#   - DNS_PRIMARY_IP / DNS_SECONDARY_IP / NTP_BIND_IP are valid IPv4 dotted-quads
#   - NTP_TARGET is either a valid IPv4 OR a valid FQDN
#   - When NTP_TARGET is an IP, it must equal NTP_BIND_IP (same listener, no DNS hop)
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

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1 (install with 'apt install gettext-base' or equivalent)"
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

# DNS_SECONDARY_IP is optional; normalize empty/unset to empty.
DNS_SECONDARY_IP="${DNS_SECONDARY_IP:-}"

# ── Validate values ────────────────────────────────────────────────
is_ipv4 "$DNS_PRIMARY_IP"  || die "DNS_PRIMARY_IP is not a valid IPv4: $DNS_PRIMARY_IP"
is_ipv4 "$NTP_BIND_IP"     || die "NTP_BIND_IP is not a valid IPv4: $NTP_BIND_IP"
[[ -n "$DNS_SECONDARY_IP" ]] && {
    is_ipv4 "$DNS_SECONDARY_IP" || die "DNS_SECONDARY_IP is not a valid IPv4: $DNS_SECONDARY_IP"
    [[ "$DNS_SECONDARY_IP" != "$DNS_PRIMARY_IP" ]] || die "DNS_SECONDARY_IP must differ from DNS_PRIMARY_IP"
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
if [[ -n "$DNS_SECONDARY_IP" ]]; then
    DNS_BIND_LINE="$DNS_PRIMARY_IP $DNS_SECONDARY_IP"
else
    DNS_BIND_LINE="$DNS_PRIMARY_IP"
fi

if [[ "$NTP_TARGET_KIND" == "fqdn" ]]; then
    NTP_RECORD_LINE="$NTP_BIND_IP $NTP_TARGET"
else
    NTP_RECORD_LINE="# NTP_TARGET is an IP literal ($NTP_TARGET) — no DNS A-record needed."
fi

export DNS_PRIMARY_IP DNS_SECONDARY_IP NTP_TARGET NTP_BIND_IP HOST_NIC_NAME NODE_SUBNET
export DNS_BIND_LINE NTP_RECORD_LINE NTP_TARGET_KIND

# ── Render ─────────────────────────────────────────────────────────
rm -rf "$OUT"
mkdir -p "$OUT/dns/zones" "$OUT/ntp" "$OUT/host"

envsubst '${DNS_BIND_LINE}' \
    < "$REPO_ROOT/docker/dns/Corefile.tmpl" > "$OUT/dns/Corefile"

envsubst '${NTP_RECORD_LINE}' \
    < "$REPO_ROOT/docker/dns/zones/seed.hosts.tmpl" > "$OUT/dns/zones/seed.hosts"

envsubst '${NTP_BIND_IP} ${NODE_SUBNET}' \
    < "$REPO_ROOT/docker/ntp/chrony.conf.tmpl" > "$OUT/ntp/chrony.conf"

# Host-side outputs — NIC alias list (consumed by scripts/setup-host-nic.sh).
# Under the Linux-host architecture (post-spike), every rig-bound IP must be
# an alias on the Linux host's NIC: the DNS listener IP(s) AND the NTP
# listener IP, since containers run with `network_mode: host` and bind
# directly on the host's interface.
{
    printf '# Generated from %s — IPs to bind as aliases on host NIC %q\n' \
        "$ENV_FILE" "$HOST_NIC_NAME"
    printf '%s\n' "$DNS_PRIMARY_IP"
    [[ -n "$DNS_SECONDARY_IP" ]] && printf '%s\n' "$DNS_SECONDARY_IP"
    printf '%s\n' "$NTP_BIND_IP"
} > "$OUT/host/aliases.txt"

# Host-side outputs — abstract bindings.
# How these are routed to the containers is decided by the WSL2 spike.
{
    printf '# Generated from %s — service bindings the rig must surface on the cabled NIC.\n' "$ENV_FILE"
    printf '# Format: SERVICE\\tBIND_IP\\tPORT\\tPROTO\n'
    printf 'DNS\t%s\t53\tudp\n' "$DNS_PRIMARY_IP"
    [[ -n "$DNS_SECONDARY_IP" ]] && printf 'DNS\t%s\t53\tudp\n' "$DNS_SECONDARY_IP"
    printf 'NTP\t%s\t123\tudp\n' "$NTP_BIND_IP"
} > "$OUT/host/bindings.txt"

# ── Report ─────────────────────────────────────────────────────────
printf 'render-config: rendered %s\n' "$OUT"
printf '  DNS bind        : %s\n' "$DNS_BIND_LINE"
printf '  NTP target kind : %s\n' "$NTP_TARGET_KIND"
if [[ "$NTP_TARGET_KIND" == "fqdn" ]]; then
    printf '  NTP A-record    : %s -> %s\n' "$NTP_TARGET" "$NTP_BIND_IP"
else
    printf '  NTP A-record    : (none — NTP_TARGET is IP literal)\n'
fi
printf '  NTP listen      : %s (allow %s)\n' "$NTP_BIND_IP" "$NODE_SUBNET"
printf '  Host NIC        : %s (alias IPs: see %s)\n' "$HOST_NIC_NAME" "$OUT/host/aliases.txt"
