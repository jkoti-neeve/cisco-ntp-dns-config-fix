# cisco-ntp-dns

Bench-test rig that simulates the **NTP** and **DNS** servers a single
preconfigured device expects to talk to. Connect the device to a Linux
host over a direct Cat6 cable; run two Docker containers (CoreDNS +
chrony) that respond on the IPs the device's preconfig points at; verify
the device's NTP/DNS client is healthy.

> **Naming note**: the directory is `cisco-ntp-dns` for historical reasons.
> No Cisco hardware is involved — the first device under test is a Neeve
> node (Advantech 2484). The rig is generic.

---

## TL;DR

```bash
# On the Linux host (Hyper-V VM, Pi, dedicated box — see "One-time setup"):
cp .env.example .env && $EDITOR .env       # set DNS IPs, NTP target, NIC name
bash   scripts/render-config.sh            # validate + render runtime configs
sudo bash scripts/setup-host-nic.sh        # bind alias IPs on the cabled NIC
docker compose up -d                       # bring up DNS + NTP

# Then plug the device in and observe:
docker compose logs -f dns                 # DNS queries the device makes
sudo tcpdump -i "$HOST_NIC_NAME" -n udp port 123  # NTP exchange

# Teardown:
docker compose down
sudo bash scripts/setup-host-nic.sh --teardown
```

---

## What this is

A small Docker stack of two services:

| Service | Image | Listens on | Purpose |
|---|---|---|---|
| `dns` | `coredns/coredns:1.11.3` | UDP/53 at `DNS_PRIMARY_IP` (and `DNS_SECONDARY_IP` if set) | Captures every DNS query the device makes; answers the seed records (notably the NTP target's A-record) and NXDOMAIN's the rest. Edit the seed file at runtime to add records as the device reveals what it asks for. |
| `ntp` | `alpine:3.20` + chrony | UDP/123 at `NTP_BIND_IP` | Authoritative NTP server at a stable local stratum (5) with no upstream peers. Allows only `NODE_SUBNET`. No authentication. |

Per-device values (1–2 DNS IPs, NTP target, NIC name, subnet) live in
`.env`. The rig is generic — pointing at a different device is an `.env`
edit.

---

## Status

| | |
|---|---|
| Implemented | `.env` schema + `render-config.sh` (validates, renders Corefile/zone/chrony.conf), `docker-compose.yml`, `docker/ntp/Dockerfile`, `scripts/setup-host-nic.sh`, this README |
| Not yet implemented | `scripts/verify.sh` — automated pass/fail (currently you observe manually with `docker logs` + `tcpdump`). Tracked as plan chunk 7. |
| Open device-side facts | `Q-IP` (static or DHCP? expected node IP/subnet?), `Q-DNS` (the actual primary + backup DNS IPs), `Q-EXTRA` (other names the node may query). The rig accepts these as `.env` inputs at cable-up — no source edits. |

See `.ai/plans/2026-05-08-1322-jkoti-neeve-scope-cisco-ntp-dns-planning.md`
for the full plan, configuration matrix (4 cases), and open questions.

---

## Why a Linux host (not Windows directly)

The rig must bind UDP/53 and UDP/123. On Windows, both ports are owned
by wildcard (`0.0.0.0`) listeners that catch traffic to every local IP:

- **`SharedAccess`** (Internet Connection Sharing / Hyper-V Default Switch
  DNS proxy) on UDP/53
- **`W32Time`** on UDP/123

A Docker Desktop container can't publish UDP/53 to any Windows IP — alias
or otherwise — without first stopping these services, which would break
Hyper-V VM networking and Windows time sync. WSL2 mirrored networking
would have sidestepped this but is **Windows 11 only**.

The rig therefore runs **inside a Linux host of your choice**:

- A small **Hyper-V Linux VM** with the cabled NIC bridged into a Hyper-V
  **external switch** (recommended on this dev box)
- A **dedicated Linux box** wired directly to the device (Pi 4, NUC, spare
  laptop)
- (If you upgrade to Windows 11) WSL2 with `[wsl2] networkingMode=mirrored`

Inside that Linux host, containers use `network_mode: host` and bind
directly on the cabled NIC — no proxying, no relay.

---

## One-time setup (Hyper-V VM path)

> Skip this section if you're using a dedicated Linux box. Just install
> Docker + git on it and clone this repo.

### Hardware

- Windows 10/11 Pro, Enterprise, or Education with Hyper-V enabled
- A spare physical NIC dedicated to the device-under-test cable. On this
  dev box that's `Ethernet 2` (Intel I211 GbE) or `Ethernet 3` (Realtek
  USB GbE). **Don't use the NIC that carries your normal internet** —
  the external switch will dedicate that NIC to the VM.

### 1 — Create the Hyper-V external switch

Open **Hyper-V Manager** → **Virtual Switch Manager** → **External** → **Create Virtual Switch**.

- **Name**: `bench-external` (any name; the VM references it later)
- **External network**: pick the NIC you cabled to the device
- **Allow management operating system to share this network adapter**:
  **uncheck** — the cabled NIC becomes VM-only, no Windows sharing

Click OK. Windows networking on that NIC is now off — that's expected.

PowerShell equivalent (admin):

```powershell
New-VMSwitch -Name "bench-external" -NetAdapterName "Ethernet 2" -AllowManagementOS:$false
```

### 2 — Provision an Ubuntu Server VM

Recommended: **Ubuntu Server 24.04 LTS** (or 22.04 LTS). Generation 2 VM,
2 vCPU, 1 GB RAM, 20 GB disk.

- **NIC 1**: Default Switch — for internet during setup (so `apt install`
  works)
- **NIC 2**: `bench-external` — the dedicated cabled-NIC switch

Boot from the Ubuntu Server ISO and install. During install, give it a
hostname (e.g. `ntp-dns-bench`) and enable OpenSSH. After install, log in.

### 3 — Inside the VM: install Docker + tools

```bash
# Update + base tools
sudo apt update && sudo apt install -y ca-certificates curl gettext-base git iproute2 tcpdump

# Docker (official convenience script)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
# Log out + back in (or `newgrp docker`) for the group change to take effect.
```

Verify Docker:

```bash
docker run --rm hello-world
```

### 4 — Inside the VM: clone the repo

```bash
git clone https://github.com/jkoti-neeve/cisco-ntp-dns-config-fix.git ~/cisco-ntp-dns
cd ~/cisco-ntp-dns
```

### 5 — Identify the cabled NIC's name inside the VM

```bash
ip -4 addr show
ip link show
```

Note which interface corresponds to NIC 2 (the `bench-external` switch).
On Ubuntu it's commonly `eth1` or `enp0s4` (depends on systemd's
predictable-naming scheme). You'll put this in `.env` as `HOST_NIC_NAME`.

---

## Per-test operation

### 1 — Configure `.env` for the device

```bash
cd ~/cisco-ntp-dns
cp .env.example .env
$EDITOR .env
```

Set:

| Var | Value |
|---|---|
| `DNS_PRIMARY_IP` | The primary DNS IP the device's preconfig points at |
| `DNS_SECONDARY_IP` | The backup DNS IP, if the device has one (leave blank otherwise) |
| `NTP_TARGET` | The NTP target — FQDN (e.g. `ntp2.wbg.org`) **or** IP literal |
| `NTP_BIND_IP` | The IP the chrony container binds. If `NTP_TARGET` is a FQDN, our DNS hands out this IP. If `NTP_TARGET` is an IP literal, set this to the same value. |
| `HOST_NIC_NAME` | The Linux interface name of the cabled NIC (from step 5 above) |
| `NODE_SUBNET` | CIDR of the subnet the device lives on, e.g. `10.0.0.0/24` |

### 2 — Render the runtime configs

```bash
bash scripts/render-config.sh
```

Validates the `.env` and writes:

```
out/render/
├── dns/
│   ├── Corefile
│   └── zones/seed.hosts
├── ntp/
│   └── chrony.conf
└── host/
    ├── aliases.txt        # IPs setup-host-nic.sh will add
    └── bindings.txt       # human-readable record of services + ports
```

Re-run any time `.env` changes.

### 3 — Bind alias IPs on the cabled NIC

```bash
sudo bash scripts/setup-host-nic.sh
```

This adds the DNS primary, optional secondary, and `NTP_BIND_IP` as
aliases on `HOST_NIC_NAME`, all using `NODE_SUBNET`'s prefix length.
Idempotent.

Verify with `ip -4 addr show dev "$HOST_NIC_NAME"`.

### 4 — Bring up the rig

```bash
docker compose up -d
docker compose ps
```

Both `dns` and `ntp` should be `running`. If the `ntp` build fails,
check that the VM has internet (NIC 1 = Default Switch).

### 5 — Plug the cable + power on the device

The device sees its preconfigured DNS/NTP IPs respond on the link.

### 6 — Observe (manual, until verify.sh lands)

In one terminal — DNS query log:

```bash
docker compose logs -f dns
```

In a second terminal — NTP packet capture:

```bash
sudo tcpdump -i "$HOST_NIC_NAME" -n udp port 123
```

Pass criteria (black-box, since we have no shell on the device — Q-DIAG):

- DNS log shows the device querying `${NTP_TARGET}` (when FQDN) and our
  server returning an A-record for `${NTP_BIND_IP}`
- tcpdump shows NTP **mode 3** (client request) → **mode 4** (server
  response) at `${NTP_BIND_IP}`
- The device continues polling at chrony's standard back-off (initial
  fast burst → ~32 s → ~64 s → ~128 s) — proof the device accepted our
  responses. A device that *didn't* trust us either stops polling or
  stays at the minimum interval forever.

### 7 — Teardown

```bash
docker compose down
sudo bash scripts/setup-host-nic.sh --teardown
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `docker compose up` complains about port 53 already in use | The VM has `systemd-resolved` listening on `127.0.0.53:53` (Ubuntu default) AND your `DNS_PRIMARY_IP` happens to also be `127.0.0.53` | Don't use `127.0.0.53` for the rig. If you must, disable `systemd-resolved` (`sudo systemctl disable --now systemd-resolved`) and replace `/etc/resolv.conf`. |
| `docker compose up` complains about port 123 already in use | The VM has `chrony` or `ntpd` running natively | `sudo systemctl disable --now chrony` (or `ntp`). The rig's chrony runs in the container, not on the host. |
| `setup-host-nic.sh` says "NIC '...' not found" | `HOST_NIC_NAME` in `.env` doesn't match the actual interface name | Run `ip link show` and copy the exact name |
| DNS log shows no queries from the device | The device probably isn't reaching us. Possible causes: cable not connected; alias IPs aren't on the right NIC; `NODE_SUBNET` doesn't include the device's IP | `ip addr show dev $HOST_NIC_NAME` to confirm aliases. `tcpdump -i $HOST_NIC_NAME -n` to see if any traffic arrives at all. |
| DNS log shows queries answered but NTP shows no exchange | The DNS A-record isn't pointing where the device expects, or the device's chrony is rejecting our responses | Check `out/render/dns/zones/seed.hosts` has `${NTP_BIND_IP} ${NTP_TARGET}`. Check chrony logs: `docker compose logs ntp`. Stratum mismatches and time skew can cause client rejection. |
| Device queries names we don't have records for | Capture-then-respond: that's by design. Look at the DNS log, decide which names should resolve, and append `<IP> <name>` lines to `out/render/dns/zones/seed.hosts`. CoreDNS reloads the file automatically. |

---

## Architecture

```
┌─────────────────┐  Cat6 direct      ┌──────────────────────┐
│ Device under    │ ◄──────────────► │ Hyper-V external     │ ─── (NIC 2 in VM)
│ test            │                   │ switch (bench-external)
│ (e.g. Neeve     │                   └──────────┬───────────┘
│  Advantech 2484)│                              │
│                 │                  ┌───────────▼────────────┐
│ preconfigured:  │                  │ Linux VM (Ubuntu 24.04)│
│ - DNS pri/bak   │                  │  HOST_NIC_NAME with    │
│ - NTP target    │                  │  alias IPs (DNS_*, NTP)│
└─────────────────┘                  │                        │
                                     │  Docker:               │
                                     │   - CoreDNS host-mode  │
                                     │   - chrony  host-mode  │
                                     └────────────────────────┘
                                                 ▲
                                                 │ NIC 1 (Default Switch)
                                                 │ Internet for `apt`/Docker pulls;
                                                 │ also useful for SSH'ing in
                                            (Windows host)
```

---

## File map

```
.env.example                          # operator-edited template
.env                                  # (gitignored) operator's filled config
scripts/
├── render-config.sh                  # validate .env + render runtime configs
└── setup-host-nic.sh                 # bind alias IPs on the cabled NIC
docker/
├── dns/
│   ├── Corefile.tmpl                 # CoreDNS template
│   └── zones/seed.hosts.tmpl         # DNS records template
└── ntp/
    ├── Dockerfile                    # Alpine + chrony
    └── chrony.conf.tmpl              # chrony template
docker-compose.yml                    # the stack — both services in host mode
out/render/                           # (gitignored) runtime-rendered configs
.ai/                                  # planning + sessions (mostly gitignored)
```

---

## What's coming

- **`scripts/verify.sh`** (chunk 7) — automated pass/fail script that captures DNS log + NTP pcap, runs the trust-progression check, and prints a green/red summary. Until then, observe manually as in step 6 above.
- **DHCP service** — only if `Q-IP` closes as DHCP. Will live behind a `--profile dhcp` compose flag.
