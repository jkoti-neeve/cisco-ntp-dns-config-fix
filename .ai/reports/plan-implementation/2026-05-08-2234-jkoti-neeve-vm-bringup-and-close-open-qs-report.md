# Implementation Report: vm-bringup-and-close-open-qs

| Field | Value |
|-------|-------|
| **Plan** | `.ai/plans/2026-05-08-2016-jkoti-neeve-vm-bringup-and-close-open-qs.md` |
| **Session** | `.ai/sessions/2026-05-08-2228-jkoti-neeve-vm-bringup-and-close-open-qs.md` |
| **Owner** | jkoti-neeve |
| **Started** | 2026-05-08 20:16 EDT |
| **Ended** | 2026-05-08 22:34 EDT (paused at chunk 4 — BLOCKED on operator-side DNS IPs) |
| **Duration** | 2h 18m |
| **Agent** | Claude Code |
| **Project** | `C:\dev\cisco-ntp-dns` |
| **Git Branch** | `main` |
| **Commits** | `369ecaa`, `4c1cc1d`, plus the session-end commit |

---

## Executive Summary

The bench-test rig was deployed to the Hyper-V Ubuntu VM and the first end-to-end DHCP exchange against the live Neeve 2484 was validated (lease `192.168.50.172` issued to client hostname `nodeos`). An architectural pivot from CoreDNS to dnsmasq — driven by the in-session discovery that the device is a DHCP client on its WAN port — was implemented, committed, pushed, and confirmed working. **Q-IP closed; Q-DNS and Q-EXTRA remain open**: the device cycles its DHCP client every ~2 minutes and never reaches the DNS-using stage of init, so observation cannot proceed without the operator's preconfigured DNS IPs.

---

## Plan vs. Actual

| Planned Change | Status | Actual Implementation | Deviation Notes |
|---|---|---|---|
| Chunk 1 — BOOTSTRAP: rig running on the VM | DONE | SSH'd in, installed Docker (apt: docker.io 29.1.3 + docker-compose-v2 2.40.3), set up passwordless sudo, disabled DHCP on eth1 via netplan drop-in, cloned repo at `369ecaa`. | Used Ubuntu native packages over `get.docker.com` script — slightly older Docker but battle-tested on Ubuntu 26.04. |
| Chunk 2 — DISCOVER (passive observation) | FOLDED INTO 1 | A 15s passive tcpdump during chunk 1 caught a `BOOTP/DHCP, Request from cc:82:7f:91:75:6f`, which closed Q-IP=DHCP immediately. | The "discover before configure" pose wasn't needed — the device was already broadcasting on a stable link. |
| (NEW) Chunk 2-bis — PIVOT: CoreDNS → dnsmasq | DONE | 9-file diff: new `docker/dns/Dockerfile` + `dnsmasq.conf.tmpl`; `docker-compose.yml` dns service rebuilt (`cap_add: NET_ADMIN`); `render-config.sh` full rewrite; `verify.sh` dnsmasq-aware + DHCP assertion; `.env.example` `+DHCP_*`; README updated. Committed `369ecaa`, pushed to `main`. | Architectural decision; not in original plan. Surfaced when Q-IP closed as DHCP. User-approved before implementation. |
| Chunk 3 — CONFIGURE: real .env, alias IPs, stack up | DONE | `.env` with `192.168.50.0/24` link, render, `setup-host-nic.sh` aliased `.53` + `.123` on eth1, `docker compose up -d --build`. | First run revealed NTP container crash bug (chrony cap_add); fixed and pushed as `4c1cc1d` (autonomous bug-fix). |
| Chunk 4 — VERIFY/OBSERVE: close Q-DNS / Q-EXTRA | PARTIAL — BLOCKED | Full DHCP exchange validated (DISCOVER→OFFER→REQUEST→ACK; lease `192.168.50.172`, hostname `nodeos`). Zero DNS / NTP traffic. | Cannot continue without preconfigured DNS IPs from operator. |
| Chunk 5 — HARDEN: fix rig issues uncovered | PARTIAL | Fixed chrony cap_add + pidfile race; documented as 3 PROJECT_LESSONS entries. | More hardening expected once Q-DNS unblocks. |

---

## Technical Decisions

### Decision 1: Replace CoreDNS with dnsmasq (not co-existence)
- **Context**: Q-IP closed as DHCP. The original plan noted "Optional DHCP container — only if Q-IP closes as DHCP, with `--profile dhcp` flag". Two paths emerged.
- **Options Considered**:
  - **A** Replace CoreDNS with dnsmasq (single container DNS+DHCP)
  - **B** Add dnsmasq as DHCP-only, keep CoreDNS for DNS
  - **C** Use host's `isc-dhcp-server` natively + keep CoreDNS
- **Chosen Approach**: A
- **Rationale**: dnsmasq's `addn-hosts` accepts the same hosts(5) format we already render; one container instead of two; unified DNS+DHCP log stream is materially better for "capture-then-respond" than tailing two streams.
- **Trade-offs**: Lost CoreDNS's structured query log format — replaced by dnsmasq's `query[A] foo from x` lines. Acceptable for our use case; `verify.sh` was updated to match.

### Decision 2: `cap_add: [SYS_TIME]` on the ntp service (autonomous fix)
- **Context**: First hardware run crash-looped: "`CAP_SYS_TIME not present`" → "`adjtimex(0x8001) failed: Operation not permitted`". The original `docker-compose.yml` comment claimed `manual` mode meant no caps were needed — wrong and untested.
- **Options Considered**: A) `cap_add SYS_TIME`, B) replace `manual` with a more permissive mode, C) skip privdrop init.
- **Chosen Approach**: A
- **Rationale**: Standard chrony-in-docker pattern. Chrony 4.5 calls `adjtimex` during privdrop init regardless of mode. Tested empirically and confirmed working.
- **Trade-offs**: Container has slightly more privilege than strictly necessary. Acceptable for a closed bench rig.

### Decision 3: Disable DHCP on eth1 via netplan drop-in
- **Context**: Default Ubuntu netplan auto-DHCPs every interface. With dnsmasq serving DHCP on eth1, systemd-networkd would also try to DHCP-client eth1 from our pool — racing with `setup-host-nic.sh`'s static aliases.
- **Options Considered**: A) netplan override `dhcp4: false` for eth1 only, B) tell dnsmasq to ignore the VM's MAC, C) leave the conflict.
- **Chosen Approach**: A
- **Rationale**: Single source of truth — `setup-host-nic.sh` fully owns eth1's IP layout. No race conditions.
- **Trade-offs**: Adds `/etc/netplan/99-bench-eth1.yaml` to one-time VM setup. Currently undocumented in README — flagged as follow-up.

### Decision 4: Push `369ecaa` before validating on the VM
- **Context**: Per user-confirmed pattern, pushed the dnsmasq pivot commit to `origin/main` before deploying to the VM.
- **Rationale**: Failures iterate as new commits on top, never as amended pushed commits. Matches the project's per-chunk commit-and-push rhythm.
- **Trade-offs**: A bug pushed to main can affect collaborators (none on this project). The chrony-cap_add bug surfaced post-push; fix landed as `4c1cc1d` on top — clean history.

---

## Assumptions Made

| # | Assumption | Basis | Risk if Wrong |
|---|---|---|---|
| 1 | The 2484 will accept any private subnet for its DHCP lease | DHCP clients pick from offered options; subnet doesn't matter to a client | If device validates against a baked-in subnet, leases would fail. **Held**: device accepted `.172` from our pool. |
| 2 | dnsmasq's default option set is sufficient | Standard DHCP options 1, 3, 6, 12 cover most clients | Device requested options 15 (domain-name) and 120 (sip-server) — not currently supplied. **Possible cause of the 2-min DHCP cycle.** Not yet validated. |
| 3 | The 2484 will reach DNS-using boot stage given a valid lease | Standard embedded init: networking → DNS → NTP → application | **Not held**: device cycles DHCP every ~2 min instead of progressing. Holding hypothesis pending more data. |
| 4 | Q-AUTH's "no NTP auth" close (from scoping) is correct | User's confirmation 2026-05-08 | If device requires NTS or symmetric key, chrony.conf would need updates. Not yet exercised. |

---

## Architecture & Design Choices

### Tech Stack Decisions
- **dnsmasq** (Alpine 3.20) replaces CoreDNS as the DNS+DHCP server. Single binary, single config, unified log.
- **chrony 4.5** retained as NTP server, now with `CAP_SYS_TIME`.
- Both containers continue with `network_mode: host` (Linux-host architecture from the prior spike).

### Code Organization
- `docker/dns/` retains its directory structure: `Dockerfile` + `dnsmasq.conf.tmpl` + `zones/seed.hosts.tmpl`. The `dns` directory name is generic enough that swapping CoreDNS → dnsmasq is invisible to the operator.
- `scripts/render-config.sh` was rewritten rather than incrementally patched — dnsmasq's variable surface (`DNS_LISTEN_LINES`, `DHCP_DNS_SERVERS`, `DHCP_GATEWAY_IP`) differs materially from CoreDNS's, and a clean rewrite reads better than a patch series.

### Data Flow
```
.env  →  render-config.sh  →  out/render/dns/dnsmasq.conf
                              out/render/dns/zones/seed.hosts
                              out/render/host/aliases.txt
                              out/render/ntp/chrony.conf

aliases.txt  →  setup-host-nic.sh  →  ip addr add ... dev eth1

dnsmasq.conf + seed.hosts  →  bind-mounted into dns container  →
  listen on DNS IPs (53/udp), DHCP on eth1 (67/udp), log to stdout

chrony.conf  →  bind-mounted into ntp container  →  bind on NTP_BIND_IP (123/udp)
```

---

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `docker/dns/Dockerfile` | ADD | alpine:3.20 + dnsmasq, mirrors NTP container pattern |
| `docker/dns/dnsmasq.conf.tmpl` | ADD | bind-interfaces + addn-hosts + dhcp-range + option:dns-server + option:router + log-queries + log-dhcp |
| `docker/dns/Corefile.tmpl` | DELETE | CoreDNS no longer used |
| `docker/dns/zones/seed.hosts.tmpl` | MODIFY | Comment refresh (CoreDNS → dnsmasq) |
| `docker/ntp/Dockerfile` | MODIFY | Wrap entrypoint in `sh -c "rm -f /var/run/chrony/chronyd.pid; exec chronyd ..."` |
| `docker-compose.yml` | MODIFY | dns: build local + cap NET_ADMIN; ntp: cap SYS_TIME |
| `.env.example` | MODIFY | +DHCP_RANGE_START/END, DHCP_LEASE_TIME, DHCP_GATEWAY_IP |
| `scripts/render-config.sh` | MODIFY | Full rewrite — dnsmasq.conf rendering + DHCP validation |
| `scripts/verify.sh` | MODIFY | dnsmasq log format + DHCP DISCOVER/ACK assertion |
| `README.md` | MODIFY | Status, file map, arch diagram, troubleshooting all reflect new architecture |
| `.ai/plans/2026-05-08-2016-jkoti-neeve-vm-bringup-and-close-open-qs.md` | ADD | Plan for this session |
| `.ai/PROJECT_LESSONS.md` | MODIFY | +3 lessons (chrony cap_add, ssh-t no TTY, verify earlier-session claims) |

---

## Testing & Verification

| Verification Step | Result | Evidence |
|---|---|---|
| `bash -n` syntax check on all 3 scripts | PASS | "render-config.sh: syntax OK" / "verify.sh: syntax OK" / "setup-host-nic.sh: syntax OK" |
| `render-config.sh` smoke test on synthetic `.env` (Windows local Git Bash) | PASS | Produced valid `dnsmasq.conf` with bind 53/54, dhcp-range 100..200/10m, option 6 = both DNS IPs, option 3 = DNS_PRIMARY_IP (default) |
| Docker install on VM | PASS | `Docker version 29.1.3`, `Docker Compose version 2.40.3` |
| `docker compose up -d --build` (first attempt) | FAIL | ntp container crash-looped: "CAP_SYS_TIME not present" |
| `docker compose up -d --build` (after `4c1cc1d`) | PASS | Both containers Up; chronyd: "Initial frequency 2.317 ppm" |
| `setup-host-nic.sh` on eth1 | PASS | Aliased 192.168.50.53/24 + 192.168.50.123/24 |
| Full DHCP exchange with 2484 | **PASS** | dnsmasq logs show DISCOVER → OFFER → REQUEST → ACK (xid 3342914132); lease `192.168.50.172` issued to client `nodeos` (MAC `cc:82:7f:91:75:6f`); leases file in container confirms |
| DNS query from 2484 | NOT OBSERVED | Zero UDP/53 packets on eth1 in 5+ minutes after lease — device cycles DHCP every ~2 min |
| NTP exchange | NOT OBSERVED | Zero UDP/123 packets — same as DNS |
| `verify.sh` end-to-end run | NOT RUN | Pre-condition (DNS query observed) not met; deferred until Q-DNS closes |

---

## Challenges & Solutions

### Challenge 1: PowerShell + ssh.exe quoting for sudoers setup
- **Problem**: First attempt to write `/etc/sudoers.d/90-gh0stwhee1-nopasswd` failed silently — the sudoers entry never landed.
- **Root Cause**: PowerShell 5.1 mangled the `(ALL)` runas spec when passing through `ssh.exe` — interpreted parens as subexpression syntax inside the double-quoted string.
- **Solution**: Used the parens-free sudoers form `gh0stwhee1 ALL=NOPASSWD: ALL`. Even with that, the `!` shell-out in Claude Code couldn't allocate a TTY for the sudo password prompt — user opened a real PowerShell window outside Claude Code and ran `ssh -t ...` interactively there.
- **Lesson**: Captured as `PROJECT_LESSONS` entry "ssh -t doesn't allocate a TTY when invoked through Claude Code's `!` prefix".

### Challenge 2: NTP container crash-loop on first run
- **Problem**: Within seconds of `docker compose up -d`, the ntp container crash-looped: "CAP_SYS_TIME not present" → "adjtimex(0x8001) failed: Operation not permitted", then on subsequent restarts "Another chronyd may already be running".
- **Root Cause**: Two bugs. (a) chrony 4.5 calls `adjtimex(0x8001)` during privdrop init regardless of `manual` mode — needs `CAP_SYS_TIME`. (b) Crashes leave stale `/var/run/chrony/chronyd.pid` which blocks subsequent starts.
- **Solution**: Added `cap_add: [SYS_TIME]` to docker-compose.yml; wrapped Dockerfile ENTRYPOINT in `sh -c "rm -f /var/run/chrony/chronyd.pid; exec chronyd ..."`. Pushed as `4c1cc1d`.
- **Lesson**: Captured as `PROJECT_LESSONS` entry "Don't claim runtime behavior in code comments without testing it" — the original `# No cap_add — chrony.conf uses 'manual' (no clock discipline), so CAP_SYS_TIME is not needed` comment had been wrong-and-untested for ~5 hours before this session validated it.

### Challenge 3: 2484 cycles DHCP every 2 minutes, never reaches DNS
- **Problem**: Despite a clean DHCP exchange and a valid lease, the device sits idle for ~2 min then re-DHCPs from scratch (DHCPDISCOVER from `0.0.0.0:68`, not unicast renewal). No DNS or NTP queries observed.
- **Root Cause**: Unknown. Hypotheses:
  - (a) missing DHCP options 15 (domain-name) and 120 (sip-server) which the device explicitly requested
  - (b) missing IPv6 router advertisement triggers a 2-min init timeout
  - (c) device firmware-side init issue unrelated to our DHCP response
- **Solution**: Deferred. Session paused pending operator-side info on the device's preconfigured DNS IPs — closing Q-DNS may also reveal what the device is actually waiting on.
- **Lesson**: This is an investigation-in-progress, not a closed problem.

---

## Questions Senior Engineers Might Ask

### Q: Why replace CoreDNS instead of running CoreDNS + isc-dhcp-server side-by-side?
**A**: Three reasons. First, dnsmasq's `addn-hosts` accepts the same hosts(5) format we already use for seed records, so the migration cost is one rewrite, not two integrations. Second, a unified log stream (DNS queries + DHCP transactions in one `docker compose logs dns`) is materially better for "capture-then-respond" iteration than tailing two streams. Third, dnsmasq is one battle-tested binary instead of two — fewer moving parts on a closed bench rig. The downside (less granular DNS query log format) is acceptable for our use case.

### Q: Why pick `192.168.50.0/24` for the link subnet — was that arbitrary?
**A**: Largely arbitrary, with one constraint: it had to be a private subnet not used by either of the VM's existing vNICs (eth0 = 172.20.x.x Hyper-V Default Switch; eth1's stale lease was 192.168.1.x home LAN). 192.168.50/24 satisfies both. The 2484 is a DHCP client, so it accepts whatever subnet the rig hands out — no intrinsic dependency on a specific range. If the operator's preconfigured DNS IPs land in a different range, the rig simply re-renders against a different `NODE_SUBNET`.

### Q: The original docker-compose comment said "no cap_add needed because manual mode" — how did that survive code review and a previous session-end commit?
**A**: It didn't survive a deployment, because there had been no deployment. The chunks 4+5 commit (`0dcc4b6`) was developed offline (no VM existed yet), the implementation report for that session marked the work as "feature-complete pending operator-side VM provisioning and cable-up", and the rig was committed-and-pushed without ever being run end-to-end. This session is the first time the rig was actually deployed. The `PROJECT_LESSONS` entry "Don't claim runtime behavior without testing" is the direct outcome.

### Q: Why didn't you address the device's requested DHCP options 15 and 120 immediately?
**A**: Two reasons. First, the user explicitly chose to pause until they retrieved the preconfigured DNS IPs — fixing options 15/120 in isolation might mask the real Q-DNS answer (we don't yet know if the device uses our DHCP-supplied DNS or some preconfigured IP). Second, supplying option 120 (sip-server) requires picking a valid IP and either standing up a SIP responder or accepting connection failures gracefully — non-trivial for a "quick test." Better to come back with the real Q-DNS data and triangulate.

### Q: Are the `PROJECT_LESSONS` entries committed with this session, or will they get lost?
**A**: They're committed locally as part of the session-end commit (alongside this implementation report). The user will need to push when ready — `/session-end` does not auto-push. The session itself is gitignored, but `PROJECT_LESSONS.md` and `.ai/reports/plan-implementation/` are tracked per the project's `.gitignore` whitelist.

---

## What's Left / Follow-up Items

- [ ] **Q-DNS**: get the device's preconfigured DNS pri/bak IPs from the operator's docs / web UI / spec sheet
- [ ] **Q-EXTRA**: enumerate any other names the device queries (capture-then-respond once DNS traffic flows)
- [ ] **Investigate the 2-min DHCP cycle**: hypotheses include missing option 15 (domain-name), missing option 120 (sip-server), or missing IPv6 RA. May resolve naturally once the device reaches the DNS stage.
- [ ] **Document the netplan override** in `README.md` under "One-time setup (Hyper-V VM path)" — currently `setup-host-nic.sh` instructions silently assume eth1 isn't being DHCP'd by netplan.
- [ ] **Run `verify.sh` end-to-end** once Q-DNS unblocks — confirm the DHCP DISCOVER/ACK assertion + `summary.json` + green pass output.
- [ ] **Optional cheap experiment**: add `dhcp-option=option:domain-name,bench.local` to `dnsmasq.conf` and see whether the 2-min cycle stops. If yes, surface to render-config.sh as `DHCP_DOMAIN` env var.
- [ ] **Push the session-end commit** when ready (this session left it local).

---

## Raw Session Data

<details>
<summary>Git Log (commits during implementation)</summary>

```
4c1cc1d fix(ntp): chrony 4.5 needs CAP_SYS_TIME + clear stale pidfile
369ecaa chunk 2: pivot DNS service from CoreDNS to dnsmasq
```

</details>

<details>
<summary>Files Diff Summary (369ecaa..HEAD)</summary>

```
 .ai/plans/2026-05-08-2016-jkoti-neeve-vm-bringup-and-close-open-qs.md | 175 +++++
 .env.example                                                         |  29 +-
 README.md                                                            |  35 +-
 docker-compose.yml                                                   |  20 +-
 docker/dns/Corefile.tmpl                                             |  16 -
 docker/dns/Dockerfile                                                |  19 +
 docker/dns/dnsmasq.conf.tmpl                                         |  35 ++
 docker/dns/zones/seed.hosts.tmpl                                     |   8 +-
 docker/ntp/Dockerfile                                                |   9 +-
 scripts/render-config.sh                                             | 101 +++--
 scripts/verify.sh                                                    |  37 +-
```

</details>

---

*Report generated by `/session-end` on 2026-05-08 22:34 EDT.*
