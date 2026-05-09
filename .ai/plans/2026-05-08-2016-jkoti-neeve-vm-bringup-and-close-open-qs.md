# Plan: vm-bringup-and-close-open-qs

| Field | Value |
|-------|-------|
| **Owner** | jkoti-neeve |
| **Created** | 2026-05-08 20:16 EDT |
| **Status** | Paused 2026-05-09 — chunk 4 reached the rig's limit; blocker is device-side, requires operator/firmware info |

---

## Context

The bench-test rig (Neeve-node NTP/DNS simulator) is **implementation-complete** on `main`. All scripts, templates, `docker-compose.yml`, and `verify.sh` were shipped across chunks 1, 4, 5, 7, 8 + the Linux-host spike pivot. This plan covers the **next phase**: stand the rig up on real hardware and close the three remaining open scoping questions by observing actual Neeve-node behavior over the cable.

**Pre-conditions held at session start**:
- Hyper-V Ubuntu VM is deployed on the dev box.
- Cabled NIC bridged to the VM via a Hyper-V external switch (per the spike pivot to Linux-host architecture).
- User has SSH key access to the VM (ubuntu user) from this Windows host.
- Neeve node (Advantech 2484) is preconfigured with its DNS pri/bak IPs and `ntp2.wbg.org` as the NTP target — *exact values are part of what we're discovering this session*.

**Out of scope this session**: rebuilding the rig itself. Fix-as-needed only — anything bigger forks into its own plan.

---

## Open Qs to close (carried from the scoping plan)

| ID | Question | Status |
|----|----------|--------|
| **Q-IP** | Static IP or DHCP? expected IP / subnet? | **CLOSED 2026-05-08 20:35 EDT — DHCP**. Passive 15s tcpdump on eth1 captured `BOOTP/DHCP, Request from cc:82:7f:91:75:6f` (Advantech OUI) — node broadcasts DHCP DISCOVER on its WAN port. No static IP. Subnet is whatever the rig's DHCP server hands out (the rig picks). |
| **Q-DNS** | Exact DNS primary + backup IPs the node is preconfigured with? | **CLOSED 2026-05-09 (operator-side disclosure)** — `DNS_PRIMARY_IP=138.220.4.4`, `DNS_SECONDARY_IP=138.220.8.8`. Both are public-space IPs (138.220.0.0/16), out of the link subnet `192.168.50.0/24` — see "Architectural implication" below. **Behavioral confirmation: NEGATIVE so far** — device has not queried DNS at all in 5+ min of post-DHCP-ACK observation across multiple captures; see "Chunk 4 — outcomes" below. |
| **Q-EXTRA** | Other DNS names the node queries beyond `ntp2.wbg.org`? | **OPEN — UNREACHABLE FROM RIG ALONE.** Device hasn't reached the DNS-using stage of init in any observation window; cannot enumerate names it would query if its app stack were progressing. Closing this requires either operator-side info on what the device is waiting for post-DHCP, or a serial/console tap during boot. |

### Architectural implication (Q-DNS public-space resolution)

The disclosed DNS IPs (`138.220.4.4`, `138.220.8.8`) are NOT inside the link subnet `192.168.50.0/24`. The rig still works, but the routing has an extra hop:

1. Device boots, DHCP lease arrives in `192.168.50.0/24` (e.g., `192.168.50.172`).
2. Device wants to query `138.220.4.4` → not on-link → routes via DHCP-supplied default gateway.
3. Default gateway must be a rig-owned IP **in-subnet** (e.g., `192.168.50.1`), so the device can ARP-resolve it on eth1.
4. Rig kernel receives the packet on eth1, sees `138.220.4.4` is locally configured (aliased), delivers to dnsmasq.

This means `DHCP_GATEWAY_IP` MUST be set explicitly to an in-subnet IP — it can no longer default to `DNS_PRIMARY_IP` (the prior assumption broke when DNS IPs went out-of-subnet).

`setup-host-nic.sh` uses ONE prefix for all aliases (taken from `NODE_SUBNET`, currently `/24`). Aliasing `138.220.4.4/24` on eth1 installs a spurious connected route `138.220.4.0/24 dev eth1`. This is harmless on the air-gapped cable to the device, but will need a follow-up if the rig is ever deployed somewhere with an upstream that legitimately routes 138.220.x.x. **Carry-forward TODO**: optionally modify `setup-host-nic.sh` to use `/32` for aliases that fall outside `NODE_SUBNET`.

---

## Discovery

### Existing rig (from prior sessions)

- `scripts/render-config.sh` — reads `.env`, materializes Corefile / zone / chrony.conf
- `scripts/setup-host-nic.sh` — adds IP aliases on the host NIC (Linux); idempotent; `--teardown` reverses
- `scripts/verify.sh` — runs the test for N seconds, captures DNS log + UDP/123 pcap, emits `summary.json`
- `docker-compose.yml` — DNS + NTP services with `network_mode: host`
- `docker/dns/Corefile.tmpl`, `docker/dns/zones/seed.hosts.tmpl`, `docker/ntp/chrony.conf.tmpl`
- `README.md` — operator runbook (7-step quick start, post-spike Linux-host version)
- `.env.example` — config schema

### Reusable for bring-up

- All of the above. The rig is supposed to "just work" if the `.env` values are correct.

### What we don't yet know

- Is the cabled NIC inside the VM up and named what we think (`eth0` vs `ens33` vs `enp0s3` etc.)?
- Does the operator's SSH connection traverse the same NIC as the cabled link, or a separate management vNIC? (If same, we have to be careful not to disrupt our own session.)
- Is Docker installed in the VM image already?

These are answered in chunk 1 below.

---

## Changes (anticipated chunks, ordered)

### 1. **[BOOTSTRAP]** Get the rig running on the VM — *DONE 2026-05-08*
- ✅ SSH in to gh0stwhee1@172.20.193.219 (eth0 = mgmt vNIC)
- ✅ Install Docker engine + compose-v2 (Docker 29.1.3, Compose 2.40.3 via Ubuntu native packages)
- ✅ Confirm eth1 = cabled vNIC to 2484 WAN port (separate from mgmt)
- ✅ Set up passwordless sudo for SSH automation
- ✅ Passive tcpdump on eth1 — closed Q-IP

### 2. **[PIVOT]** CoreDNS → dnsmasq — *IN PROGRESS 2026-05-08*
- Q-IP=DHCP means the rig needs a DHCP server. Decision: replace CoreDNS with dnsmasq (single container serves DNS + DHCP). Approved by user 2026-05-08.
- Files: `docker/dns/Dockerfile` (NEW), `docker/dns/dnsmasq.conf.tmpl` (NEW, replaces `Corefile.tmpl`), `docker-compose.yml` (rebuild dns service), `.env.example` (+DHCP_* vars), `scripts/render-config.sh` (+dnsmasq rendering), `scripts/verify.sh` (+dnsmasq log format / DHCP assertion), `README.md` (status + arch).
- Single commit on main with the diff and a reference to this plan.

### 3. **[DEPLOY]** Bring the rig up against the 2484
- Clone repo on VM, write `.env` with `192.168.50.0/24` (or operator-chosen) link subnet
- Render configs, setup-host-nic, `docker compose up -d`
- Verify dnsmasq starts and binds the IPs we asked for
- Cable up + power on the 2484 (already powered — just observe)

### 4. **[OBSERVE]** Close Q-DNS and Q-EXTRA
- Watch `docker compose logs -f dns` for DHCP DISCOVER → OFFER → REQUEST → ACK exchange
- Watch DNS queries that follow the lease. Two outcomes:
  - Node uses DHCP-supplied DNS → queries hit our `DNS_PRIMARY_IP` → we see `ntp2.wbg.org` lookup, possibly other names (Q-EXTRA)
  - Node uses preconfigured DNS IPs → queries go to some other IP → that IP IS the Q-DNS answer; iterate `.env` to alias it on eth1 and re-deploy
- Update this plan with observed values

### 4. **[OBSERVE]** — outcomes (2026-05-09)

**Rig-side fixes applied this session** (committed to `main`):
- `fix(setup-host-nic)`: per-IP /32 prefix for aliases outside `NODE_SUBNET` (so 138.220.4.4/32 and 138.220.8.8/32 don't install spurious connected routes). Commit `ef00cd8`.
- `feat(dhcp): DHCP_DOMAIN_NAME`: optional env var → DHCP option 15 (domain-name). Set to `wbg.org` on the VM. Commit `6f0cc16`.
- `.env` on VM updated: `DNS_PRIMARY_IP=138.220.4.4`, `DNS_SECONDARY_IP=138.220.8.8`, `DHCP_GATEWAY_IP=192.168.50.1`, `DHCP_DOMAIN_NAME=wbg.org`.

**Captures observed** (multiple windows, ~10 min cumulative wall time post-power-cycle):
- DHCP exchange: clean. DISCOVER → OFFER → REQUEST → ACK in ~3.5 ms. Lease `192.168.50.172` issued to client hostname `nodeos`, MAC `cc:82:7f:91:75:6f`.
- T1 renewal: confirmed at +5 min (unicast DHCPREQUEST `192.168.50.172.68 → 192.168.50.123.67` → DHCPACK). Device's DHCP state machine is fully alive.
- ARP: device responds to ARP probes from the rig in both directions; rig's gateway alias (`192.168.50.1`) is reachable from the device's perspective.
- L2: link counters increment as expected; no errors, no drops attributable to the rig.

**Application-layer behavior**:
- **Zero DNS queries** observed across all captures (incl. 5-min passive watch).
- **Zero NTP packets** observed.
- **Zero spontaneous traffic** beyond DHCP renewal + ARP responses.

**Hypotheses tested and ruled out**:

| Hypothesis | Test | Result |
|---|---|---|
| Gateway IP defaulting to `DNS_PRIMARY_IP=192.168.50.53` was confusing the device's stack | Set `DHCP_GATEWAY_IP=192.168.50.1` explicitly (in-subnet) | Device behavior changed: prior session's "every 2 min" DHCP cycling stopped, lease became stable. But still no app traffic. |
| Off-subnet DNS IPs needed proper routing | `setup-host-nic.sh` /32 fix; aliased 138.220.4.4 and 138.220.8.8 on eth1 | Rig listens correctly on the public IPs. Doesn't unblock the device because the device never queries. |
| Device requested but never received DHCP option 15 (domain-name); some embedded stacks gate boot init on it | `DHCP_DOMAIN_NAME=wbg.org` → option 15 in OFFER+ACK | Device receives option 15 (per dnsmasq log: `sent size: 7 option: 15 domain-name wbg.org`). No behavioral change post-ACK. **Ruled out as wedge.** |

**Hypotheses still open (untested)**:

| Hypothesis | Why we paused instead of testing |
|---|---|
| Option 120 (sip-server) — device requested it; we don't send it | Without operator info on whether the device is SIP-capable and what server IP/format it expects, we'd be sending a placeholder. Diminishing returns. |
| Device requires inbound trigger from a registration / cloud / config server | Can't simulate without knowing what server, what protocol, what payload. |
| Device firmware in a "factory pre-commission" mode that emits nothing until provisioned through a separate channel | Requires operator/Advantech docs. |

**Conclusion**: The rig is **functionally complete and correct** for the DHCP/DNS/NTP-spoof use case. It correctly issues a lease the device accepts and renews, hands out the operator's DNS IPs as option 6, optionally sends option 15, and is listening on UDP/53 + UDP/123 + UDP/67 on the cabled link. **The blocker is device-side**: the Advantech 2484's application stack is silent post-DHCP for reasons the rig cannot diagnose. Further rig-side experiments (option 120, longer windows) have low expected information value without operator-side input on the device's expected boot-init behavior.

**Resume conditions**: any one of the following unblocks chunk 4:
- Operator describes the device's expected post-DHCP behavior (what server it should call, what protocol, what data)
- Serial/console tap during device boot reveals what the firmware is waiting on
- Advantech 2484 firmware/admin docs identify a required DHCP option or out-of-band trigger
- A specific DHCP option/value the operator wants tested (we'd add it as another optional env var)

### 5. **[VERIFY]** Run verify.sh end-to-end
- `sudo bash scripts/verify.sh --duration 300` (5 min) with the node cabled and powered
- Inspect `out/run/<run-id>/summary.json` and logs
- If FAIL: chunk 6

### 6. **[HARDEN]** Fix rig issues uncovered
- Script bugs / missing edge cases / runbook gaps surface here
- Fix-and-commit per fix; update README only if the *procedure* changed
- If lessons are learned, append to `.ai/PROJECT_LESSONS.md`

---

## Files

| File | Action | Description |
|------|--------|-------------|
| `.env` | CREATE on VM (gitignored) | Real DNS pri/bak IPs, NTP_BIND_IP, HOST_NIC_NAME, NODE_SUBNET — observed in chunk 2 |
| `docker/dns/zones/seed.hosts.tmpl` | MODIFY (if Q-EXTRA reveals new names) | Add A records as the node queries them |
| `scripts/*.sh` | MODIFY (only if bugs found) | Fixes from bring-up |
| `README.md` | MODIFY (only if procedure changed) | Operator-runbook updates |
| `.ai/PROJECT_LESSONS.md` | APPEND | Any project-level lessons from this bring-up |
| `.ai/plans/2026-05-08-2016-jkoti-neeve-vm-bringup-and-close-open-qs.md` | UPDATE in-place | Record observed answers to Q-IP / Q-DNS / Q-EXTRA |

---

## Verification

A successful end-of-session looks like:

1. ✅ `verify.sh` prints a green summary against the real Neeve node
2. ✅ DNS query log shows the node querying `ntp2.wbg.org` and receiving the rigged A record from at least the primary
3. ✅ UDP/123 pcap shows mode 3 → mode 4 with stratum < 16, sane ref-id, non-zero transmit timestamp
4. ✅ Trust-progression check: poll interval ramps 32 → 64 → 128 s
5. ✅ Q-IP, Q-DNS, Q-EXTRA each have a recorded answer in this plan
6. ✅ Any rig fixes committed to `main`
7. ✅ Session checkpointed at chunk boundaries (1 → 2 → 3 → 4 → 5)

Falling short of green by chunk 4 is acceptable IF the failure is documented and the next-step is recorded — the bench rig is research-class, not production.
