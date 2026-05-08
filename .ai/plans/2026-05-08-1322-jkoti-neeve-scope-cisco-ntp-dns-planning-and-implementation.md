# Plan: simulate-ntp-dns-for-neeve-node-bench-test

| Field | Value |
|-------|-------|
| **Owner** | jkoti-neeve |
| **Created** | 2026-05-08 13:22 EDT |
| **Last revised** | 2026-05-08 13:35 EDT — full rewrite after scoping intake |
| **Status** | Scoping (no implementation yet) |

> **Note on naming**: The project directory is `cisco-ntp-dns` but no Cisco
> hardware is involved. The actual target is a single **Neeve node**. The
> directory name can be left as-is or renamed in a separate housekeeping pass.

---

## Context

### What this is

A bench-test rig that **simulates the NTP and DNS servers** a single
preconfigured **Neeve node (Advantech 2484)** expects to talk to, so we can
verify the node's NTP/DNS client behavior end-to-end on a closed link.

### Physical setup

```
┌────────────────────┐  Cat6 direct cable   ┌──────────────────────┐
│ Neeve node         │ ◄══════════════════► │ Windows 10 dev PC    │
│ (Advantech 2484)   │                      │ + WSL2 + Docker      │
│                    │                      │   ├─ DNS container   │
│ preconfigured:     │                      │   └─ NTP container   │
│ - DNS pri IP       │                      │                      │
│ - DNS bak IP       │                      │ NIC bound with the   │
│ - NTP: ntp2.wbg.org│                      │ DNS pri/bak/NTP IPs  │
└────────────────────┘                      └──────────────────────┘
```

### Known facts

| Item | Value |
|------|------|
| Node hardware | Advantech 2484 (single device) |
| Node OS | TBD — open question Q-OS below |
| Link | Direct Cat6, NIC-to-NIC, no switch / no router |
| DNS primary IP (node-side expectation) | TBD — supply / extract from node config |
| DNS backup IP (node-side expectation) | TBD — supply / extract from node config |
| NTP target (node-side expectation) | `ntp2.wbg.org` (FQDN — node resolves it via DNS first) |
| Server-side host OS | Windows 10 (this dev PC) |
| Server-side runtime | WSL2 + Docker Desktop, Linux container(s) |
| DNS strategy | Capture-then-respond — start permissive, log all queries, iteratively fill records |

### Critical chain

The node will perform this sequence:

1. Bring up its NIC on the direct link (probably static IP, possibly DHCP — see Q-IP)
2. Issue DNS query for `ntp2.wbg.org` to its **DNS primary** (then **DNS backup** if primary doesn't answer)
3. Receive an A record from our DNS server pointing at our NTP container's IP
4. Send NTP traffic (UDP/123) to that IP
5. Sync clock

For the test to pass, **every step in that chain must work**. The plan
addresses each step explicitly.

---

## Discovery

### Open questions to close before implementation starts

| ID | Question | Why it matters |
|----|----------|----------------|
| **Q-IP** | Does the node use static IP or DHCP on this NIC? What's the expected IP and subnet mask? | If DHCP, the test rig needs a DHCP responder too (or we statically configure the host NIC to match). Affects whether we add a 3rd container / dnsmasq DHCP service. |
| **Q-DNS** | What are the exact DNS primary + backup IPs the node is preconfigured with? | We must bind these IPs as aliases on the Windows NIC (or assign to the WSL2 vEth) so the node's queries actually reach our DNS server. |
| **Q-OS** | What OS / firmware does the Neeve node run? (Linux distro? Buildroot? Yocto? Custom?) | Determines what diagnostic tools are available on the node side (nslookup vs dig vs busybox; chronyc vs ntpq) and what the NTP client is. |
| **Q-NTP-RT** | Is the node's NTP target really `ntp2.wbg.org` (World Bank Group's NTP), or is that an internal alias used in the preconfig? | If it's the real public hostname, we must intercept it at our DNS so the node never reaches the real internet (it can't anyway on a direct cable, but worth confirming). |
| **Q-EXTRA** | Beyond `ntp2.wbg.org`, will the node query any other names? (telemetry endpoints, update servers, time-sync helpers like `pool.ntp.org`?) | The capture-then-respond DNS approach handles unknowns — but knowing up front lets us seed records and shorten iteration loops. |
| **Q-AUTH** | Does the node require authenticated NTP (symmetric key / NTS)? | chrony supports both; configuration changes if yes. Most embedded gateways don't. |
| **Q-DIAG** | Can we get a shell on the node, or only observe externally? | If shell access exists, verification is `nslookup`, `chronyc tracking`, etc. If not, we rely entirely on packet capture from the test PC side. |

### Existing implementations / patterns to leverage

- **CoreDNS** — Go DNS server with a `log` plugin, `hosts` plugin, and `file`
  (zone file) plugin. Excellent for capture-then-respond: log every query in
  one tail-able stream, edit a Corefile to add records, reload.
- **chrony** — modern NTP daemon. Tiny `chrony.conf` to act as an
  authoritative server with arbitrary stratum, no upstream peers required.
- **dnsmasq** — alternative if we also need DHCP (Q-IP); single binary
  serves DHCP + DNS, simpler than CoreDNS+ISC-DHCP for a one-device test.
- **Windows IP aliasing**: `New-NetIPAddress` (PowerShell) to add multiple
  static IPs on the Cat6 NIC.
- **WSL2 networking**: WSL2 has its own vSwitch — direct binding of a
  physical NIC into WSL2 is non-trivial. The pragmatic pattern is: bind the
  IPs on the Windows NIC, run the servers on Windows-mapped ports, and
  `iptables`/`netsh` forward into the container. Validate this in the first
  implementation session as the "spike" task.

---

## Architecture (proposed)

### Components

1. **DNS container** — CoreDNS (or dnsmasq if we collapse with DHCP)
   - Listens on UDP/53 (and TCP/53 for any TCP fallback)
   - Bound to two IPs (the DNS primary + backup the node expects)
   - Logs every query to stdout (volume-mounted so we capture across restarts)
   - Serves an editable zone / hosts file with at minimum: `ntp2.wbg.org → <NTP container IP>`

2. **NTP container** — chrony
   - Listens on UDP/123
   - Bound to the IP the DNS server hands out for `ntp2.wbg.org`
   - Configured to serve time from local clock as a stable stratum (e.g., stratum 5) — no upstream peers (we're isolated)
   - Allows the node's IP / subnet

3. **(Optional) DHCP container** — only if Q-IP says the node DHCPs

4. **Test runner** (host side, PowerShell or bash-in-WSL2)
   - Sets up NIC IP aliases
   - Brings the stack up (`docker compose up`)
   - Tails DNS query log + NTP packet capture
   - Reports pass/fail (domain resolution succeeded? clock-sync packets observed?)

### Networking decision (committed): WSL2 + Docker Desktop

- Containers run inside WSL2; Windows NIC is configured with the necessary IP aliases.
- Open question for the spike: whether `docker compose` with a `macvlan` or
  `host` network plugin can directly attach to the Windows-side NIC. Likely
  approach: Windows NIC has the alias IPs; netsh/PowerShell port-forwards
  UDP 53 and 123 from the alias IPs to the WSL2 container's listening port.

---

## Changes (anticipated chunks, ordered)

### 1. **[ADD]** `docker/dns/Corefile` + `docker/dns/zones/`

CoreDNS config with `log` plugin enabled, a hosts/zone file containing the
seed records (initially just `ntp2.wbg.org → <NTP container IP placeholder>`).

### 2. **[ADD]** `docker/ntp/chrony.conf`

chrony as authoritative NTP server, no upstream pool, fixed stratum, allows
the test subnet.

### 3. **[ADD]** `docker-compose.yml`

Brings up DNS + NTP services; defines the user-defined Docker network with
the NTP container's static IP that the DNS record points at.

### 4. **[ADD]** `scripts/setup-host-nic.ps1`

PowerShell script that adds the DNS primary, DNS backup, and (if needed)
NTP IP as aliases on the Windows NIC connected to the Neeve node. Removes
them on teardown.

### 5. **[ADD]** `scripts/forward-to-wsl.ps1`

`netsh interface portproxy` rules to forward UDP/53 and UDP/123 from the
Windows alias IPs into the WSL2-hosted container. (Or, if a cleaner
direct-binding path is found during the spike, replace with that.)

### 6. **[ADD]** `scripts/verify.ps1` (or `verify.sh` in WSL2)

Runs the test:

- Captures DNS query log for N seconds
- Captures NTP packets via `tshark` / `tcpdump`
- Asserts: at least one DNS query for `ntp2.wbg.org` was answered; at least one NTP request → response pair was observed; (optional) node clock has synced (requires shell access — Q-DIAG)
- Prints a green/red summary

### 7. **[ADD]** `README.md`

Operator runbook: cable layout, host NIC setup, `docker compose up`, run
verify, teardown. Include the IP-binding requirements as a checklist.

### 8. **[ADD]** `.gitignore` (+ `git init`)

Repo isn't yet a git repo — initialize before first commit. `.gitignore`
should cover `*.pcap`, captured DNS query logs, container volumes.

---

## Files

| File | Action | Description |
|------|--------|-------------|
| `docker/dns/Corefile` | ADD | CoreDNS config with `log` + `hosts`/`file` plugins |
| `docker/dns/zones/seed.hosts` | ADD | Editable seed records, starting with `ntp2.wbg.org` |
| `docker/ntp/chrony.conf` | ADD | Authoritative NTP, fixed stratum, no upstream |
| `docker-compose.yml` | ADD | Two-service compose (DNS + NTP) on a static-IP user network |
| `scripts/setup-host-nic.ps1` | ADD | Adds Windows NIC IP aliases for DNS pri/bak/NTP |
| `scripts/forward-to-wsl.ps1` | ADD | `netsh portproxy` UDP/53 + UDP/123 → WSL2 container |
| `scripts/verify.ps1` | ADD | End-to-end pass/fail script |
| `README.md` | ADD | Operator runbook |
| `.gitignore` | MODIFY | Already exists for the framework; extend for `*.pcap`, captured logs, container volumes |

---

## Verification

A successful session ends with:

1. ✅ `docker compose up` brings DNS + NTP healthy
2. ✅ NIC alias setup script binds the expected DNS pri/bak/NTP IPs on the cabled NIC and is reversible
3. ✅ With the Neeve node cabled and powered on, the DNS query log shows the node querying `ntp2.wbg.org` (and any other names — feeds capture-then-respond)
4. ✅ tshark/tcpdump shows NTP request from node → response from container, mode 4 (server)
5. ✅ Node-side observation (Q-DIAG-dependent) confirms clock has synced
6. ✅ `verify.ps1` prints a green summary

---

## Decisions (this session)

- **2026-05-08** — *Project scope is a 1-device bench-test rig, not a multi-device Cisco config-fix tool.* The directory name `cisco-ntp-dns` is misleading; left as-is for now (rename = separate housekeeping task).
- **2026-05-08** — *Server delivery: dockerized Linux containers on WSL2 + Docker Desktop on Windows 10.* Picked over a Hyper-V Linux VM bridge for speed of setup; networking spike will validate the WSL2 + portproxy path before committing in the implementation session.
- **2026-05-08** — *DNS strategy: capture-then-respond.* Start with one seeded record (`ntp2.wbg.org`) and CoreDNS query logging; iteratively add records as the node reveals what it queries.
- **2026-05-08** — *NTP target is `ntp2.wbg.org` (FQDN).* Confirmed by user. Our DNS will short-circuit it to a container-local IP — the node never reaches the real public NTP server.
- **2026-05-08** — *Tech stack: CoreDNS for DNS, chrony for NTP* — both for query-log clarity and modern config ergonomics. Open to reconsidering if Q-IP forces dnsmasq-with-DHCP into the picture.

## Decisions (deferred to first implementation session)

- Whether to add a DHCP service (depends on Q-IP)
- Whether to keep CoreDNS or switch to dnsmasq (depends on Q-IP)
- Exact NIC alias IPs and subnet (depends on Q-DNS)
- Whether NTP authentication is needed (depends on Q-AUTH)
