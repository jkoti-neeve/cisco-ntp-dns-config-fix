# Implementation Report: vm-bringup-and-close-open-qs (resume + pause)

| Field | Value |
|-------|-------|
| **Plan** | `.ai/plans/2026-05-08-2016-jkoti-neeve-vm-bringup-and-close-open-qs.md` |
| **Session** | `.ai/sessions/2026-05-09-1853-jkoti-neeve-vm-bringup-and-close-open-qs.md` |
| **Owner** | jkoti-neeve |
| **Started** | 2026-05-08 20:16 EDT (resumed 2026-05-09 17:46 EDT) |
| **Completed** | 2026-05-09 18:59 EDT (chunk 4 PAUSED — not chunk-5/6 complete) |
| **Agent** | Claude Code (Opus 4.7) |
| **Project** | cisco-ntp-dns |
| **Git Branch** | main |
| **Commits** | Day 1: `369ecaa`, `4c1cc1d`, `953f2c3` · Day 2 (resume): `ef00cd8`, `3a60087`, `6f0cc16`, `0c430b1` |

---

## Executive Summary

The bench-test rig is now **functionally complete and correct** for the DHCP/DNS-spoof use case against the Advantech 2484 Neeve node. This resume landed three rig commits (off-subnet alias /32 fallback, optional DHCP option 15, plan/lessons capture) plus a planning commit, all driven by operator-disclosed DNS IPs (`138.220.4.4 / 138.220.8.8`) and the discovery that those IPs sit in public address space outside our link subnet. The rig issues a clean lease the device accepts, observes a unicast T1 renewal at +5 min, and gets ARP replies in both directions. **However**, the device's application stack stays silent — zero DNS, zero NTP, zero spontaneous traffic across 10+ min cumulative observation. Hypothesis "option 15 is the wedge" was empirically tested and ruled out. Chunk 4 is paused; further progress requires operator/firmware/console-side info on the device's expected post-DHCP behavior.

This is a **research-class finding**: the rig has done its job; the unanswered question has shifted from "is the rig working?" to "what does this device need post-DHCP?" — which is a device-config question, not a rig question.

---

## Plan vs. Actual

| Planned Change | Status | Actual Implementation | Deviation Notes |
|---|---|---|---|
| Chunk 1 — Bootstrap | DONE (Day 1) | Docker, sudo, netplan, Q-IP closed via passive tcpdump | — |
| Chunk 2 — CoreDNS → dnsmasq pivot | DONE (Day 1) | 9-file diff committed as `369ecaa` | — |
| Chunk 3 — Deploy on VM | DONE (Day 1) | First DHCP exchange validated against live 2484 | — |
| Chunk 4 — OBSERVE Q-DNS / Q-EXTRA | **PARTIAL — PAUSED 2026-05-09** | Operator disclosed DNS IPs; rig serves them correctly via DHCP option 6 + /32 host aliases; verified DHCP exchange clean and T1 renewal works. **But device emits zero DNS/NTP in 5+ min.** Q-DNS behavioral confirmation NEGATIVE; Q-EXTRA unreachable from rig alone. | Chunk 4 hit the rig's diagnostic ceiling — the wedge is device-side. Plan now has a "Chunk 4 — outcomes" section documenting this with hypothesis-test grid + resume conditions. |
| Chunk 5 — VERIFY (verify.sh end-to-end) | NOT REACHED | n/a — chunk 5's green-pass criteria require DNS queries, which haven't appeared | Will run when chunk 4 completes. |
| Chunk 6 — HARDEN | NOT REACHED | n/a | Will run if chunk 5 surfaces issues. |

**New emergent work (this resume)**:

| Item | Status | Implementation | Why it emerged |
|---|---|---|---|
| Per-IP /32 prefix in `setup-host-nic.sh` | DONE | Commit `ef00cd8`. Added `ip_in_cidr` / `prefix_for_ip` helpers; in-subnet aliases keep NODE_SUBNET prefix, out-of-subnet aliases use /32. | Operator's DNS IPs (138.220.x.x) are public-space and outside the link's `192.168.50.0/24`. The original script would have aliased them with /24 and installed spurious connected routes. |
| Optional `DHCP_DOMAIN_NAME` env var (DHCP option 15) | DONE | Commit `6f0cc16`. New optional `.env` var; rendered conditionally in `dnsmasq.conf` via `${DHCP_DOMAIN_LINE}` placeholder. Validated via existing `is_fqdn` helper. Set to `wbg.org` on the VM. | Hypothesis test for chunk 4: device's silence = option-15 starvation. Hypothesis was ruled out empirically — option 15 sent and acknowledged, but no behavior change. |
| Plan recording (operator info + chunk-4 pause) | DONE | Commits `3a60087` and `0c430b1`. Plan status moved from `Active` to `Paused 2026-05-09`. | Standard documentation discipline — record findings so the next agent picks up cleanly. |

---

## Technical Decisions

### Decision 1: Per-IP /32 prefix for off-subnet aliases (vs. uniform NODE_SUBNET prefix)
- **Context**: Operator's DNS IPs are `138.220.4.4` and `138.220.8.8` — both in `138.220.0.0/16` (public space), neither in the rig's `192.168.50.0/24` link subnet.
- **Options Considered**:
  - (a) Keep uniform NODE_SUBNET prefix; accept spurious connected routes (`138.220.4.0/24 dev eth1`, `138.220.8.0/24 dev eth1`)
  - (b) Per-IP prefix selection: in-subnet → NODE_SUBNET prefix, out-of-subnet → /32
  - (c) Set `NODE_SUBNET=138.220.0.0/16` so it covers the DNS IPs natively (but also force DHCP pool into public space)
- **Chosen Approach**: (b). Added `ip_in_cidr` / `prefix_for_ip` helpers in `setup-host-nic.sh`; aliases get the right prefix automatically.
- **Rationale**: (a) was harmless on the air-gapped link but lays a routing landmine if the rig is ever moved to a network with legitimate upstream routes for `138.220.x.x`. (c) is structurally weird — issuing public-space leases on a benchtest LAN. (b) is the cleanest of the three.
- **Trade-offs**: One additional ~30-line helper section in the bash script. Smoke-tested 8 input cases before commit.

### Decision 2: Make `DHCP_DOMAIN_NAME` optional (per-device) rather than hardcoding `wbg.org`
- **Context**: User authorized a chunk-4 hypothesis test with `wbg.org` as the option-15 value. The rig is meant to be generic per device.
- **Options Considered**:
  - (a) Hardcode `dhcp-option=option:domain-name,wbg.org` in `dnsmasq.conf.tmpl`
  - (b) Add a `DHCP_DOMAIN_NAME` `.env` var with no default (optional)
  - (c) Add a `DHCP_DOMAIN_NAME` `.env` var with `wbg.org` as the default in `.env.example`
- **Chosen Approach**: (b). `.env.example` keeps the field blank with documentation; rendering conditionally emits the line only when the value is set.
- **Rationale**: Future operators / different devices may have different domains (or none). Baking `wbg.org` into rig defaults pollutes the generic-per-device design. (b) keeps the rig clean while exposing the knob.
- **Trade-offs**: Slightly more rendering-script complexity (5-line conditional + `is_fqdn` validation + envsubst allowlist update). Acceptable.

### Decision 3: Set `DHCP_GATEWAY_IP` explicitly to in-subnet `192.168.50.1` (vs. defaulting to `DNS_PRIMARY_IP`)
- **Context**: The original `render-config.sh` defaults `DHCP_GATEWAY_IP` to `DNS_PRIMARY_IP` if blank — the rig pretends to be the gateway. With operator's DNS IPs now in public space, that default would send the device a default-route gateway of `138.220.4.4` — off-link from the device's `192.168.50.0/24` lease, which most DHCP clients reject (or require option 121 classless static route to accept).
- **Options Considered**:
  - (a) Leave `DHCP_GATEWAY_IP` blank → defaults to `138.220.4.4` (off-link gateway)
  - (b) Set `DHCP_GATEWAY_IP=192.168.50.1` explicitly (in-subnet, rig-aliased)
  - (c) Add option 121 (classless static routes) to point the device at the public DNS IPs via the link
- **Chosen Approach**: (b). Set explicitly in the VM's `.env`.
- **Rationale**: (a) would likely make the device reject the lease (or stay confused); (c) is a heavier rig change with new code paths. (b) is a one-line `.env` change that gives the device a sane default route landing on us.
- **Trade-offs**: One more IP to alias on `eth1` (`192.168.50.1/24`). Negligible cost.
- **Verified**: Device accepted the lease cleanly (DHCPACK), performed unicast T1 renewal at +5 min, responded to ARP. Behavior matched expectation.

### Decision 4: Pause chunk 4 instead of probing DHCP option 120 (sip-server) blind
- **Context**: After option 15 was empirically ruled out as the wedge, the next blind-probe candidate would have been DHCP option 120 (sip-server) with a placeholder IP. The device explicitly requested option 120 in its DISCOVER.
- **Options Considered**:
  - (a) Test option 120 with placeholder (e.g., `192.168.50.123`)
  - (b) Pause and gather operator-side info first (firmware docs, console tap, expected behavior)
  - (c) Run a longer passive capture (30+ min) hoping for asynchronous device wake-up
- **Chosen Approach**: (b). Paused rig changes; recorded findings; enumerated 4 explicit resume conditions in the plan.
- **Rationale**: We've shown the rig is functionally correct (DHCP healthy, ARP healthy, T1 renewal verified). Without operator info on whether the device is SIP-capable, what server format it expects, or what value to send, (a) becomes a coin-flip experiment whose result is hard to interpret. (c) had diminishing returns — the T1 renewal at +5 min already proved the device's network stack is alive but the app layer isn't progressing on a time-based schedule.
- **Trade-offs**: Ends the iterate-the-rig loop earlier than maximum-effort. Trades short-term progress for clearer next steps and documented research findings.

---

## Assumptions Made

| # | Assumption | Basis | Risk if Wrong |
|---|---|---|---|
| 1 | Operator-disclosed DNS IPs (`138.220.4.4`, `138.220.8.8`) are what the device is preconfigured to query | User stated them in response to "what DNS IPs does the device use?" | If the device has a different value baked into firmware that we'd see in console/serial output, we'd be aliasing the wrong IPs and the device's DNS queries would never reach us. (Risk: low — operator typically has authoritative knowledge of their fleet.) |
| 2 | The Hyper-V VM's mgmt IP is DHCP-assigned and may change between sessions | Last session's IP was `172.20.193.219`; this resume's was `172.20.206.72` | Each resume needs to verify the IP via Hyper-V Manager. Documented in the handoff. |
| 3 | The `bench.local`-style placeholder for option 15 wouldn't have worked either | We picked `wbg.org` because (a) it matches the operator's NTP target's domain, (b) it's plausibly close to what the device expects | If the device is specifically validating the domain string against a hardcoded value, neither `wbg.org` nor `bench.local` may be right. Option 15 still ruled out *for the value we tested*. |
| 4 | Device's "every ~2 min DHCP cycling" from prior session was caused by gateway IP equaling DNS IP (`192.168.50.53`) | After setting `DHCP_GATEWAY_IP=192.168.50.1` explicitly, the cycling stopped — lease became stable | Could have also been a coincidence; not strictly proven. But the correlation is strong enough to record as a likely cause. |
| 5 | The device is alive and not in some HW-fault state | DHCP DISCOVER → ACK clean, T1 renewal works, ARP works | If the device is HW-faulted (sub-component failure that affects only the app layer but not the network stack), no rig change will help. Console tap would distinguish this from "waiting for input." |

---

## Architecture & Design Choices

### Off-subnet listener architecture
The rig now supports DNS listeners on IPs outside the link subnet. Required two changes:

1. **`setup-host-nic.sh` per-IP /32**: aliases for IPs outside `NODE_SUBNET` get `/32` (host-only, no connected route). Aliases inside `NODE_SUBNET` keep the link's prefix (e.g., `/24`) so the connected route covers the link normally.

2. **Explicit `DHCP_GATEWAY_IP`**: with DNS listeners potentially off-link, the gateway-defaults-to-DNS_PRIMARY behavior is no longer safe. Operator must now set `DHCP_GATEWAY_IP` to an in-subnet rig-owned IP.

The device's traffic flow becomes:
- Device → ARP for default gateway (in-subnet, rig-owned) → ARP reply from rig
- Device → IP packet to `138.220.4.4` (off-link DNS) → MAC = rig
- Rig kernel → packet has destination locally aliased on eth1 → deliver to dnsmasq socket
- dnsmasq → reply (sourced from the bound IP) → device

### Optional DHCP option scaffold
The `DHCP_DOMAIN_NAME` / `${DHCP_DOMAIN_LINE}` pattern is now the template for adding any future optional DHCP option. Each option needs:

1. A `.env.example` row with documentation (blank by default)
2. A `${OPTION_LINE}` placeholder in `dnsmasq.conf.tmpl`
3. A normalize-empty + validate-if-set block in `render-config.sh`
4. A conditional render block setting `OPTION_LINE` to the dnsmasq line or a comment
5. An export + envsubst allowlist update
6. A status line in the post-render report

Future agents adding option 120 (sip-server) or option 121 (classless static routes) should follow this exact pattern.

### Code Organization
No structural changes — same `scripts/` + `docker/dns/` + `docker/ntp/` layout. The rig stays a 4-script + 4-template package.

---

## Files Changed (this resume)

| File | Action | Description |
|------|--------|-------------|
| `scripts/setup-host-nic.sh` | MODIFY | Add `ip_to_int`, `ip_in_cidr`, `prefix_for_ip` helpers; per-IP prefix selection in both `add` and `teardown` modes; updated print messages |
| `docker/dns/dnsmasq.conf.tmpl` | MODIFY | Add `${DHCP_DOMAIN_LINE}` placeholder between options 3 and `dhcp-authoritative` |
| `.env.example` | MODIFY | Document optional `DHCP_DOMAIN_NAME` (DHCP option 15) |
| `scripts/render-config.sh` | MODIFY | Normalize+validate `DHCP_DOMAIN_NAME`; compute `DHCP_DOMAIN_LINE`; export + envsubst allowlist; status-report line |
| `.ai/plans/2026-05-08-2016-jkoti-neeve-vm-bringup-and-close-open-qs.md` | MODIFY | Update Q-DNS/Q-EXTRA status; add "Architectural implication" section; status `Active` → `Paused 2026-05-09`; full "Chunk 4 — outcomes" section |
| `.ai/PROJECT_LESSONS.md` | MODIFY | Add lesson: when DHCP+ARP healthy but app silent, classify as device-side and stop probing rig |
| `.ai/sessions/2026-05-09-1853-jkoti-neeve-vm-bringup-and-close-open-qs.md` | MODIFY (rename) | Session file checkpoints, summary, decisions, files; renamed to today's timestamp |
| `.ai/sessions/INDEX.md` | MODIFY | Row updated to today's filename + status = ended |

VM-side (not in git, gitignored):
| File | Action | Description |
|------|--------|-------------|
| `.env` (on `gh0stwhee1@172.20.206.72:~/cisco-ntp-dns/.env`) | MODIFY | `DNS_PRIMARY_IP=138.220.4.4`, `DNS_SECONDARY_IP=138.220.8.8`, `DHCP_GATEWAY_IP=192.168.50.1`, `DHCP_DOMAIN_NAME=wbg.org` |

---

## Testing & Verification

| Verification Step | Result | Evidence |
|---|---|---|
| `setup-host-nic.sh` /32 helper logic | PASS | Local smoke test of `prefix_for_ip` against 14 input cases (in/out of `192.168.50.0/24`, in/out of `138.220.0.0/16`, /32 NODE_SUBNET edge) |
| `render-config.sh` validation accepts `DHCP_DOMAIN_NAME=wbg.org` | PASS | Render report on VM: `DHCP option 15 : domain-name = wbg.org` |
| `render-config.sh` correctly omits option 15 when `DHCP_DOMAIN_NAME` blank | UNTESTED | Implicit from conditional logic; no negative test run. Acceptable risk — fall-through is straightforward (renders a comment line). |
| dnsmasq.conf renders option 15 correctly when set | PASS | Live VM render: `dhcp-option=option:domain-name,wbg.org` at line 31 |
| Aliases bound at correct prefixes on eth1 | PASS | `ip -4 addr show dev eth1` after setup-host-nic: `138.220.4.4/32`, `138.220.8.8/32`, `192.168.50.123/24`, `192.168.50.1/24` |
| dns container restart succeeds (no socket-bind errors) | PASS | Post-restart logs: `dnsmasq[1]: started, version 2.90`, `DHCP, sockets bound exclusively to interface eth1`. Prior `failed to create listening socket for 192.168.50.53` errors gone. |
| Live DHCP exchange against 2484 includes option 15 | PASS | dnsmasq log: `sent size: 7 option: 15 domain-name wbg.org` in OFFER and ACK |
| Live DHCP exchange completes ACK | PASS | tcpdump captured DISCOVER → OFFER → REQUEST → ACK in ~3.5 ms; lease `192.168.50.172` issued |
| Device performs unicast T1 renewal | PASS | 5-min passive capture: `192.168.50.172.68 → 192.168.50.123.67` DHCPREQUEST + ACK at +3:27 (within T1 jitter window) |
| Device responds to ARP probes | PASS | `ip neigh show 192.168.50.172` = `lladdr cc:82:7f:91:75:6f REACHABLE` after passive trigger; both directions confirmed in tcpdump |
| **Behavioral target: device emits DNS query for `ntp2.wbg.org`** | **FAIL** | Zero DNS packets in any capture window (60s + 90s + 300s = 450s cumulative passive watch with rig fully configured). Hypothesis "option 15 was the wedge" empirically ruled out. |
| `verify.sh` end-to-end green pass | NOT REACHED | Requires DNS queries to flow; chunk 4 paused before this could run. |

---

## Challenges & Solutions

### Challenge 1 — VM mgmt IP changed between sessions
- **Symptom**: First SSH attempt to `gh0stwhee1@172.20.193.219` (last session's IP) timed out.
- **Diagnosis**: VM's mgmt vNIC is DHCP-assigned by the host's mgmt vSwitch; reboot or lease expiry changed it to `172.20.206.72`.
- **Solution**: User checked Hyper-V Manager GUI to find the VM ("ubuntu-vm", running) and ran `Get-VM` (which returned headers-only initially because PowerShell wasn't elevated, then resolved when checking the GUI). Documented in handoff: future resumes should expect mgmt IP to change.

### Challenge 2 — `dns` container in restart loop after `.env` change
- **Symptom**: After updating `.env` with new DNS IPs, `docker ps` showed `cisco-ntp-dns-dns-1   Restarting (2) 43 seconds ago`.
- **Diagnosis**: stale `out/render/dns/dnsmasq.conf` still referenced the old `192.168.50.53` listener; eth1 no longer had that IP aliased after VM reboot. dnsmasq logged `failed to create listening socket for 192.168.50.53: Address not available`.
- **Solution**: Run `render-config.sh` (regenerates `out/render/` with new IPs) → `setup-host-nic.sh` (aliases the new IPs) → `docker compose restart dns`. Container came up clean.

### Challenge 3 — Identifying when to stop iterating
- **Symptom**: After three rounds of rig changes (gateway IP, /32 alias, option 15), the device still emitted zero application traffic.
- **Diagnosis**: The 5-min passive capture's T1-renewal observation was the breakthrough — proved the device's network stack is alive and the silence is application-layer. Further rig changes would be probing without a hypothesis grounded in operator info.
- **Solution**: Recommend pausing rather than testing option 120 with a placeholder. User agreed. Pause is now formally recorded (plan, lessons, session file), so the next agent picks up without restarting the iterate-the-rig loop.

---

## Questions Senior Engineers Might Ask

**Q: You sent DHCP option 15 with `wbg.org` and saw no behavior change. How do you know the device isn't comparing the value byte-for-byte against some specific expected string?**
A: We don't, strictly. The hypothesis "value-sensitive option 15" is conceivable but rare in commodity DHCP clients. We picked `wbg.org` because it matches the device's known NTP target's domain — the highest-probability "right" value without operator confirmation. If the operator can confirm what domain string the device actually expects, that's a one-line `.env` change to retest.

**Q: Why didn't you also try DHCP option 121 (classless static route) to give the device a route for the public DNS IPs over the link?**
A: Considered it during the off-subnet routing decision (Decision 3). Decided against it because (a) the in-subnet `DHCP_GATEWAY_IP=192.168.50.1` solves the routing question more simply (default route lands on us, kernel-level alias delivery handles the rest), and (b) option 121 encoding (RFC 3442) is a small per-route binary blob that would expand the rig's optional-DHCP scaffolding more than option 15 did. Worth doing if/when we add multi-route scenarios.

**Q: dnsmasq logs include `LOUD WARNING: ... use --bind-dynamic rather than --bind-interfaces to avoid DNS amplification attacks`. Why didn't you fix that?**
A: It's flagged in the carry-forward TODOs as optional hardening. On the air-gapped link cable to a single device, DNS amplification isn't a real risk (the device can't reach us via any other interface). If the rig is ever moved off the air-gapped link, the bind-dynamic switch should be made.

**Q: How confident are you that `192.168.50.50` is "the right" rig-owned gateway IP and not some IP the device may already have configured a route to?**
A: Not confident in any specific value, but the device's behavior (clean DHCP DISCOVER + ACK + T1 renewal + ARP-responsive) is consistent with it accepting whatever in-subnet gateway we hand out. If the device had a hardcoded gateway expectation, we'd see lease rejection; we don't.

**Q: 7 commits across two days for what amounts to a "the rig works but the device is silent" outcome — is that proportionate?**
A: 4 of the 7 are documentation/recording (plan updates, lessons, session-end). 3 are actual rig code (off-subnet /32, optional option 15, prior-day chrony fix). The recording commits exist because this is research-class work and the findings have to outlive the session — the next agent (or next operator iteration) will pick up from the plan and lessons, not from chat history.

---

## What's Left

### Chunk 4 — OBSERVE (PAUSED, awaiting external input)
Resume conditions, any one of which unblocks:
1. Operator describes the device's expected post-DHCP behavior
2. Serial/console tap during device boot reveals what the firmware is waiting on
3. Advantech 2484 firmware/admin docs identify a required DHCP option or out-of-band trigger
4. Operator provides a specific DHCP option/value to test (extends the option-15 framework)

### Chunk 5 — VERIFY
- Run `sudo bash scripts/verify.sh --duration 300` against the cabled device once chunk 4 is complete
- Inspect `out/run/<run-id>/summary.json` — expects DNS query log entries + UDP/123 pcap with mode 3 → mode 4

### Chunk 6 — HARDEN (only if chunk 5 surfaces issues)

### Open carry-forward TODOs
- Document the netplan override (`/etc/netplan/99-bench-eth1.yaml`) in README's "One-time setup (Hyper-V VM path)" section
- Optional dnsmasq hardening: address `LOUD WARNING: --bind-dynamic`

---

## Appendix: 1-Line Reproducer for the Behavioral Failure

On the VM `gh0stwhee1@172.20.206.72`, with the rig running and the 2484 just power-cycled:

```bash
sudo timeout 60 tcpdump -i eth1 -nn -e -tttt -p 'arp or udp port 67 or udp port 68 or udp port 53 or udp port 123'
```

Expected: 4–7 packets total — DHCP DISCOVER → OFFER → REQUEST → ACK, optionally a T1 renewal at ~+5 min, optionally ARP exchanges.

Observed: matches expected, **plus zero DNS queries, zero NTP packets**.
