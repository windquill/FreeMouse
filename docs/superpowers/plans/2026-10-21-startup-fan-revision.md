# Startup and Fan Revision Plan

**Goal:** Repair delayed SMC control and make existing startup settings editable.

**Spec:** `docs/superpowers/specs/2026-10-21-startup-fan-revision-design.md`

- [x] Fan helper checked-control state machine: reproduce delayed mode/Ftst acceptance with injected reads/writes; implement bounded polling, stage diagnostics and heartbeat-safe transition.
- [x] Startup manager: installed apps plus actual login items, literal System Events commands, launchctl disabled override parsing and user-triggered switches with error refresh.
- [x] Preserve owned-agent compatibility, protected/unknown states and no mutation in tests.
- [x] Add automation usage text; build 1.1.35 build 37, run relevant regressions, review, sign and package DMG.
