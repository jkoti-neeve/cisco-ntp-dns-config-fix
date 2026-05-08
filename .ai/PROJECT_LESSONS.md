# Project Lessons — cisco-ntp-dns

Lessons learned from corrections and discoveries during work on **this project** (the Neeve-node NTP/DNS bench-test rig). Reviewed by agents at session start alongside framework lessons in `.ai/LESSONS.md`.

**Entry format:**
<!--
### YYYY-MM-DD — Short title
- **What happened**: Describe the mistake or misunderstanding
- **Correction**: What the correct approach is
- **Rule**: One-sentence rule to prevent recurrence
-->

---

### 2026-05-08 — Don't extrapolate scope from the project name; do a small intake first
- **What happened**: Project directory was `cisco-ntp-dns`. On `/framework-init` and again on `/session-start`, I assumed a multi-device Cisco config-fix tool and produced a heavy plan with 18+ scoping questions covering inventory sources, multi-platform fanout, change windows, rollback strategies, and TACACS credentials. The actual scope was a single-device bench-test rig that simulates NTP and DNS for one Neeve gateway over a direct Cat6 cable. The first plan was discarded entirely; the user then wrote out the real scope in plain prose.
- **Correction**: For greenfield projects (no source code yet, user has signaled "still defining the problem"), the FIRST scoping action must be a 3–5 question intake that establishes (1) target system count and topology, (2) what's known vs. unknown, (3) what success looks like. Only after those answers is detailed plan content worth writing.
- **Rule**: For greenfield/scoping sessions, ask a 3–5 question intake before drafting more than a one-paragraph plan stub. Never extrapolate scope from the directory name or PROJECT_CONFIG defaults — confirm with the user.

<!-- LESSON_MARKER — new lessons are inserted above this line -->
