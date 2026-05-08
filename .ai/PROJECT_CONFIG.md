# Project Configuration

> Project-specific settings for `cisco-ntp-dns`. This file is created by `/framework-init` and freely editable.
> `/sync-configs` merges this file with `.ai/AGENT_GUIDE.md` to produce tool-specific configs (`CLAUDE.md`, `.cursorrules`, etc.).

---

## Project Context

### Overview

**Cisco NTP/DNS Config Fix** — a remediation effort to correct NTP (time
synchronization) and DNS (name resolution) configuration issues across Cisco
network devices.

> **Status: scoping.** Problem space is still being defined. Tech stack, target
> device classes (IOS / IOS-XE / NX-OS / IOS-XR), scope (audit vs. fix vs.
> ongoing config management), and execution model (one-shot script vs.
> automation pipeline) will be decided during initial planning. Use
> `/plan-create` to capture decisions as they are made.

### Tech Stack

| Layer       | Technology                          |
|-------------|-------------------------------------|
| Language    | _TBD — decide during planning_      |
| Device I/O  | _TBD (e.g., Netmiko, NAPALM, Ansible `cisco.ios`, Nornir, raw SSH/Expect)_ |
| Config diff | _TBD_                               |
| Inventory   | _TBD_                               |
| Secrets     | _TBD (vault, env vars, etc.)_       |

### Architecture

```
cisco-ntp-dns/
├── .ai/              AI Dev Framework (plans, sessions, handoffs, context)
├── .claude/          Claude Code settings + project-local skills
├── .agent/           Per-tool agent config
└── (source layout TBD once stack is chosen)
```

### Branding (optional)

Not applicable — this is a network/infrastructure tooling project, not a
user-facing product. Branding tokens are kept at framework defaults; ignore
unless a UI is later added.

---

## Critical Policies

These are **defaults** for a Cisco-touching project. Confirm or revise during
the first planning session.

- **Never push to production devices without an explicit dry-run/diff first.**
  All proposed changes must be reviewable as config diffs before any write.
- **Never commit device credentials, enable secrets, SNMP community strings,
  or TACACS/RADIUS keys.** Use a vault or environment variables; add concrete
  paths to `.gitignore` once the stack is chosen.
- **Read-only by default against real devices.** Mutating operations
  (`configure terminal`, `write memory`, etc.) require explicit user
  authorization per session — no autonomous writes.
- **Preserve operator state.** Never clear counters, reload, or otherwise
  disturb a device beyond the explicit scope of an NTP/DNS change.

---

## Key Files

| Purpose                  | Path                              |
|--------------------------|-----------------------------------|
| Project configuration    | `.ai/PROJECT_CONFIG.md` (this file) |
| Agent guide (merged)     | `.ai/AGENT_GUIDE.md`              |
| Active plans             | `.ai/plans/`                      |
| Session journal          | `.ai/sessions/`                   |
| Project lessons          | `.ai/PROJECT_LESSONS.md`          |
| Roadmap                  | `.ai/ROADMAP.md` _(create with `/roadmap`)_ |
| Architecture context     | `.ai/context/ARCHITECTURE.md`     |

Source-tree key files will be added here once the stack is chosen.

---

## Development

```bash
# TBD — populated once tech stack is chosen.
# First session should run /plan-create to scope the problem and pick a stack.
```

### Environment Variables

To be defined. Likely candidates once stack is chosen:

- Device credentials (username / password / enable / SSH key path)
- Inventory source (file path or NetBox/IPAM URL + token)
- Optional: syslog/NTP server allow-list, DNS server allow-list

---

## Additional Features

- **Scope candidates** to clarify in first plan:
  - Audit-only (read NTP/DNS state, report drift) vs. remediate (push fixes)
  - Single-vendor Cisco vs. multi-platform (IOS / IOS-XE / NX-OS / IOS-XR)
  - One-shot fix vs. ongoing config-as-code
  - Idempotency requirements and rollback strategy
- **Likely deliverables**: device inventory model, golden NTP/DNS config per
  platform, diff/preview tooling, change record / audit log.
