#!/usr/bin/env bash
# Automated pass/fail for the bench-test rig.
#
# Captures DNS query log + UDP/123 pcap for N seconds, then asserts
# protocol-correctness against the active .env's config-matrix case
# (A: 1 DNS + FQDN / B: 2 DNS + FQDN / C: 1 DNS + IP / D: 2 DNS + IP).
#
# Runs INSIDE the Linux host (Hyper-V VM, dedicated box, etc.) — same
# environment as setup-host-nic.sh and `docker compose up`.
#
# Usage:
#   sudo bash scripts/verify.sh                    # 60s capture, default
#   sudo bash scripts/verify.sh --duration 300     # longer (recommended for
#                                                  # observing chrony back-off
#                                                  # 32s -> 64s -> 128s)
#   sudo bash scripts/verify.sh --help
#
# Outputs (to out/run/<run-id>/):
#   dns.log        — DNS query log captured during the window
#   ntp.pcap       — UDP/123 packet capture
#   ntp.tsv        — pcap parsed by tshark (one NTP packet per row)
#   summary.json   — machine-readable assertions + verdict
#
# Requires: Linux with tcpdump, tshark, jq, Docker. Run as root (tcpdump).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

# ── Argument parsing (before privileged checks so --help works) ─────
DURATION=60
case "${1:-}" in
    --help|-h)
        awk 'NR>1 { if (/^[^#]/) exit; sub(/^#[[:space:]]?/, ""); print }' \
            "${BASH_SOURCE[0]}"
        exit 0
        ;;
    --duration)
        DURATION="${2:?--duration requires N seconds}"
        ;;
    --duration=*)
        DURATION="${1#--duration=}"
        ;;
    "")
        ;;
    *)
        printf 'verify: error: unknown argument: %s (use --help for usage)\n' "$1" >&2
        exit 1
        ;;
esac
[[ "$DURATION" =~ ^[0-9]+$ && "$DURATION" -ge 5 ]] \
    || { printf 'verify: error: --duration must be an integer >= 5\n' >&2; exit 1; }

# ── Helpers ─────────────────────────────────────────────────────────
die()  { printf 'verify: error: %s\n' "$1" >&2; exit 1; }
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }
warn() { printf '  WARN  %s\n' "$1"; }
note() { printf '  note  %s\n' "$1"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || die "missing dependency: $1 (install with 'apt install $2')"
}

# ── Pre-flight ──────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || die "must run as root (try: sudo bash $0)"
require_cmd tcpdump tcpdump
require_cmd tshark wireshark
require_cmd jq jq
require_cmd docker docker.io
[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE"

# Load .env
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${HOST_NIC_NAME:?HOST_NIC_NAME must be set in .env}"
: "${NTP_TARGET:?NTP_TARGET must be set in .env}"
: "${NTP_BIND_IP:?NTP_BIND_IP must be set in .env}"
: "${DNS_PRIMARY_IP:?DNS_PRIMARY_IP must be set in .env}"
DNS_SECONDARY_IP="${DNS_SECONDARY_IP:-}"

# Detect NTP_TARGET kind (same logic as render-config.sh).
if [[ "$NTP_TARGET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    NTP_TARGET_KIND="ip"
else
    NTP_TARGET_KIND="fqdn"
fi

# Determine config matrix case.
if [[ -n "$DNS_SECONDARY_IP" ]]; then
    if [[ "$NTP_TARGET_KIND" == "fqdn" ]]; then CASE="B"; else CASE="D"; fi
else
    if [[ "$NTP_TARGET_KIND" == "fqdn" ]]; then CASE="A"; else CASE="C"; fi
fi

# Verify NIC + Docker stack are up.
ip link show "$HOST_NIC_NAME" >/dev/null 2>&1 \
    || die "NIC '$HOST_NIC_NAME' not found"

docker_compose_dir="$REPO_ROOT"
( cd "$docker_compose_dir" && docker compose ps --status running --services 2>/dev/null | grep -qx dns ) \
    || die "DNS service not running. 'docker compose up -d' first."
( cd "$docker_compose_dir" && docker compose ps --status running --services 2>/dev/null | grep -qx ntp ) \
    || die "NTP service not running. 'docker compose up -d' first."

# ── Output dir ──────────────────────────────────────────────────────
RUN_ID="$(date '+%Y-%m-%d-%H%M%S')"
OUT="$REPO_ROOT/out/run/$RUN_ID"
mkdir -p "$OUT"

# ── Capture ─────────────────────────────────────────────────────────
printf 'verify: capturing for %ds on %q (case %s)\n' "$DURATION" "$HOST_NIC_NAME" "$CASE"
printf '  output    : %s\n' "$OUT"
printf '  ntp_target: %s (%s)\n' "$NTP_TARGET" "$NTP_TARGET_KIND"
printf '  ntp_bind  : %s\n' "$NTP_BIND_IP"
printf '  dns       : %s%s\n\n' "$DNS_PRIMARY_IP" \
    "${DNS_SECONDARY_IP:+ + $DNS_SECONDARY_IP}"

PCAP="$OUT/ntp.pcap"
DNS_LOG="$OUT/dns.log"

# Start tcpdump in background, capture its PID, and ensure cleanup.
tcpdump -i "$HOST_NIC_NAME" -U -w "$PCAP" \
    "udp port 123" >/dev/null 2>&1 &
TCPDUMP_PID=$!
trap 'kill "$TCPDUMP_PID" 2>/dev/null || true; wait "$TCPDUMP_PID" 2>/dev/null || true' EXIT

# Note the start time so we can extract just this window's docker logs later.
START_TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

printf '  [+0s]    tcpdump started\n'
sleep "$DURATION"
printf '  [+%ds]   stopping tcpdump\n' "$DURATION"

kill "$TCPDUMP_PID" 2>/dev/null || true
wait "$TCPDUMP_PID" 2>/dev/null || true
trap - EXIT

# Pull DNS log for the window. `docker compose logs --since` accepts a
# duration like 60s as well as an absolute timestamp; use the duration
# form so we don't depend on host/container clock alignment.
( cd "$docker_compose_dir" && docker compose logs --since "${DURATION}s" --no-color dns ) \
    > "$DNS_LOG" 2>&1 || true

PCAP_PACKETS="$(tcpdump -r "$PCAP" 2>/dev/null | wc -l)"
printf '  pcap      : %d packets\n' "$PCAP_PACKETS"
printf '  dns log   : %d lines\n\n' "$(wc -l < "$DNS_LOG")"

# ── Assertions ──────────────────────────────────────────────────────
FAILED=0

# DNS assertions (only meaningful when NTP_TARGET is FQDN; in IP cases
# the device never asks DNS for the NTP target).
printf 'DNS:\n'
DNS_QUERY_COUNT=0
DNS_RESPONSE_OK="false"

if [[ "$NTP_TARGET_KIND" == "fqdn" ]]; then
    # CoreDNS log plugin format includes the queried name. Match
    # case-insensitively, allow trailing dot.
    DNS_QUERY_COUNT="$(grep -ciE "\\b${NTP_TARGET}\\.?\\b" "$DNS_LOG" || true)"

    if (( DNS_QUERY_COUNT > 0 )); then
        pass "device queried ${NTP_TARGET} (${DNS_QUERY_COUNT} log lines)"
    else
        fail "no DNS queries for ${NTP_TARGET} observed in ${DURATION}s"
        note "device may not be reaching DNS at ${DNS_PRIMARY_IP}; check NIC aliases + cabling"
    fi

    # The Corefile uses the `hosts` plugin without fallthrough — any
    # answered query for ${NTP_TARGET} must have returned NTP_BIND_IP.
    # Confirm by spot-checking the seed.hosts content.
    SEED_HOSTS="$REPO_ROOT/out/render/dns/zones/seed.hosts"
    if grep -qE "^${NTP_BIND_IP//./\\.}\\s+${NTP_TARGET//./\\.}\\b" "$SEED_HOSTS" 2>/dev/null; then
        DNS_RESPONSE_OK="true"
        pass "seed.hosts maps ${NTP_TARGET} -> ${NTP_BIND_IP}"
    else
        fail "seed.hosts does NOT contain ${NTP_TARGET} -> ${NTP_BIND_IP} — DNS may have answered NXDOMAIN"
    fi
else
    note "NTP_TARGET is an IP literal (case ${CASE}); no DNS query expected"
    DNS_OTHER="$(wc -l < "$DNS_LOG")"
    if (( DNS_OTHER == 0 )); then
        note "DNS log is empty — normal for cases C/D"
    else
        note "DNS log shows ${DNS_OTHER} lines (other names the device queried — review ${DNS_LOG})"
    fi
fi

# NTP assertions (always meaningful).
printf '\nNTP:\n'

# Use tshark to extract NTP mode + timing per packet.
# Fields: time_epoch, ip.src, ip.dst, ntp.flags.mode
NTP_TSV="$OUT/ntp.tsv"
tshark -r "$PCAP" -Y 'ntp' \
    -T fields \
    -e frame.time_epoch -e ip.src -e ip.dst -e ntp.flags.mode \
    > "$NTP_TSV" 2>/dev/null || true

# Mode 3 = client request; mode 4 = server response.
REQ_COUNT="$(awk -F'\t' -v bind="$NTP_BIND_IP" '$3==bind && $4==3' "$NTP_TSV" | wc -l)"
RESP_COUNT="$(awk -F'\t' -v bind="$NTP_BIND_IP" '$2==bind && $4==4' "$NTP_TSV" | wc -l)"

NTP_EXCHANGE_OK="false"
if (( REQ_COUNT > 0 && RESP_COUNT > 0 )); then
    NTP_EXCHANGE_OK="true"
    pass "NTP exchange observed (${REQ_COUNT} requests, ${RESP_COUNT} responses)"
elif (( REQ_COUNT > 0 && RESP_COUNT == 0 )); then
    fail "device sent ${REQ_COUNT} NTP requests but rig did NOT respond — check chrony container logs"
elif (( REQ_COUNT == 0 )); then
    fail "no NTP traffic to ${NTP_BIND_IP} in ${DURATION}s"
    note "device may not be reaching us; verify aliases bound + cable connected"
fi

# Trust-progression check: inter-arrival of mode-3 requests from the
# device. A trusting client backs off (~32s -> 64s -> 128s); a non-
# trusting client either stops or hammers at minimum interval.
INTERVALS_JSON="[]"
TRUST_VERDICT="not-checked"
if (( REQ_COUNT >= 2 )); then
    INTERVALS=()
    PREV=""
    while IFS=$'\t' read -r t src dst mode; do
        [[ "$dst" == "$NTP_BIND_IP" && "$mode" == "3" ]] || continue
        if [[ -n "$PREV" ]]; then
            INTERVALS+=("$(awk -v a="$t" -v b="$PREV" 'BEGIN { printf "%.2f", a - b }')")
        fi
        PREV="$t"
    done < "$NTP_TSV"

    INTERVALS_JSON="[$(IFS=,; echo "${INTERVALS[*]}")]"
    printf '  intervals (s): %s\n' "${INTERVALS[*]:-(none)}"

    # If duration is short, we typically only see fast-burst — that's
    # fine, just call out the limitation.
    if (( DURATION < 180 )); then
        TRUST_VERDICT="fast-burst-only (rerun with --duration 300+ for back-off observation)"
        note "trust-progression: fast-burst window only (DURATION=${DURATION}s); use --duration 300+ to observe back-off"
    else
        # Crude check: are intervals monotonically non-decreasing?
        # (Allow some jitter — chrony's actual back-off has ±5% tolerance.)
        MONO=1
        prev=0
        for v in "${INTERVALS[@]}"; do
            if awk -v a="$v" -v b="$prev" 'BEGIN { exit !(a + 1 < b) }'; then
                MONO=0; break
            fi
            prev="$v"
        done
        if (( MONO == 1 )); then
            TRUST_VERDICT="back-off observed"
            pass "trust-progression: intervals monotonically non-decreasing (device trusts our responses)"
        else
            TRUST_VERDICT="no-back-off"
            warn "trust-progression: intervals NOT increasing — device may not trust our responses"
        fi
    fi
elif (( REQ_COUNT == 1 )); then
    note "only 1 request seen — not enough data for trust-progression check; capture longer"
fi

# ── Verdict ────────────────────────────────────────────────────────
printf '\n'
if (( FAILED == 0 )); then
    printf 'PASS  rig responding correctly (case %s)\n' "$CASE"
    VERDICT="PASS"
else
    printf 'FAIL  see assertions above\n'
    VERDICT="FAIL"
fi

# ── summary.json ───────────────────────────────────────────────────
jq -n \
    --arg run_id "$RUN_ID" \
    --argjson duration "$DURATION" \
    --arg case "$CASE" \
    --arg ntp_target "$NTP_TARGET" \
    --arg ntp_target_kind "$NTP_TARGET_KIND" \
    --arg ntp_bind_ip "$NTP_BIND_IP" \
    --arg dns_primary_ip "$DNS_PRIMARY_IP" \
    --arg dns_secondary_ip "$DNS_SECONDARY_IP" \
    --argjson dns_query_count "$DNS_QUERY_COUNT" \
    --argjson dns_response_ok "$DNS_RESPONSE_OK" \
    --argjson req_count "$REQ_COUNT" \
    --argjson resp_count "$RESP_COUNT" \
    --argjson ntp_exchange_ok "$NTP_EXCHANGE_OK" \
    --argjson intervals "$INTERVALS_JSON" \
    --arg trust_verdict "$TRUST_VERDICT" \
    --arg verdict "$VERDICT" \
    '{
        run_id: $run_id,
        duration_seconds: $duration,
        config: {
            case: $case,
            ntp_target: $ntp_target,
            ntp_target_kind: $ntp_target_kind,
            ntp_bind_ip: $ntp_bind_ip,
            dns_primary_ip: $dns_primary_ip,
            dns_secondary_ip: ($dns_secondary_ip | select(. != ""))
        },
        results: {
            dns: {
                query_count: $dns_query_count,
                response_correct: $dns_response_ok
            },
            ntp: {
                request_count: $req_count,
                response_count: $resp_count,
                exchange_seen: $ntp_exchange_ok,
                inter_request_intervals_sec: $intervals,
                trust_progression_verdict: $trust_verdict
            }
        },
        verdict: $verdict
    }' > "$OUT/summary.json"

DNS_LOG_LINES="$(wc -l < "$DNS_LOG")"
printf '\nartifacts:\n  %s\n' "$OUT"
printf '  ├── ntp.pcap     (%d packets)\n' "$PCAP_PACKETS"
printf '  ├── ntp.tsv      (parsed NTP fields)\n'
printf '  ├── dns.log      (%d lines)\n' "$DNS_LOG_LINES"
printf '  └── summary.json\n'

exit $(( FAILED == 0 ? 0 : 1 ))
