# Implementation Report: simulate-ntp-dns-for-neeve-node-bench-test (rig complete)

| Field | Value |
|-------|-------|
| **Plan** | `.ai/plans/2026-05-08-1322-jkoti-neeve-scope-cisco-ntp-dns-planning.md` |
| **Session** | `.ai/sessions/2026-05-08-1805-jkoti-neeve-implementation-2.md` |
| **Owner** | jkoti-neeve |
| **Started** | 2026-05-08 15:29 EDT |
| **Completed** | 2026-05-08 18:20 EDT |
| **Agent** | Claude Code |
| **Project** | `C:\dev\cisco-ntp-dns` |
| **Git Branch** | `main` (origin/main at `e0b3912` + this report's session-end commit) |
| **Commits (this session)** | `e0b3912` |
| **Prior report** | `.ai/reports/plan-implementation/2026-05-08-1521-jkoti-neeve-implement-initial-plan-report.md` (chunks 1, 4, 5, 8 + spike) |

---

## Executive Summary

Final implementation session for the bench-test rig. Delivered chunk 7
(`scripts/verify.sh`) — automated pass/fail with case-aware assertions,
tshark-parsed NTP mode 3/4 verification, and a chrony trust-progression
check. **All 9 originally-planned chunks are now resolved**; the rig is
feature-complete pending operator-side VM provisioning and cable-up
against the actual Neeve node.

---

## Plan Implementation Status (final state)

| # | Chunk | Status | Notes |
|---|---|---|---|
| 1 | `.env.example` + `scripts/render-config.sh` | DONE | Smoke-tested: 4/4 config-matrix cases (A/B/C/D), 4 negative paths catch errors |
| 2 | `Corefile.tmpl` + `seed.hosts.tmpl` | DONE | Folded into chunk 1 (templates are render-config's contract) |
| 3 | `chrony.conf.tmpl` | DONE | Folded into chunk 1 |
| 4 | `docker-compose.yml` *(post-spike revision)* | DONE | `network_mode: host` for both services; `docker/ntp/Dockerfile` (Alpine 3.20 + chrony) added |
| 5 | host NIC alias script *(post-spike revision)* | DONE | Bash `scripts/setup-host-nic.sh` (was PowerShell pre-spike); idempotent add / `--teardown` |
| 6 | host port forwarding | DROPPED | Linux-host architecture binds via `network_mode: host` — no proxy needed |
| 7 | `scripts/verify.sh` | DONE | This session. ~250-line bash; 60 s default, configurable |
| 8 | `README.md` runbook | DONE | 337 lines (chunk 8) + this session's tshark/jq update |
| 9 | `.gitignore` polish | PARTIAL | Pulled into chunk 1 commit (added `.env`, `out/`, `*.pcap`); other refinements unnecessary |

---

## What `verify.sh` Does

Captures DNS query log + UDP/123 pcap for `--duration` seconds (default 60),
then runs assertions parameterized by the active config-matrix case:

| Case | Detection | DNS assertion | NTP assertion |
|------|-----------|---------------|---------------|
| **A** (1 DNS + FQDN) | `DNS_SECONDARY_IP` blank, `NTP_TARGET` matches FQDN regex | At least one query for `${NTP_TARGET}`; seed.hosts maps it to `${NTP_BIND_IP}` | At least one mode 3 → mode 4 exchange at `${NTP_BIND_IP}` |
| **B** (2 DNS + FQDN) | Both DNS set, FQDN target | Same as A | Same as A |
| **C** (1 DNS + IP) | One DNS, IP-literal target | None — empty DNS log is normal (note printed) | Same as A |
| **D** (2 DNS + IP) | Two DNS, IP-literal target | Same as C | Same as A |

**Trust-progression check** (chrony's 32s → 64s → 128s back-off): collects
inter-arrival times of mode-3 requests, verifies non-decreasing pattern.
Calls out windows shorter than 180 s as fast-burst-only (not enough data
for full back-off observation) and recommends `--duration 300+`.

**Outputs to `out/run/<run-id>/`**:

- `ntp.pcap` — full UDP/123 capture
- `ntp.tsv` — tshark-extracted NTP fields (one packet per row)
- `dns.log` — `docker compose logs --since` for the dns service
- `summary.json` — machine-readable verdict + per-step results
- Console output (human-readable, also reproducible from `summary.json`)

---

## Technical Decisions (this session)

### Decision 1: Default `--duration 60`, document longer for back-off

- **Context**: How long should `verify.sh` capture by default?
- **Options**: 60 s (Recommended), 300 s, configurable-only-no-default
- **Chosen**: 60 s with `--duration` override
- **Rationale**: 60 s sees the initial fast-burst (~6 packets in first 30 s) and one back-off transition — enough to confirm "device trusts us" qualitatively. Default fast enough for routine operator iteration; explicit longer flag for definitive trust-progression analysis.
- **Trade-off**: At 60 s the back-off check can only conclude "fast-burst observed", not "32s→64s→128s back-off observed". Script prints this explicitly.

### Decision 2: Case C/D explanatory note when DNS log is empty

- **Context**: When `NTP_TARGET` is an IP literal, the device never queries DNS for the NTP target. Empty DNS log is then *normal*, not a failure.
- **Options**: silent skip; warning; explanatory note
- **Chosen**: One-line note: `note: NTP_TARGET is an IP literal (case ${CASE}); no DNS query expected`
- **Rationale**: Predictable confused-operator question; preempting it is cheap and improves operator experience.

### Decision 3: Use tshark, not custom parsing

- **Context**: Need to extract NTP mode + timing from pcap.
- **Options**: tshark; custom awk on `tcpdump -tttt -vv` output; Python with `dpkt`
- **Chosen**: tshark.
- **Rationale**: tshark's NTP dissector is canonical. Reproducing protocol details in awk would be a re-implementation; risk of subtle bugs.
- **Trade-off**: tshark is a hard dependency (~150 MB install on Ubuntu — not ideal but acceptable for a bench-test rig).

### Decision 4: Trust-progression check is non-decreasing only

- **Context**: How strict should the back-off check be?
- **Options**: strict-increasing; non-decreasing; explicit chrony-pattern matching (1.5x-3x growth per step)
- **Chosen**: non-decreasing (with 1-second jitter tolerance)
- **Rationale**: Constant-interval polling on a stable trusted client is legitimate (steady-state). A strict-increasing check would false-positive that case.
- **Trade-off**: A non-trusting client retrying at constant minimum interval also passes. The script prints the raw `intervals` array so the operator can sanity-check — varying intervals = trusting, constant minimum = not trusting.

### Decision 5: No `summary.txt`

- **Context**: Whether to write a text companion to `summary.json`.
- **Chosen**: No — console output IS the human-readable form.
- **Rationale**: Reduces output sprawl. Operator can `tee` console if archival is needed.

---

## Assumptions Made

| # | Assumption | Risk if Wrong |
|---|---|---|
| 1 | `docker compose ps --status running --services` is supported on Ubuntu 24.04's docker-ce | Low — fall back to `docker compose ps -q ${name}` is trivial |
| 2 | tshark's NTP dissector returns mode in field `ntp.flags.mode` | Low — well-established Wireshark filter; verifiable |
| 3 | chrony's `--since` log filter accepts `${N}s` form | Low — standard Compose v2 syntax |
| 4 | Devices using FQDN NTP targets resolve at startup, then talk NTP | Medium — some clients hardcode IP after first resolve and never re-resolve, which means restarting our DNS would invalidate the test. Out of scope to detect. |
| 5 | Linux host clock is reasonably accurate (within minutes of NTP servers) | Low — chrony in `manual` mode serves whatever the host has; if host clock is wildly wrong, served time will be wrong, but the rig still measures the protocol exchange correctly |

---

## Files Changed (this session)

| File | Action | Description |
|---|---|---|
| `scripts/verify.sh` | ADD | Automated pass/fail (~250 lines, bash + tshark + jq) |
| `README.md` | MODIFY | Added tshark + jq to install list; dropped "verify.sh coming"; observation step leads with the automated path |
| `.ai/sessions/2026-05-08-1805-jkoti-neeve-implementation-2.md` | NEW (gitignored) | This session's session file |
| `.ai/reports/plan-implementation/2026-05-08-1820-jkoti-neeve-implementation-2-report.md` | NEW | This report |

---

## Testing & Verification

| Step | Result | Evidence |
|---|---|---|
| `bash -n scripts/verify.sh` | PASS | "syntax OK" |
| `bash scripts/verify.sh --help` (no root) | PASS | Prints help block, exits 0 |
| `bash scripts/verify.sh --bogus` | PASS (rejected) | `error: unknown argument: --bogus` |
| `bash scripts/verify.sh --duration 3` | PASS (rejected) | `error: --duration must be an integer >= 5` |
| `bash scripts/verify.sh` (no root) | PASS (rejected) | `error: must run as root` |
| **End-to-end runtime test** | NOT RUN | Requires the Linux VM, which is operator-provisioned out-of-band. The rig and verify.sh are static-checked only. |

---

## Challenges & Solutions (this session)

### Challenge 1: Trust-progression check has a soft-spot

- **Problem**: Non-decreasing intervals correctly identifies "device trusts us and is in steady state," but also matches "device doesn't trust us and retries at constant minimum interval."
- **Root Cause**: Both states present as constant intervals at the protocol surface. Distinguishing them needs either (a) longer observation to see the back-off, or (b) the actual interval value (chrony's iburst minimum is ~2 s, steady-state is ~64–1024 s).
- **Solution**: Document the soft-spot; print the raw `intervals` array; recommend `--duration 300+` for definitive results.
- **Lesson**: Black-box verification has limits — sometimes the operator's eyes are still needed. Print the raw signal even when you've also computed a verdict.

### Challenge 2: Default 60 s window can't see chrony's 32s → 64s → 128s back-off

- **Problem**: Chrony's full back-off ramp takes minutes. A 60 s capture only catches the initial fast burst.
- **Root Cause**: Chrony's poll-interval growth pattern is logarithmic over minutes.
- **Solution**: Default to 60 s for routine "is the rig responding" checks; explicitly note when window is < 180 s; document `--duration 300+` for definitive back-off observation.
- **Lesson**: Match default to the most common operator intent (quick check) but make the longer/stricter mode discoverable.

### Challenge 3: `docker compose logs --since "60s"` may include logs older than the capture window if container started during the window

- **Problem**: If the operator brings up the rig and immediately runs verify, `--since` returns logs back to container start, not just the verify window.
- **Solution**: For routine use this is harmless (the extra logs are real DNS queries, just from before our window). Operator should bring up the rig first, then run verify after a short pause.
- **Documented**: README's "Per-test §6" implicitly covers this by ordering steps (compose up → cable up → verify).

---

## Questions Senior Engineers Might Ask

### Q: Why not put verify.sh inside a sidecar container?

**A**: Two reasons:
1. **tcpdump on the host NIC**: needs to see the actual cabled-NIC traffic, not just the container's view. Containers see traffic via Docker's network namespace; for `network_mode: host` containers, that IS the host namespace, so technically a sidecar could work — but it would add complexity (cap_add NET_ADMIN/NET_RAW, volume mount for output) for no real gain.
2. **Operator simplicity**: `sudo bash scripts/verify.sh` is one command; running a sidecar adds compose surface area and lifecycle management.

### Q: Is `tshark` overkill — couldn't `tcpdump -A` parse modes inline?

**A**: `tcpdump -A` shows ASCII; NTP packets are binary with no readable text. tshark's NTP dissector is canonical. The size cost is real (~150 MB installed) but acceptable for a bench-test rig that's not constrained on disk.

### Q: How is `verify.sh`'s exit code consumed?

**A**: 0 = PASS, 1 = FAIL, anything else = pre-flight error. Useful for CI / scripted runs, but the rig is currently used interactively. The exit code is the canonical "did it pass" signal; `summary.json`'s `verdict` field mirrors it.

### Q: Why doesn't the script restart the rig if it finds the stack down?

**A**: Operator intent: pre-flight should fail loudly when the stack isn't running, not auto-recover. Auto-recovery makes failures harder to diagnose and breaks the contract that "verify only verifies what's there now."

### Q: What stops `--duration 86400` from filling the disk with pcap?

**A**: Nothing in the script. UDP/123 traffic for one device is tiny (~80 bytes per packet, a few packets per minute), so 24 hours = ~10 KB. For DNS, similar order. Practically a non-issue. If we ever ran this against high-traffic infrastructure, a `--max-packets` cap would matter.

---

## What's Left / Follow-up Items (operator-side)

- [ ] **Provision the Hyper-V Linux VM** per `README.md` § "One-time setup". One-time, ~20 min.
- [ ] **First smoke test inside the VM**: `bash scripts/render-config.sh` + `sudo bash scripts/setup-host-nic.sh` + `docker compose up -d` + `sudo bash scripts/verify.sh --duration 30`. Last step expected to FAIL (no device, no traffic) — proves the harness runs.
- [ ] **Get the device facts** (Q-IP, Q-DNS, optionally Q-EXTRA): static or DHCP? Expected node IP/subnet? Exact primary + secondary DNS IPs the device's preconfig points at?
- [ ] **Edit `.env` with real values** + re-run render-config + re-bind aliases.
- [ ] **Cable up the device**, run `sudo bash scripts/verify.sh --duration 300` (longer window for full back-off observation), inspect `summary.json` + `intervals` array.
- [ ] **DHCP service** — only if Q-IP closes as DHCP. Add a `--profile dhcp` compose service.
- [ ] **Update `.env.example`'s default `HOST_NIC_NAME`** from `"Ethernet 4"` (Windows holdover) to a Linux interface name like `eth1`.
- [ ] **Framework upstream issues**: monitor #1 (force-with-lease block) and #2 (CRLF in commands) on `kchristo-neeve/neeve-ai-dev-framework`.

---

## Raw Session Data

<details>
<summary>Git Log (commits during this session)</summary>

```
e0b3912 chunk 7: verify.sh — automated pass/fail
```

</details>

<details>
<summary>Files Diff Summary (since session start)</summary>

```
 README.md           |  29 +++++++--
 scripts/verify.sh   | 274 ++++++++++++++++++++++++++++++++++++++++++
```

</details>

<details>
<summary>Cumulative project state (all sessions)</summary>

Files at session end (gitignored items omitted):

```
.env.example
.gitignore
README.md
docker-compose.yml
docker/dns/Corefile.tmpl
docker/dns/zones/seed.hosts.tmpl
docker/ntp/Dockerfile
docker/ntp/chrony.conf.tmpl
scripts/render-config.sh
scripts/setup-host-nic.sh
scripts/verify.sh
setup-framework.sh
.ai/PROJECT_CONFIG.md
.ai/PROJECT_LESSONS.md
.ai/plans/2026-05-08-1322-jkoti-neeve-scope-cisco-ntp-dns-planning.md
.ai/reports/plan-implementation/2026-05-08-1521-jkoti-neeve-implement-initial-plan-report.md
.ai/reports/plan-implementation/2026-05-08-1820-jkoti-neeve-implementation-2-report.md  (this file)
```

</details>

---

*Report generated by `/session-end` on 2026-05-08 18:20 EDT.*
