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
| Node hardware | Advantech 2484 (single device — first target; rig is generic) |
| Node OS | Custom Neeve Linux (Yocto/Buildroot-class) |
| Link | Direct Cat6, NIC-to-NIC, no switch / no router |
| DNS server count (rig supports) | **1 or 2** — primary required, secondary optional |
| DNS server IPs (per-test) | **Configurable** via `.env` (`DNS_PRIMARY_IP`, `DNS_SECONDARY_IP`) |
| NTP target form (rig supports) | **FQDN or IP literal** — exactly one |
| NTP target (per-test) | **Configurable** via `.env` (`NTP_TARGET`); default for the first device under test = `ntp2.wbg.org` |
| NTP listen IP (per-test) | **Configurable** via `.env` (`NTP_BIND_IP`) — what the chrony container binds. If `NTP_TARGET` is a FQDN, our DNS short-circuits it to this IP. If `NTP_TARGET` is an IP literal, set `NTP_BIND_IP = NTP_TARGET`. |
| Server-side host OS | Windows 10 (this dev PC) |
| Server-side runtime | WSL2 + Docker Desktop, Linux container(s) |
| DNS strategy | Capture-then-respond — start permissive, log all queries, iteratively fill records |

### Critical chain

The node will perform this sequence (parameterized by `.env`):

1. Bring up its NIC on the direct link (static or DHCP — see Q-IP)
2. Issue DNS query for `${NTP_TARGET}` (when it's a FQDN) to its **DNS primary** (`${DNS_PRIMARY_IP}`); falls back to **DNS secondary** (`${DNS_SECONDARY_IP}`) if set
3. Receive an A record from our DNS server pointing at `${NTP_BIND_IP}`
4. Send NTP traffic (UDP/123) to `${NTP_BIND_IP}`
5. Sync clock

> **NTP-as-IP path**: when `NTP_TARGET` is an IP literal, step 2 is skipped entirely (the node never asks DNS about the NTP target). DNS still serves any other queries the node makes; NTP container still binds at `NTP_BIND_IP = NTP_TARGET`.

For the test to pass, **every step in that chain must work**. The plan
addresses each step explicitly.

---

## Discovery

### Open questions

#### Closed during scoping (2026-05-08)

| ID | Answer | Impact on plan |
|----|--------|----------------|
| **Q-OS** | Custom Neeve Linux build (Yocto/Buildroot/similar). | Server side unchanged. Expect busybox-level userland on the node — diagnostic tools may be minimal, but we don't depend on them anyway (see Q-DIAG). NTP client is likely chrony or systemd-timesyncd; doesn't matter for our side. |
| **Q-NTP-RT** | Literal string is `ntp2.wbg.org`. | Confirmed. DNS seed record stays exactly as planned: `ntp2.wbg.org. IN A <NTP container IP>`. |
| **Q-AUTH** | No auth — plain NTP. | chrony.conf stays minimal: no `keyfile`, no NTS cert provisioning, no `auth select`. |
| **Q-DIAG** | Black-box — no shell, no admin API access for verification. | **Big implication.** All pass/fail signal comes from our side: DNS query log + tcpdump on UDP/53 and UDP/123. We can never directly assert "the node's clock is now correct" — we infer it from a clean NTP protocol exchange (mode 3 request → mode 4 response) AND continued polling at chrony's standard intervals (32s → 64s → 128s — the client only ramps up if it trusts the server). See updated Verification section. |

#### Still open — gate first implementation session

| ID | Question | Why it matters |
|----|----------|----------------|
| **Q-IP** | Does the node use static IP or DHCP on this NIC? What's the expected IP and subnet mask? | If DHCP, the test rig needs a DHCP responder too (or we statically configure the host NIC to match). Affects whether we add a 3rd container / dnsmasq DHCP service. |
| **Q-DNS** | What are the exact DNS primary + backup IPs the node is preconfigured with? | We must bind these IPs as aliases on the Windows NIC (or assign to the WSL2 vEth) so the node's queries actually reach our DNS server. |
| **Q-EXTRA** | Beyond `ntp2.wbg.org`, will the node query any other names? (telemetry endpoints, update servers, time-sync helpers like `pool.ntp.org`?) | The capture-then-respond DNS approach handles unknowns — but knowing up front lets us seed records and shorten iteration loops. |

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

### Configuration (single source of truth: `.env`)

All per-device values are externalized. The user copies `.env.example` to
`.env`, fills in the values for whichever device they're testing, and runs
the rig — no source edits required.

```env
# === DNS ============================================================
# Primary DNS IP the device under test points at (REQUIRED).
DNS_PRIMARY_IP=10.0.0.53

# Secondary DNS IP, if the device has one configured (OPTIONAL).
# Leave blank to disable the secondary listener.
DNS_SECONDARY_IP=10.0.0.54

# === NTP ============================================================
# What the device tries to reach for NTP — either a FQDN or an IP literal.
NTP_TARGET=ntp2.wbg.org

# IP that our chrony container will bind on. The DNS server short-circuits
# NTP_TARGET (when a FQDN) to this address. If NTP_TARGET is itself an IP,
# set NTP_BIND_IP to the same value.
NTP_BIND_IP=10.0.0.123

# === Host-side =====================================================
# The cabled Windows NIC name (used by the alias-binding script).
HOST_NIC_NAME=Ethernet 4

# Subnet the device under test lives on (used for chrony's allow rule).
NODE_SUBNET=10.0.0.0/24
```

A small helper script (`scripts/render-config.sh`) reads `.env` and:

- Detects whether `NTP_TARGET` is an IP or a FQDN
- Renders the CoreDNS Corefile + zone file (adds the `${NTP_TARGET} IN A ${NTP_BIND_IP}` record only if `NTP_TARGET` is a FQDN)
- Renders chrony.conf with the right bind address and `allow ${NODE_SUBNET}`
- Emits the list of host-NIC alias IPs and portproxy rules consumed by the PowerShell scripts
- Validates the config (e.g., `DNS_PRIMARY_IP` set, `NTP_BIND_IP` set, IP literals are valid dotted-quads, etc.)

### Components

1. **DNS container** — CoreDNS
   - Listens on UDP/53 (and TCP/53 for fallback)
   - Bound to **`DNS_PRIMARY_IP`** (always) and **`DNS_SECONDARY_IP`** (only if set)
   - Logs every query to stdout, volume-mounted to `out/<run-id>/dns.log` for post-mortem
   - Zone records generated from `.env` by `render-config.sh`; capture-then-respond pattern means the operator can edit the zone file mid-run and CoreDNS reloads

2. **NTP container** — chrony
   - Listens on UDP/123 at **`NTP_BIND_IP`**
   - Stable local-clock stratum (default: 5; configurable if a test wants a different stratum)
   - `allow ${NODE_SUBNET}` only — won't answer outside the rig

3. **(Optional) DHCP container** — only if Q-IP closes as DHCP. Add to compose under a `--profile dhcp` flag so it's opt-in.

4. **Test runner** (host side, PowerShell + bash-in-WSL2)
   - Reads `.env`
   - Calls `render-config.sh` to materialize Corefile/zone/chrony.conf
   - Sets up NIC alias IPs (`DNS_PRIMARY_IP`, optionally `DNS_SECONDARY_IP`, optionally `NTP_BIND_IP` if it's not in the WSL2 subnet)
   - Brings the stack up (`docker compose up`)
   - Tails DNS query log + NTP packet capture into `out/<run-id>/`
   - Reports pass/fail per the Verification checklist

### Networking decision (committed): Linux host (Hyper-V VM with cabled NIC bridged)

> **Pivoted 2026-05-08 during the implementation-session spike.** The original
> "WSL2 + Docker Desktop on Windows host" plan was infeasible on Windows 10
> for two compounding reasons (see § "Spike findings"):
>
> 1. `SharedAccess` (ICS) holds a wildcard `0.0.0.0:53` UDP listener (it backs
>    Hyper-V Default Switch's DNS proxy). A wildcard catches port 53 on every
>    local IP — Docker Desktop can't publish a container's UDP/53 to any
>    Windows IP, alias or otherwise, without first stopping ICS (which
>    disrupts Hyper-V VMs and shared-network features).
> 2. `W32Time` holds `0.0.0.0:123` — same wildcard problem for NTP.
> 3. WSL2 mirrored networking (which would have sidestepped the above) is
>    Windows 11 only.

**The rig now runs inside a Linux host of the operator's choice.** Concretely:

- A small **Linux VM in Hyper-V** with a Hyper-V **external switch** bound
  to the cabled NIC (e.g. `Ethernet 2` on this dev box). The VM owns that
  NIC at the link layer; Windows doesn't see it; no host port conflict.
- Inside the VM: `docker compose up` runs the rig. Containers use
  `--network host` (Linux host networking, NOT Docker-Desktop's
  pseudo-host) and bind directly on the cabled NIC at `DNS_PRIMARY_IP`,
  optionally `DNS_SECONDARY_IP`, and `NTP_BIND_IP`.
- IP aliases on the VM's NIC are added by `scripts/setup-host-nic.sh`
  (bash; runs inside the VM).
- **No port forwarding, no relay, no portproxy.** Chunk 6 from the
  original plan is dropped.

**Alternative hosts** (rig is host-agnostic Linux): a dedicated Pi 4 / NUC /
spare laptop wired to the device works identically. The only Windows-specific
piece is the one-time Hyper-V external-switch + VM provisioning, documented
in the README.

### Spike findings (2026-05-08)

| Probe | Result |
|---|---|
| WSL version + mirrored mode | WSL 2.6.3.0 on Win10 Pro 19045 — mirrored mode unavailable (Win11+ only) |
| Docker Desktop UDP forwarding to host alias | Untested directly — pre-empted by host port conflict below |
| `0.0.0.0:53/udp` ownership | PID 4716 = `svchost / SharedAccess` (ICS / Hyper-V Default Switch DNS proxy) |
| `0.0.0.0:123/udp` ownership | PID 18924 = `svchost / W32Time` (Windows Time service) |
| Hyper-V availability | Enabled (`vEthernet (Default Switch)` Up); external switch creation viable |
| Cabled-test NICs available | `Ethernet 2` (Intel I211 GbE) and `Ethernet 3` (Realtek USB GbE) — both currently disconnected |

---

## Changes (anticipated chunks, ordered)

### 1. **[ADD]** `.env.example` + `scripts/render-config.sh`

Externalized config schema (the file shown in **Configuration** above) plus
the renderer that materializes Corefile / zone file / chrony.conf / alias-IP
list / portproxy-rule list from `.env`. Validates inputs (required keys, IP
literal format, FQDN-vs-IP detection on `NTP_TARGET`). All other chunks
read from this rendered output, never from hard-coded values.

### 2. **[ADD]** `docker/dns/Corefile.tmpl` + `docker/dns/zones/seed.hosts.tmpl`

CoreDNS templates consumed by the renderer. Conditional bind for
`DNS_SECONDARY_IP` (only listed if set). The `${NTP_TARGET} IN A
${NTP_BIND_IP}` record is added only when `NTP_TARGET` is a FQDN.
`log` plugin enabled in both branches.

### 3. **[ADD]** `docker/ntp/chrony.conf.tmpl`

chrony template: binds on `${NTP_BIND_IP}`, no upstream pool, fixed local-
clock stratum (default 5), `allow ${NODE_SUBNET}`. No keyfile, no NTS.

### 4. **[ADD]** `docker-compose.yml` *(revised post-spike)*

Brings up DNS + NTP services. Reads `.env` directly. **Both services use
`network_mode: host`** so they bind directly on the Linux host's NIC at
`DNS_PRIMARY_IP` / `DNS_SECONDARY_IP` / `NTP_BIND_IP`. No user-defined
Docker network, no port mapping (host-mode bypasses `ports:` anyway).
DHCP service (if Q-IP requires) goes behind a `--profile dhcp` flag.

### 5. **[ADD]** `scripts/setup-host-nic.sh` *(revised post-spike)*

Bash script (runs **inside the Linux host** — a Hyper-V VM, dedicated Linux
box, etc.) that reads `.env` and adds `DNS_PRIMARY_IP`, optionally
`DNS_SECONDARY_IP`, and `NTP_BIND_IP` as IP aliases on the host's NIC
(`HOST_NIC_NAME` interpreted as a Linux interface name, e.g. `eth0`).
Uses `ip addr add ... dev ${HOST_NIC_NAME}`. Idempotent. Tear-down via
`--teardown`.

### 6. *(DROPPED post-spike)* — port forwarding no longer needed

The original chunk 6 was a `netsh portproxy` script for routing UDP/53
and UDP/123 from Windows alias IPs into a WSL2 container. The Linux-host
architecture binds directly via `--network host`, so no proxy exists.
Skipping this chunk and renumbering 7–9 below.

### 7. **[ADD]** `scripts/verify.ps1` (or `verify.sh` in WSL2)

Runs the test for N seconds, captures into `out/<run-id>/`:

- DNS query log (full, gzipped)
- NTP pcap (UDP/123 only, both directions)
- Renders pass/fail per the Verification checklist (black-box, no node-side access)

Reads `.env` so the assertions match the active config — e.g., asserts a
DNS query for `${NTP_TARGET}` only when it's a FQDN.

### 8. **[ADD]** `README.md`

Operator runbook:

1. Copy `.env.example` to `.env` and fill in the device's expected values
2. Run `scripts/setup-host-nic.ps1` (admin shell)
3. Run `scripts/forward-to-wsl.ps1` (admin shell)
4. `docker compose up -d`
5. Cable up + power on the device
6. Run `scripts/verify.ps1` for ~5 minutes; check the green summary
7. `docker compose down` + `scripts/setup-host-nic.ps1 -Teardown` to clean up

### 9. **[MODIFY]** `.gitignore`

Add: `.env`, `out/`, `*.pcap`, container volume mounts. Keep `.env.example`
tracked.

---

## Files

| File | Action | Description |
|------|--------|-------------|
| `.env.example` | ADD | Template config: 1–2 DNS IPs, 1 NTP target (FQDN or IP), bind IP, NIC name, node subnet |
| `.env` | (gitignored) | Operator-supplied per-device values |
| `scripts/render-config.sh` | ADD | Renders Corefile / zone / chrony.conf / alias list / portproxy list from `.env`; validates inputs |
| `docker/dns/Corefile.tmpl` | ADD | CoreDNS template — conditional secondary bind, conditional NTP A-record |
| `docker/dns/zones/seed.hosts.tmpl` | ADD | Editable seed-record template; renderer fills `${NTP_TARGET} → ${NTP_BIND_IP}` if FQDN |
| `docker/ntp/chrony.conf.tmpl` | ADD | chrony template — binds `${NTP_BIND_IP}`, allows `${NODE_SUBNET}`, no auth, no upstream |
| `docker-compose.yml` | ADD | DNS + NTP services on a user-defined network; DHCP under `--profile dhcp` (opt-in) |
| `scripts/setup-host-nic.ps1` | ADD | Idempotent NIC alias add / remove (`-Teardown`); reads `.env` |
| `scripts/forward-to-wsl.ps1` | ADD | `netsh portproxy` UDP/53 (per DNS IP) + UDP/123 (NTP_BIND_IP) → WSL2; reads `.env` |
| `scripts/verify.ps1` | ADD | End-to-end pass/fail; assertions parameterized by `.env` |
| `README.md` | ADD | Operator runbook (7-step quick start) |
| `.gitignore` | MODIFY | Add `.env`, `out/`, `*.pcap`, container volumes; keep `.env.example` tracked |

---

## Verification (black-box; node-side observation NOT available)

Because Q-DIAG closed as black-box, every pass criterion must be observable
from the test PC side alone. Assertions are **parameterized by `.env`** so
the same harness validates any device.

A successful run ends with:

1. ✅ `docker compose up` brings DNS + NTP healthy
2. ✅ NIC alias setup script bound the expected IPs (`DNS_PRIMARY_IP`, `DNS_SECONDARY_IP` if set, `NTP_BIND_IP` if needed) on `HOST_NIC_NAME`, and `-Teardown` reverses them cleanly
3. ✅ DNS query log shows:
   - **If `NTP_TARGET` is a FQDN**: at least one query for `${NTP_TARGET}`, answered with an A record of `${NTP_BIND_IP}`, served from the **primary** (and from the **secondary** in a separate failover pass that briefly stops the primary listener — only if `DNS_SECONDARY_IP` is set)
   - **If `NTP_TARGET` is an IP literal**: no DNS-for-NTP-target assertion (the node never asks DNS about it). Other queries the node makes are still logged and reviewed.
4. ✅ tshark/tcpdump on UDP/123 at `${NTP_BIND_IP}`: client sends NTP **mode 3** → container replies **mode 4** → response has stratum < 16, ref-id sane, transmit timestamp non-zero
5. ✅ **Trust-progression check**: the node continues polling. Standard chrony/ntp progression is initial fast-burst (4–8 packets in the first ~30 s) then back-off to ~32 s → ~64 s → ~128 s. A client that *didn't* accept our response stops polling or keeps retrying at minimum interval — both are red signals.
6. ✅ Captured during run to `out/<run-id>/`: full DNS query log + UDP/123 pcap + a `summary.json` produced by `verify.ps1`
7. ✅ `verify.ps1` prints a green summary that consolidates 3–6 into one pass/fail line, citing the `.env` values it asserted against

### Configuration matrix (the four shapes the rig must handle)

| Case | `DNS_PRIMARY_IP` | `DNS_SECONDARY_IP` | `NTP_TARGET` | What 3–4 above check |
|------|---|---|---|---|
| A | set | unset | FQDN | DNS pri only; A-record check on `NTP_TARGET` |
| B | set | set | FQDN | DNS pri+bak; A-record check on `NTP_TARGET`; failover pass |
| C | set | unset | IP literal | DNS pri only; **no** A-record check; NTP exchange only |
| D | set | set | IP literal | DNS pri+bak; **no** A-record check; NTP exchange only |

This device under test is **Case B**. Cases A/C/D are not exercised at first cable-up but the rig MUST support them so future devices don't need code changes.

> **Limit of inference**: this confirms the protocol exchange is healthy, *not* that the node's wall clock is correct. The node could in principle accept our packets and still apply a buggy offset internally. That would require node-side access to detect — out of scope for this rig.

---

## Decisions (this session)

- **2026-05-08** — *Project scope is a 1-device bench-test rig, not a multi-device Cisco config-fix tool.* The directory name `cisco-ntp-dns` is misleading; left as-is for now (rename = separate housekeeping task).
- **2026-05-08** — *Server delivery: dockerized Linux containers on WSL2 + Docker Desktop on Windows 10.* Picked over a Hyper-V Linux VM bridge for speed of setup; networking spike will validate the WSL2 + portproxy path before committing in the implementation session.
- **2026-05-08** — *DNS strategy: capture-then-respond.* Start with one seeded record (`ntp2.wbg.org`) and CoreDNS query logging; iteratively add records as the node reveals what it queries.
- **2026-05-08** — *NTP target is `ntp2.wbg.org` (FQDN).* Confirmed by user. Our DNS will short-circuit it to a container-local IP — the node never reaches the real public NTP server.
- **2026-05-08** — *Tech stack: CoreDNS for DNS, chrony for NTP* — both for query-log clarity and modern config ergonomics. Open to reconsidering if Q-IP forces dnsmasq-with-DHCP into the picture.

## Decisions (additional, 2026-05-08 — parameterize the rig)

- **Per-device values are externalized to `.env`.** The rig is generic: `DNS_PRIMARY_IP` (required), `DNS_SECONDARY_IP` (optional), `NTP_TARGET` (FQDN **or** IP literal, exactly one), `NTP_BIND_IP`, `HOST_NIC_NAME`, `NODE_SUBNET`. Source files are templates rendered by `scripts/render-config.sh`. No source edits needed to test a different device.
- **Configuration matrix has 4 cases (A–D)** based on whether the secondary DNS is set and whether `NTP_TARGET` is a FQDN or IP literal. The rig must handle all four; verification assertions are parameterized accordingly. The first device under test is Case B (two DNS, FQDN NTP).

## Decisions (additional, 2026-05-08 — closing 4 of 7 open Qs)

- **Q-OS** = custom Neeve Linux build (Yocto/Buildroot/similar). No change to server design; node-side userland is busybox-class but we don't depend on it (see Q-DIAG).
- **Q-NTP-RT** = literal `ntp2.wbg.org`. DNS seed record stays as planned.
- **Q-AUTH** = no auth — plain NTP. chrony.conf stays minimal.
- **Q-DIAG** = black-box; no shell, no admin API. **Verification is fully test-PC-side**: DNS query log + tcpdump on UDP/53 and UDP/123, including a trust-progression check on chrony's poll back-off (32 s → 64 s → 128 s). The rig cannot directly verify "node clock is correct" — only "the protocol exchange is healthy".

## Decisions (deferred to first implementation session)

- **Q-IP** — node addressing (static vs DHCP, expected IP/subnet). Determines whether we add a DHCP service.
- **Q-DNS** — exact DNS primary + backup IPs. Determines NIC alias IPs.
- **Q-EXTRA** — other names the node might query. Capture-then-respond handles it; knowing up front shortens iteration.
- **CoreDNS vs. dnsmasq** — sticks with CoreDNS unless Q-IP forces DHCP into the picture, in which case dnsmasq's combined DHCP+DNS may be simpler than running CoreDNS + ISC-DHCP separately.
