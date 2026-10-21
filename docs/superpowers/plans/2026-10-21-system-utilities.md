# System Utilities Implementation Plan

> **For agentic workers:** Use independent subsystem agents, then integrate and verify in the parent session.

**Goal:** Add startup management, real fan control and per-app input switching to OmniDesk menu bar.

**Architecture:** Three controllers expose window methods and keep OS access separate from testable policies. AppDelegate owns lifetime and menu actions; existing shortcut settings provide configurable bindings.

**Tech Stack:** Swift, AppKit, SwiftUI, Carbon TIS, ServiceManagement, IOKit/SMC.

**Spec:** `docs/superpowers/specs/2026-10-21-system-utilities-design.md`

## Global Constraints

- Apple Silicon / macOS 15+, existing bundle IDs and shortcut IDs preserved.
- No host startup, input source or fan mutation during development tests.
- Privileged operations limited to fan automatic/maximum commands.
- Preserve pending archive functionality and source changes.

## Review Focus

- Startup path symlinks and unrelated plist ownership must not permit overwrite/delete.
- Missing input source or unconfigured app must not switch unpredictably.
- Hardware limits invalid or absent must fail without writes.
- Fan control partial failure, timeout and parent exit must restore automatic control.
- Privileged helper must not accept arbitrary commands or attacker-supplied executable paths.

## Tasks

- [x] StartupManager.swift + StartupManagerTests.swift: fixture ownership checks, LaunchAgent creation, enable/disable/remove and system metadata UI.
- [x] InputSourceSwitcher.swift + InputSourceSwitcherTests.swift: TIS bridge, persisted per-app rules, decision tests, activation observer and rules UI.
- [x] FanControl.swift + FanHelper sources + FanControlTests.swift: SMC types, bounds tests, readback/rollback, narrow privileged helper and automatic restore lifetime.
- [x] AppDelegate.swift + KeyboardShortcuts.swift: three menu actions, optional configurable shortcuts, lifecycle cleanup. Test stable hotkey identifiers and new actions.
- [ ] Build/package scripts, README/changelog/validation: bump 1.1.34 build 36, compile helper if needed, preserve licenses, run relevant tests, verify signatures and DMG checksums.
