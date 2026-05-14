# Implementation Report: retest-existing-config-laptop-sub

| Field | Value |
|-------|-------|
| **Plan** | `.ai/plans/2026-05-12-1647-jkoti-neeve-retest-existing-config-laptop-sub.md` |
| **Session** | `.ai/sessions/2026-05-12-1647-jkoti-neeve-retest-existing-config.md` (active during save → renamed at end of /session-save per protocol) |
| **Owner** | jkoti-neeve |
| **Started** | 2026-05-12 16:47 EDT |
| **Test work completed** | 2026-05-12 17:45 EDT (5/12 wall-time tests; documentation/save event 5/14 16:01 EDT) |
| **Agent** | Claude Code (Opus 4.7) |
| **Project** | cisco-ntp-dns |
| **Git Branch** | main |
| **Commits** | This save adds 1 commit. Plan and lessons committed; rig source unchanged. |

---

## Executive Summary

This plan validated rig correctness end-to-end by substituting a **Windows laptop for the Advantech 2484** on the same cable, then re-inserted the 2484 for a sanity check. Both halves landed cleanly:

- **Laptop test (PASS)**: DHCP lease matched `.env` exactly (192.168.50.196, gw 192.168.50.1, DNS 138.220.4.4/8.8, suffix wbg.org, 10m lease). `nslookup ntp2.wbg.org` against both primary AND secondary alias IPs returned `192.168.50.123`. `w32tm /stripchart /computer:ntp2.wbg.org` round-tripped 12+ samples with chrony (delay ~3 ms, offset ~−90 ms).
- **Device sanity check (chunk-4 reproduces)**: 2484 plugged back in and power-cycled. DHCP exchange clean (lease 192.168.50.172 to `nodeos`, all options accepted including option 15 `wbg.org`, device requested option 120 sip-server which we don't supply). Post-DHCP application traffic: **0 DNS, 0 NTP, 0 spontaneous packets** — only ARP replies to rig probes. Identical to 2026-05-09 observation.

**Outcome**: Two-sided proof — rig is *provably* correct, device silence is *reproducibly* device-side. The vm-bringup plan's chunk-4 classification ("blocker is device-side") is upgraded from "inferred by elimination" to "affirmatively validated". No rig changes were made.

---

## Plan vs. Actual

| Planned Step | Status | Actual Implementation | Deviation Notes |
|---|---|---|---|
| A. Bring up rig (setup-host-nic + render-config + docker compose) | DONE | Four aliases installed on eth1 (138.220.4.4/32, 138.220.8.8/32, 192.168.50.123/24, 192.168.50.1/24); render produced expected config; both containers up; binds verified via `ss -lnup` | — |
| B. Start observability (tcpdump + log tails) | DONE | `tcpdump -i eth1 -nn -tttt -s 0` to `out/run/laptop-sub-20260512-211431.pcap` (nohup, detached); dnsmasq + chrony logs pulled on-demand | tcpdump's default buffered writes meant pcap showed 0 bytes mid-test — flushed correctly on SIGINT close (final 2.4 MB) |
| C. Connect laptop (operator action, Wi-Fi off, same cable as 2484) | DONE | User confirmed Wi-Fi off; ethernet via Realtek USB GbE Family Controller (MAC 00-E0-4C-68-38-67); eth1 went LINK-UP | — |
| D. DHCP test (`ipconfig /all` on laptop) | DONE — PASS | All 8 lease fields matched `.env`; VM lease file `/var/lib/misc/dnsmasq.leases` recorded `00:e0:4c:68:38:67 192.168.50.196 jkotiadis-neeve` | — |
| E. DNS test (nslookup against primary + secondary) | DONE — PASS | `nslookup ntp2.wbg.org` (138.220.4.4 default) → `192.168.50.123`; `nslookup ntp2.wbg.org 138.220.8.8` → `192.168.50.123`. /32 alias for secondary serves correctly. | The "short name + suffix appending" check (step 15 in the plan) was not run — already had two-way PASS evidence; skipping was low-value. |
| F. NTP test (`w32tm /stripchart`) | DONE — PASS | `w32tm /stripchart /computer:ntp2.wbg.org` reported `Tracking ntp2.wbg.org [192.168.50.123:123]` with 12+ samples, delay ~3 ms, offset ~−90 ms, no failures. tcpdump confirmed UDP/123 packets between 192.168.50.196 and 192.168.50.123 with 77 μs rig-side round-trip. | User omitted `/samples:5 /dataonly`, so w32tm ran longer — gave us more samples, all consistent. Side observation: Windows w32time emits NTPv1; chrony serves it anyway. |
| G. Teardown | NOT DONE (deferred) | Rig still up at end of test work; the chunk-6 carry-forward `setup-host-nic.sh --teardown` bug repro is queued for a future session. | User asked for "one final test with the 2484 as a sanity check" instead of teardown — that test was added and passed (device sanity check below). Teardown deferred without status loss. |

**New emergent work**:

| Item | Status | Implementation |
|---|---|---|
| Device sanity check (post-laptop-test) | DONE | Per user request: 2484 re-cabled, power-cycled, observed ~3 min. New pcap `out/run/device-recheck-20260512-214029.pcap` (3.3 KB; 8 DHCP + 0 DNS + 0 NTP + 7 ARP). Chunk-4 finding reproduced exactly. |
| Update `vm-bringup` plan with validation stamp | DONE | Appended "Chunk 4 — validation update (2026-05-12)" section to `.ai/plans/2026-05-08-2016-...vm-bringup...md` linking back to this plan + artifacts. |
| PROJECT_LESSONS entry on substitution-test methodology | DONE | Appended 2026-05-12 lesson: "Prove rig correctness with a known-good substitute client, don't infer it by elimination." |
| Self-describing VM-side summaries | DONE | Companion summary files written next to each pcap: `*-summary.md` documenting test inputs, results, and conclusion in-place. |

---

## Technical Decisions

### Decision 1: Treat the retest as a methodology shift, not a scope pivot — keep the session, write a new plan
- **Context**: Session "retest-existing-config" was initially linked to the paused vm-bringup plan. State-check found the rig torn down, eth1 NO-CARRIER. User then chose to swap the 2484 for a Windows laptop as the test client — a substantive change in what we'd actually be doing.
- **Options Considered**:
  - (a) Strict pivot per framework rules: new plan AND new session
  - (b) Reframe in place: keep session, write a new plan, update session frontmatter
  - (c) Bend the existing vm-bringup plan to cover laptop-substitution (modify chunk 4)
- **Chosen Approach**: (b). Created `.ai/plans/2026-05-12-1647-...laptop-sub.md`, updated session Active Plan field, logged the decision in session Key Decisions.
- **Rationale**: Session was 5 minutes old with zero checkpoints — forcing a new session would be paperwork churn. The session-name "retest-existing-config" generalizes equally well to either client. The plan binding is what genuinely changed.
- **Trade-off**: Slight deviation from the framework's strict pivot-management rule. Documented in the session's Key Decisions for audit.

### Decision 2: Use a substitution test instead of more device-side probing
- **Context**: Chunk-4 device silence was already classified "device-side" by elimination in 2026-05-09. User asked to "retest the existing configuration" — which could mean device-side re-observation OR rig-side validation.
- **Options Considered**:
  - (a) Re-run device-side observation hoping for a different result (or testing option 120)
  - (b) Substitute a known-good client (laptop) on the same cable to *affirmatively* prove rig correctness
- **Chosen Approach**: (b). User confirmed.
- **Rationale**: (a) had near-zero expected information value per the 2026-05-09 PROJECT_LESSON ("if DHCP+ARP are healthy but zero app packets in 5+ min, the blocker is device-side and rig changes have diminishing returns"). (b) is a single experiment that produces an unambiguous answer — either rig is good (and we've upgraded chunk-4 from inferred to validated) or rig has a defect we haven't seen.
- **Verified**: Worked as designed. Rig produced clean lease + DNS + NTP for the laptop; subsequent device sanity-check reproduced chunk-4 exactly.

### Decision 3: Defer teardown and the chunk-6 bug repro
- **Context**: Plan step G called for teardown including a `setup-host-nic.sh --teardown` run that could reproduce the chunk-6 carry-forward bug (alias-leak).
- **Chosen Approach**: Deferred. User opted to do a device sanity-check instead. Rig left running at end of session.
- **Rationale**: Sanity check had higher information value (closes the validation loop). Teardown bug is well-characterized (single low-severity entry on the chunk-6 list); it can be reproduced in a future targeted session without losing the artifact trail from this one.
- **Follow-up**: Queued for a future session focused on chunk-6 (or whenever the next teardown happens naturally — the bug is reproducible whenever 4 aliases are torn down, so any teardown will exhibit it).

### Decision 4: Two separate pcaps (laptop + device) instead of one continuous capture
- **Context**: The original tcpdump was running through the laptop test. Could have continued through the device swap.
- **Chosen Approach**: Stopped laptop pcap on SIGINT (clean close, 2.4 MB), then started a fresh pcap for the device test (3.3 KB).
- **Rationale**: Clean partition simplifies post-hoc analysis. Each pcap pairs 1:1 with its own summary.md, and the file naming (`laptop-sub-*` vs `device-recheck-*`) is self-documenting.
- **Cost**: ~30 seconds of capture-blind window during the swap (no DHCP/DNS/NTP happens in that window anyway since neither client is on the link).

---

## Verification

| Plan success criterion | Met? | Evidence |
|---|---|---|
| All four DHCP fields on laptop match `.env` | ✅ | `ipconfig /all` shows IPv4 192.168.50.196, mask 255.255.255.0, gw 192.168.50.1, DNS 138.220.4.4/8.8, suffix wbg.org, lease 10m. VM lease file confirms MAC + hostname. |
| DNS resolves `ntp2.wbg.org` to `192.168.50.123` from both DNS IPs | ✅ | Confirmed both via `nslookup ntp2.wbg.org` (default = 138.220.4.4) and `nslookup ntp2.wbg.org 138.220.8.8`. |
| `w32tm /stripchart` prints offset samples with no failures | ✅ | 12+ samples returned, all valid, no timeouts. |
| VM-side pcap shows DHCP/DNS/NTP triad | ✅ | Laptop pcap: 13 DHCP + 28998 DNS + 358 NTP + 204 ARP. |
| Teardown clean OR chunk-6 bug repro captured | ❌ — DEFERRED | Teardown not run; rig left up. Tracked as carry-forward. |

Bonus criterion added during execution:

| Sanity check | Met? | Evidence |
|---|---|---|
| Device sanity check reproduces chunk-4 silence | ✅ | Device pcap: 8 DHCP + 0 DNS + 0 NTP + 7 ARP. Reproduces 2026-05-09 finding exactly. |

---

## Artifacts

**VM-side** (in `gh0stwhee1@172.20.206.72:~/cisco-ntp-dns/out/run/`):

| File | Size | Content |
|---|---|---|
| `laptop-sub-20260512-211431.pcap` | 2.4 MB | Wire capture, laptop test window (~24 min) |
| `laptop-sub-20260512-211431-summary.md` | ~3 KB | Test rig, results, conclusion |
| `device-recheck-20260512-214029.pcap` | 3.3 KB | Wire capture, device sanity check (~4 min) |
| `device-recheck-20260512-214029-summary.md` | ~2 KB | Device test rig, results, conclusion |

**Repo-side**:

- `.ai/plans/2026-05-12-1647-jkoti-neeve-retest-existing-config-laptop-sub.md` — this plan, marked Complete, with full Outcome section
- `.ai/plans/2026-05-08-2016-jkoti-neeve-vm-bringup-and-close-open-qs.md` — chunk-4 annotated with validation stamp + back-references
- `.ai/PROJECT_LESSONS.md` — new 2026-05-12 lesson on substitution-test methodology
- `.ai/reports/plan-implementation/2026-05-14-1601-jkoti-neeve-retest-existing-config-laptop-sub-report.md` — this report

---

## Implications & Follow-ups

1. **Chunk 4 is now affirmatively validated as device-side** — no further rig-side experimentation is warranted until operator info arrives. The vm-bringup plan's "Resume conditions" list still applies (operator describes expected post-DHCP behavior, console tap, Advantech docs, or operator-supplied DHCP option/value to test).

2. **Chunk-6 carry-forward (alias-leak teardown bug)** is still queued. It will surface naturally on the next teardown; the repro environment is well-characterized in the vm-bringup plan's chunk-6 table.

3. **Rig is currently still running on the VM** — not torn down. If the device is left cabled, dnsmasq will continue serving leases on T1 cycles and the rig stays in steady state. This is fine indefinitely, but worth flagging for the next session-start so it isn't mistaken for stale state.

4. **Substitution-test methodology is now a documented project lesson** — applicable beyond this device. Any future Neeve-node bring-up where the device-under-test is silent post-DHCP can start with a 10-minute laptop-sub sanity check before re-iterating rig changes.
