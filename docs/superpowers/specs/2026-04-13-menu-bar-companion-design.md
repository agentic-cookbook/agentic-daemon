# Menu Bar Companion App — Design Spec

**Date:** 2026-04-13  
**Status:** Approved

## Overview

A macOS menu bar companion app (`AgenticMenuBar`) that runs alongside `agentic-daemon` and exposes full visibility and control over the daemon and its jobs via an `NSStatusItem`. Communication uses XPC (Approach A: daemon as XPC listener).

---

## Repo Structure

Three changes to `Package.swift`:

| Target | Type | Path | Depends on |
|---|---|---|---|
| `AgenticXPCProtocol` | library (new) | `Sources/AgenticXPCProtocol` | — |
| `AgenticDaemonLib` | library (existing) | `Sources/AgenticDaemonLib` | + `AgenticXPCProtocol` |
| `AgenticMenuBar` | executable (new) | `Sources/AgenticMenuBar` | `AgenticXPCProtocol` |

`AgenticXPCProtocol` is the only coupling point between the daemon and the companion. Neither depends on the other directly.

`AgenticMenuBar` is an `LSUIElement` app (no Dock icon, `.accessory` activation policy). It ships as a separate binary alongside the daemon binary.

---

## XPC Protocol

Mach service name: `com.agentic-cookbook.daemon.xpc`

```swift
@objc protocol AgenticDaemonXPC {
    // Status queries
    func getDaemonStatus(reply: @escaping (Data) -> Void)   // → DaemonStatus (JSON)
    func getCrashReports(reply: @escaping (Data) -> Void)   // → [CrashReport] (JSON)

    // Job control
    func enableJob(_ name: String, reply: @escaping (Bool) -> Void)
    func disableJob(_ name: String, reply: @escaping (Bool) -> Void)
    func triggerJob(_ name: String, reply: @escaping (Bool) -> Void)
    func clearBlacklist(_ name: String, reply: @escaping (Bool) -> Void)

    // Daemon control
    func shutdown(reply: @escaping () -> Void)
}
```

Complex types cross as JSON-encoded `Data` (XPC natively supports only `NSSecureCoding` types; existing `Codable` structs encode cleanly). Start is not in the protocol — the companion calls `launchctl start com.agentic-cookbook.daemon` directly since a stopped daemon cannot respond to XPC.

---

## Daemon-Side Changes

Two new files in `AgenticDaemonLib`:

### `XPCServer.swift`
Registers the Mach service and accepts connections:
- `NSXPCListener(machServiceName:)` with self as delegate
- `shouldAcceptNewConnection` sets the exported interface and object, then resumes the connection

### `XPCHandler.swift`
Implements `AgenticDaemonXPC` by delegating to existing components:
- `getDaemonStatus` → queries `Scheduler` actor for job states + uptime, JSON-encodes `DaemonStatus`
- `getCrashReports` → reads from `CrashReportStore`, JSON-encodes `[CrashReport]`
- `enableJob` / `disableJob` → writes updated `enabled` flag to the job's `config.json` on disk, then calls `discovery.discover()` + `scheduler.syncJobs()` to pick up the change
- `triggerJob` → calls a new `Scheduler.triggerJob(name:)` method (to be added) that sets `nextRun = .now` for the named job
- `clearBlacklist` → delegates to `CrashTracker.clearBlacklist`
- `shutdown` → calls `DaemonController.shutdown()`

**Existing file changes:**
- `DaemonController` gains one property (`let xpcServer: XPCServer`) started in `run()` before the main loop.
- `Scheduler` gains one new method: `func triggerJob(name: String)` — sets `scheduledJobs[name]?.nextRun = .now`.
- No other existing files change.

---

## Companion App Structure

Five source files in `Sources/AgenticMenuBar`:

| File | Responsibility |
|---|---|
| `main.swift` | `NSApplication` setup, `.accessory` activation policy, run loop |
| `AppDelegate.swift` | Creates `NSStatusItem`, owns `DaemonClient`, drives 5s refresh timer |
| `DaemonClient.swift` | Wraps `NSXPCConnection`, exposes `async` methods, handles reconnect on interruption |
| `MenuBuilder.swift` | Builds `NSMenu` from latest `DaemonStatus` + crash list |
| `CrashDetailWindow.swift` | Opens `NSWindow` with full crash report when user clicks a crash entry |

`DaemonClient` bridges XPC callback replies to Swift `async` and reconnects automatically when the daemon restarts.

---

## Menu Structure

**Status item icon:** small icon that turns red when daemon is stopped or has unacknowledged crashes.

**Main menu (daemon running):**
```
● agentic-daemon                    uptime 2h 14m
─────────────────────────────────────────────────
JOBS (3)
  ● cleanup                         next: 4m  ▶
  ● sync                            running…  ▶
  ○ backup                          disabled  ▶
─────────────────────────────────────────────────
RECENT CRASHES (1)
  ⚠ sync — 3h ago          EXC_BAD_ACCESS
─────────────────────────────────────────────────
  Restart Daemon
  Stop Daemon
─────────────────────────────────────────────────
  Quit
```

**Job submenu (click ▶):**
```
cleanup
Next run in 4m 12s
─────────────────
CONFIG
  Interval      60s
  Timeout       30s
  Run at wake   Yes
  Backoff       Yes
RUNTIME
  Failures      0
  Blacklisted   No
─────────────────
  Trigger Now
  Disable Job
  Clear Blacklist
```

**Daemon stopped state:** status dot turns red, jobs section hidden, single "Start Daemon" item shown in place of controls.

**Crash detail:** clicking a crash entry opens a separate `NSWindow` with the full crash report (job name, timestamp, signal, exception type, stack trace, system info).

---

## Data Flow

```
AppDelegate (5s timer)
  └─ DaemonClient.getDaemonStatus() ──XPC──▶ XPCHandler.getDaemonStatus()
  └─ DaemonClient.getCrashReports() ──XPC──▶ XPCHandler.getCrashReports()
       ↓ DaemonStatus + [CrashReport]
     MenuBuilder.build(status:crashes:)
       ↓ NSMenu
     NSStatusItem.menu = menu

User action (e.g. Trigger Now)
  └─ DaemonClient.triggerJob("sync") ──XPC──▶ XPCHandler.triggerJob()
       └─ Scheduler.setNextRun(.now, for: "sync")
```

---

## Error Handling

- **Daemon not running:** `DaemonClient` catches XPC connection interruption, sets internal state to `.disconnected`, `MenuBuilder` renders the stopped-state menu.
- **XPC call timeout:** `DaemonClient` enforces a deadline via `Task` cancellation; failed calls surface as a "Last update failed" label in the menu header.
- **Job control failure:** reply `Bool` is `false`; menu shows a brief error label on the next refresh.
- **Crash detail unavailable:** if a crash report file is missing/corrupt, `CrashDetailWindow` shows an error message rather than crashing.

---

## Testing

- `AgenticXPCProtocol` — no logic, no tests needed.
- `XPCHandler` — unit-testable by injecting mock dependencies. `Scheduler` is an `actor`, so a `SchedulerProtocol` needs to be extracted to allow mocking; same for `DaemonController` (add a `ShutdownProvider` protocol).
- `MenuBuilder` — unit-testable: given a `DaemonStatus` + `[CrashReport]`, assert the resulting `NSMenu` item titles and enabled states.
- `DaemonClient` — integration test against a real `XPCServer` in-process using a local `NSXPCConnection`.
- `CrashDetailWindow` — manual / snapshot test.

---

## Installation

`install.sh` changes:
- Builds `AgenticMenuBar` target alongside the daemon.
- Copies `agentic-menubar` binary to `~/Library/Application Support/com.agentic-cookbook.daemon/`.
- Installs a second LaunchAgent plist (`com.agentic-cookbook.menubar.plist`) so the companion auto-launches at login. The daemon plist loads first.
