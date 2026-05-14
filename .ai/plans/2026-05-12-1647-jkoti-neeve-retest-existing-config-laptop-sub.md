# Plan: retest-existing-config — laptop substitution

| Field | Value |
|-------|-------|
| **Owner** | jkoti-neeve |
| **Created** | 2026-05-12 16:47 EDT |
| **Status** | Complete (2026-05-12) — PASS, including device sanity-check reproducing chunk-4 |
| **Supersedes (for current session only)** | `.ai/plans/2026-05-08-2016-jkoti-neeve-vm-bringup-and-close-open-qs.md` chunks 4–5. That plan stays paused; this plan does not modify it. |

---

## Context

The vm-bringup plan paused at chunk 4 because the Advantech 2484 emits no DNS/NTP post-DHCP-ACK. Rig-side everything was clean (DHCP exchange, T1 renewal, ARP, option 15) but the device's app stack is silent for reasons the rig cannot diagnose.

This plan **isolates rig correctness from the device** by substituting a known-good DHCP/DNS/NTP client — a Windows laptop — on the same physical link. If the rig answers correctly to a laptop, the chunk-4 blocker is provably device-side. If the rig fails to answer a laptop, we've found a rig defect that the device's silence was masking.

---

## Pre-conditions

- VM (`gh0stwhee1@172.20.206.72`) reachable on mgmt vNIC (eth0) — ✅ confirmed 2026-05-12 16:50 EDT
- VM's `eth1` is the cabled vNIC bridged to the physical NIC on the dev host — ✅
- Repo on VM is at `6f0cc16` on `main`, clean — ✅
- `.env` matches documented config (DNS=138.220.4.4/8.8, NTP=ntp2.wbg.org, gw=192.168.50.1, domain=wbg.org) — ✅
- Laptop: Windows, ethernet NIC available, Wi-Fi will be **off** during test
- Physical: same cable that was on the 2484 → unplug from device → plug into laptop ethernet

---

## Test sequence

### A. Bring up the rig on the VM (mutating)
1. `sudo bash scripts/setup-host-nic.sh` — install four aliases on eth1:
   - 192.168.50.1/24 (gateway)
   - 192.168.50.123/24 (NTP bind)
   - 138.220.4.4/32 (DNS primary)
   - 138.220.8.8/32 (DNS secondary)
2. `bash scripts/render-config.sh` — re-render Corefile/zones/chrony.conf from `.env` (idempotent)
3. `sudo docker compose up -d` — start dnsmasq + chrony
4. Confirm: `sudo docker compose ps` shows both services healthy; `sudo ss -lnup | grep -E ':(53|67|123)\b'` shows binds on the alias IPs.

### B. Start observability (read-only, non-blocking)
5. Background: `sudo tcpdump -i eth1 -nn -tttt -w out/run/laptop-sub-$(date +%s).pcap` so every packet is captured for later analysis.
6. Foreground tail: `sudo docker compose logs -f dns ntp` so we see DHCP/DNS/NTP events live.

### C. Connect the laptop (operator action)
7. Disable Wi-Fi on laptop.
8. Unplug ethernet from 2484, plug into the same cable end that was on the device.
9. eth1 on the VM should go LINK-UP (`ip link show eth1` → no `NO-CARRIER`).

### D. DHCP test (laptop)
10. On laptop: `ipconfig /release` then `ipconfig /renew` (or just plug in — Windows auto-DHCPs).
11. On laptop: `ipconfig /all` — assert:
    - IPv4 in 192.168.50.100–200 range
    - Subnet mask 255.255.255.0
    - Default gateway 192.168.50.1
    - DNS Servers: 138.220.4.4 and 138.220.8.8
    - Connection-specific DNS Suffix: wbg.org
    - Lease obtained from 192.168.50.123 (or wherever dnsmasq advertised itself as the server)
12. On VM logs: confirm DISCOVER → OFFER → REQUEST → ACK with the laptop's MAC.

### E. DNS test (laptop)
13. `nslookup ntp2.wbg.org` (uses primary DNS by default) → expect `192.168.50.123`.
14. `nslookup ntp2.wbg.org 138.220.8.8` → expect `192.168.50.123` (proves secondary alias answers).
15. `nslookup ntp2 138.220.4.4` (short name with wbg.org suffix appended) → expect `192.168.50.123`.
16. On VM logs: confirm query lines hitting dnsmasq with the laptop's source IP.

### F. NTP test (laptop)
17. `w32tm /stripchart /computer:ntp2.wbg.org /samples:5 /dataonly` — should print 5 offset samples. Each sample = one UDP/123 exchange.
18. On VM logs/tcpdump: confirm UDP/123 packets between laptop IP and 192.168.50.123; chrony replies.
19. Optional: configure w32time to use ntp2.wbg.org and force resync. Out of scope for v1 unless steps 17–18 pass and we want a full clock-sync test.

### G. Teardown
20. `sudo docker compose down`
21. `sudo bash scripts/setup-host-nic.sh --teardown` — **watch for the chunk-6 carry-forward bug** (leaves an alias bound despite reporting "skip ... (not bound)"). If reproduced, capture `set -x` output for the bug repro.

---

## Success criteria

- **DHCP**: laptop gets a lease matching `.env` (gateway, DNS, suffix).
- **DNS**: `ntp2.wbg.org` resolves to `192.168.50.123` from both primary and secondary.
- **NTP**: `w32tm /stripchart` prints 5 samples (any reasonable offset is fine — we're proving reachability, not accuracy).
- **Captures**: VM-side pcap + dnsmasq log + chrony log all show coherent end-to-end traffic.

**Pass meaning**: the rig is provably correct for the DHCP/DNS/NTP triad. The 2484's silence in chunks 4 is conclusively device-side.

**Fail meaning**: rig has a defect that was masked by the device's silence. We capture the defect and fix it before re-trying the device.

---

## Risks / gotchas

| # | Risk | Mitigation |
|---|------|------------|
| 1 | Windows Defender Firewall blocks inbound DHCP responses (unusual; default profile usually permits) | If lease fails to come back, `Set-NetFirewallProfile -Profile Private -Enabled False` on laptop *temporarily* — re-enable after test |
| 2 | Laptop has a stale lease from another network on the same NIC | `ipconfig /release` before plugging into the rigged cable |
| 3 | Multiple DNS suffixes on laptop shadowing `wbg.org` | We do not rely on suffix appending alone; step 14 uses FQDN. Step 15 is informational |
| 4 | chrony refuses to serve because `local stratum 5` not yet stabilized | chrony.conf has `local stratum 5` + `manual`; serves immediately. Verified in chrony.conf.tmpl 2026-05-12 |
| 5 | USB-Ethernet on laptop instead of native NIC — driver quirks | User confirmed same cable as 2484 (likely native NIC). If symptoms differ, swap to a known-good adapter |
| 6 | dnsmasq doesn't advertise itself as DHCP server-identifier on a non-primary alias IP | Default behavior is correct; if observed, set `dhcp-option=option:server-identifier,192.168.50.123` |

---

## Files

| File | Action | Description |
|------|--------|-------------|
| Captures: `out/run/laptop-sub-*.pcap` | CREATE on VM | Wire-level proof for each test |
| `.ai/PROJECT_LESSONS.md` | APPEND if applicable | Lessons specific to laptop-substitution methodology |
| `.ai/plans/2026-05-08-2016-...vm-bringup...md` | NO CHANGE | Stays paused at chunk 4 |
| Rig source (`scripts/`, `docker/`, `.env.example`) | NO CHANGE expected | Pure verification; any fixes fork into a new plan |

---

## Verification

A successful end-of-session looks like:

1. ✅ All four DHCP fields on laptop match `.env`
2. ✅ DNS resolves `ntp2.wbg.org` to `192.168.50.123` from both rigged DNS IPs
3. ✅ `w32tm /stripchart` prints 5 offset samples with no failures
4. ✅ VM-side pcap shows the full DHCP/DNS/NTP triad with laptop's MAC and IP
5. ✅ Teardown either runs clean OR reproduces the chunk-6 bug with capturable evidence

---

## Outcome (2026-05-12)

**Status: PASS — all verification criteria except #5 met.** Teardown deferred (rig left up at end of session; chunk-6 bug repro is queued for a future teardown).

### Test 1 — laptop substitution (17:14–17:38 EDT)

| Verification item | Evidence |
|---|---|
| DHCP fields match `.env` | Laptop got 192.168.50.196/24, gw 192.168.50.1, DNS 138.220.4.4/8.8, suffix wbg.org, lease 10m; VM lease file confirms MAC + hostname `jkotiadis-neeve`. |
| DNS primary | `nslookup ntp2.wbg.org` (default = 138.220.4.4) → `Address: 192.168.50.123` |
| DNS secondary | `nslookup ntp2.wbg.org 138.220.8.8` → `Address: 192.168.50.123` |
| NTP | `w32tm /stripchart /computer:ntp2.wbg.org` → `Tracking ntp2.wbg.org [192.168.50.123:123]`, 12+ samples, d≈3 ms, o≈−90 ms |
| Pcap | `out/run/laptop-sub-20260512-211431.pcap` on VM (2.4 MB; 13 DHCP + 28998 DNS + 358 NTP + 204 ARP) |
| Summary | `out/run/laptop-sub-20260512-211431-summary.md` on VM |

Side observation (expected): Windows-background queries (`wpad.wbg.org`, `*.msftncsi.com`, `*.events.data.microsoft.com`, etc.) all received `REFUSED (EDE: not ready)` from dnsmasq — correct authoritative-only-without-upstream posture; cosmetically yields "no internet" in the Windows tray.

### Test 2 — device sanity check (17:40–17:45 EDT)

Inserted Advantech 2484 on the same cable, power-cycled, observed ~3 minutes post-DHCP-ACK:

| Verification item | Evidence |
|---|---|
| DHCP exchange | DISCOVER → ACK clean; lease 192.168.50.172 to MAC `cc:82:7f:91:75:6f`, hostname `nodeos`; all options sent including option 15 (wbg.org); device requested option 120 (sip-server) which we don't supply (consistent with 2026-05-09). |
| Post-DHCP application traffic | **0 DNS, 0 NTP, 0 spontaneous packets** — only ARP replies to rig probes. |
| Pcap | `out/run/device-recheck-20260512-214029.pcap` on VM (3.3 KB; 8 DHCP + 0 DNS + 0 NTP + 7 ARP) |
| Summary | `out/run/device-recheck-20260512-214029-summary.md` on VM |

### Combined conclusion

Two-sided proof: rig is provably correct **and** device silence is reproducible. The vm-bringup plan's chunk-4 classification ("blocker is device-side") is now affirmatively validated, not just inferred. The vm-bringup plan has been annotated accordingly. No rig changes are implied.

---

## Implementation Status

| Item | Status | Notes |
|---|---|---|
| A. Bring up rig (setup-host-nic + render + compose) | DONE | All 4 aliases, both containers, all binds verified. |
| B. Start observability (tcpdump + log tails) | DONE | 2 pcaps captured (laptop + device), clean SIGINT closes. |
| C. Connect laptop (Wi-Fi off, same cable) | DONE | User confirmed; eth1 went LINK-UP. |
| D. DHCP test | DONE — PASS | All 8 lease fields match `.env`. |
| E. DNS test (primary + secondary) | DONE — PASS | Both alias IPs return `192.168.50.123`. |
| F. NTP test (w32tm stripchart) | DONE — PASS | 12+ samples, ~3 ms delay, ~−90 ms offset, no failures. |
| G. Teardown | DEFERRED | Rig left up; chunk-6 bug repro queued for a future session. |

Implementation report: `.ai/reports/plan-implementation/2026-05-14-1601-jkoti-neeve-retest-existing-config-laptop-sub-report.md`
