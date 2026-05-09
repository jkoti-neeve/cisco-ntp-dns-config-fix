#!/usr/bin/env bash
# Add IP aliases on the Linux host NIC for the bench-test rig.
#
# Runs INSIDE the Linux host (Hyper-V VM with the cabled NIC bridged in,
# dedicated Linux box, etc.) — NOT on Windows. The Linux-host architecture
# was chosen post-spike because Windows owns UDP/53 (ICS) and UDP/123
# (W32Time) on wildcard listeners, blocking the rig's binds.
#
# Reads:
#   .env                                — for HOST_NIC_NAME and NODE_SUBNET
#   out/render/host/aliases.txt         — list of IPs to bind (run render-config.sh first)
#
# Usage:
#   sudo bash scripts/setup-host-nic.sh                # add aliases
#   sudo bash scripts/setup-host-nic.sh --teardown     # remove aliases
#
# Idempotent: re-running `add` skips already-bound IPs; `--teardown` skips
# IPs that aren't bound.
#
# Requires: Linux with iproute2 (`ip` command), root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
ALIASES_FILE="$REPO_ROOT/out/render/host/aliases.txt"

die() { printf 'setup-host-nic: error: %s\n' "$1" >&2; exit 1; }

# ── Mode parsing (do this before any privileged check so --help works) ──
MODE="add"
case "${1:-}" in
    --teardown|-t) MODE="teardown" ;;
    --help|-h)
        # Print the leading comment block, skipping the shebang. Stops at the
        # first non-`#` line.
        awk 'NR>1 { if (/^[^#]/) exit; sub(/^#[[:space:]]?/, ""); print }' \
            "${BASH_SOURCE[0]}"
        exit 0
        ;;
    "")            ;;
    *)             die "unknown argument: $1 (use --teardown to remove aliases, --help for usage)" ;;
esac

# ── Pre-flight ──────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || die "must run as root (try: sudo bash $0)"
command -v ip >/dev/null || die "missing 'ip' command (install iproute2)"
[[ -f "$ENV_FILE" ]]     || die ".env not found at $ENV_FILE — copy .env.example to .env and edit"
[[ -f "$ALIASES_FILE" ]] || die "$ALIASES_FILE not found — run scripts/render-config.sh first"

# Load .env for HOST_NIC_NAME and NODE_SUBNET.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${HOST_NIC_NAME:?HOST_NIC_NAME must be set in $ENV_FILE}"
: "${NODE_SUBNET:?NODE_SUBNET must be set in $ENV_FILE}"

# Per-IP prefix selection: in-subnet aliases use NODE_SUBNET's prefix so
# the kernel installs the link's connected route; out-of-subnet aliases
# (e.g., an operator's preconfigured DNS server in public address space)
# use /32 so we don't claim a connected route into someone else's range.
PREFIX="${NODE_SUBNET##*/}"
[[ "$PREFIX" =~ ^[0-9]+$ && "$PREFIX" -ge 1 && "$PREFIX" -le 32 ]] \
    || die "NODE_SUBNET must be in CIDR form with /1..32 prefix (got: $NODE_SUBNET)"

ip_to_int() {
    local IFS=.
    # shellcheck disable=SC2086
    set -- $1
    printf '%d\n' "$(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))"
}

ip_in_cidr() {
    # Returns 0 iff $1 (dotted-quad) is inside $2 (CIDR).
    local ip="$1" cidr="$2"
    local subnet="${cidr%/*}" prefix="${cidr##*/}"
    local ip_int subnet_int mask
    (( prefix == 0 )) && return 0
    ip_int="$(ip_to_int "$ip")"
    subnet_int="$(ip_to_int "$subnet")"
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    (( (ip_int & mask) == (subnet_int & mask) ))
}

prefix_for_ip() {
    if ip_in_cidr "$1" "$NODE_SUBNET"; then
        printf '%s\n' "$PREFIX"
    else
        printf '32\n'
    fi
}

ip link show "$HOST_NIC_NAME" >/dev/null 2>&1 \
    || die "NIC '$HOST_NIC_NAME' not found on this host. Check 'ip link show'."

# ── Collect IPs from aliases.txt ────────────────────────────────────
ips=()
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]]          && continue
    ips+=("$line")
done < "$ALIASES_FILE"

((${#ips[@]} > 0)) || die "$ALIASES_FILE contained no IPs (only comments/blanks)"

# ── Apply ──────────────────────────────────────────────────────────
case "$MODE" in
    add)
        printf 'setup-host-nic: adding %d alias(es) to %q (in-subnet -> /%s, out-of-subnet -> /32)\n' \
            "${#ips[@]}" "$HOST_NIC_NAME" "$PREFIX"
        for ip in "${ips[@]}"; do
            p="$(prefix_for_ip "$ip")"
            if ip -o -4 addr show dev "$HOST_NIC_NAME" | grep -qE "inet ${ip//./\\.}/"; then
                printf '  skip   %s (already bound)\n' "$ip"
            else
                ip addr add "$ip/$p" dev "$HOST_NIC_NAME"
                printf '  add    %s/%s\n' "$ip" "$p"
            fi
        done
        ;;
    teardown)
        printf 'setup-host-nic: removing %d alias(es) from %q\n' \
            "${#ips[@]}" "$HOST_NIC_NAME"
        for ip in "${ips[@]}"; do
            p="$(prefix_for_ip "$ip")"
            if ip -o -4 addr show dev "$HOST_NIC_NAME" | grep -qE "inet ${ip//./\\.}/"; then
                ip addr del "$ip/$p" dev "$HOST_NIC_NAME"
                printf '  remove %s/%s\n' "$ip" "$p"
            else
                printf '  skip   %s (not bound)\n' "$ip"
            fi
        done
        ;;
esac

# ── Show final state ────────────────────────────────────────────────
printf '\nIPv4 addresses on %s:\n' "$HOST_NIC_NAME"
ip -4 addr show dev "$HOST_NIC_NAME" | sed -n 's/^.*inet \([0-9./]*\) .*$/  \1/p'
