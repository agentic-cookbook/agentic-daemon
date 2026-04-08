# launchd & macOS Background Daemons
### Architecture, Patterns & Best Practices

---

## 1. What is launchd?

`launchd` is the master process manager and service framework on macOS. It is PID 1 — the first process the kernel spawns — and the ancestor of every other process on the system.

It unifies what Unix systems traditionally split across multiple daemons:

- **init** — bootstraps the system and manages process lifecycle
- **inetd** — on-demand socket activation
- **cron** — scheduled job execution
- **rc** — startup scripts
- **watchdog** — process supervision and restart-on-crash

Apple replaced all of these with `launchd` starting in OS X Tiger (10.4).

### Two Realms

**System-wide daemons** run as root, start at boot, and require no user session. **Per-user agents** run in the context of a logged-in user — GUI helpers, user-level sync services, and custom tools.

### Job Definition Locations

| Location | Owner | Purpose |
|---|---|---|
| `/System/Library/LaunchDaemons` | Apple | OS daemons (SIP-sealed) |
| `/Library/LaunchDaemons` | Admin / third-party | System-wide daemons |
| `/System/Library/LaunchAgents` | Apple | OS per-user agents (SIP-sealed) |
| `/Library/LaunchAgents` | Admin / third-party | Per-user agents (all users) |
| `~/Library/LaunchAgents` | You | Your personal agents |

### Key Behavioral Knobs

- **`RunAtLoad`** — start immediately when plist is loaded
- **`KeepAlive`** — restart the process if it exits (watchdog)
- **`StartInterval`** — run every N seconds (cron replacement)
- **`StartCalendarInterval`** — cron-style time-based scheduling
- **`ThrottleInterval`** — minimum seconds between restarts after a crash
- **`WatchPaths`** — launch when a file or directory changes
- **`EnvironmentVariables`** — inject env vars into the job
- **`StandardOutPath` / `StandardErrorPath`** — redirect stdout/stderr to log files
- **`WorkingDirectory`** — set the CWD (defaults to `/` if omitted)

### launchctl — The Control Interface

```bash
# Modern bootstrap / bootout syntax (macOS 10.11+)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.you.tool.plist
launchctl bootout  gui/$(id -u)/com.you.tool

# Start / stop manually
launchctl start com.you.tool
launchctl stop  com.you.tool

# Inspect
launchctl list                              # all loaded jobs
launchctl print gui/$(id -u)/com.you.tool  # full job state dump
```

### Domain Model

macOS 10.10+ introduced a proper domain model. The older `load`/`unload` commands are deprecated because they did not understand domains.

| Domain | Scope |
|---|---|
| `system/` | Root-owned system services |
| `gui/<uid>` | Graphical user session |
| `user/<uid>` | User context (no GUI required) |
| `pid/<pid>` | Process-scoped (XPC) |

---

## 2. Persistent Loop Pattern

For a background job that needs dynamic intervals, the right approach is not a `StartInterval` plist — it is a persistent process that owns its own timing loop.

### How It Works

1. **launchd spawns your process once** — that's it, just the initial spawn
2. **Your script loops forever**, sleeping between iterations for whatever interval makes sense
3. **If your process dies** (crash, unhandled exception, kill signal) — launchd restarts it automatically via `KeepAlive`

### Python Implementation

```python
import signal, sys, time, datetime

def do_work() -> float:
    """Returns seconds to sleep until next run."""
    print(f'{datetime.datetime.now().isoformat()} — working')
    # your logic here
    return 60.0

def handle_sigterm(signum, frame):
    # flush, close connections, write state
    sys.exit(0)

signal.signal(signal.SIGTERM, handle_sigterm)

def main():
    while True:
        try:
            interval = do_work()
        except Exception as e:
            print(f'Error: {e}', file=sys.stderr)
            interval = 60   # back off and retry
        time.sleep(interval)

if __name__ == '__main__':
    main()
```

The `try/except` inside the loop is critical — without it, an unhandled exception exits the process, launchd restarts it, it crashes again immediately, and you get a rapid restart loop.

### Minimal Plist for Persistent Loop

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mikemikula.myjob</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Users/mike/scripts/myjob.py</string>
    </array>

    <key>KeepAlive</key>
    <true/>

    <key>RunAtLoad</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>30</integer>

    <key>StandardOutPath</key>
    <string>/Users/mike/logs/myjob.stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/mike/logs/myjob.stderr.log</string>
</dict>
</plist>
```

Note there is no `StartInterval` — the process owns all timing.

### Sleep / Wake Robustness

`time.sleep()` does not count elapsed time during system sleep. After a wake event, the sleep resumes from where it was suspended. Use wall-clock polling to handle this correctly:

```python
from datetime import datetime, timedelta
import time

def sleep_until(target: datetime):
    """Sleep until a wall-clock target, robust to system sleep/wake."""
    while True:
        remaining = (target - datetime.now()).total_seconds()
        if remaining <= 0:
            return
        time.sleep(min(remaining, 30))  # re-check wall time every 30s

def main():
    while True:
        do_work()
        next_run = datetime.now() + timedelta(seconds=300)
        sleep_until(next_run)
```

The `min(remaining, 30)` is the key — you wake up every 30 seconds at most to re-check wall time, so after a system wake you immediately notice the target has passed and run without delay.

### Overhead of a Sleeping Process

During `time.sleep()` the process is moved off the run queue entirely — the kernel does not schedule it and the CPU does not touch it. It consumes essentially zero CPU. Memory is whatever the interpreter footprint is at rest, typically 8–15 MB for a simple script, and macOS will page those out under memory pressure.

`StartInterval` actually has a higher amortized cost for frequent invocations because Python pays the interpreter startup tax on every single call.

---

## 3. Python vs Swift vs Compiled

### Runtime Comparison

| Concern | Python | Swift Script | Compiled Swift |
|---|---|---|---|
| Startup time | ~50–100ms | ~1–3s (compiles each run) | ~5–10ms |
| Runtime performance | Interpreted | Fully compiled | Fully compiled |
| RSS footprint | 10–20MB (may grow) | ~3–8MB | ~3–8MB stable |
| Memory fragmentation | Possible over time | None (ARC) | None (ARC) |
| GC pauses | Occasional | None | None |
| SIGTERM handling | Manual, easy | Manual, natural | Manual, natural |
| Sleep/wake events | Hard — no IOKit | Native | Native |
| Network reachability | Try/catch only | NWPathMonitor | NWPathMonitor |
| Unified logging | No | Yes (os.log) | Yes (os.log) |
| Development speed | Fast | Fast | Slower |
| Framework access | Limited | Full | Full |

### Python Memory Considerations

Python's memory allocator tends to fragment over time. A script that allocates and releases lots of objects in a loop will slowly grow its RSS even if the working set is constant. Force a collection cycle if you see creep:

```python
import gc

def main():
    while True:
        do_work()
        gc.collect()
        time.sleep(interval)
```

### Swift Script Shebang

Swift scripts are compiled on every invocation by `swiftc` — this is why startup takes 1–3 seconds. For a persistent-loop daemon this cost is paid exactly once, making it a sweet spot: full framework access, native performance, zero build step.

```swift
#!/usr/bin/env swift
import Foundation
import os

let logger = Logger(subsystem: "com.mikemikula.myjob", category: "main")

signal(SIGTERM) { _ in exit(0) }

func doWork() -> TimeInterval {
    logger.info("Job running")
    // work here
    return 60.0
}

while true {
    let interval = doWork()
    Thread.sleep(forTimeInterval: interval)
}
```

### Unified Logging — Swift Advantage

Swift can write to the macOS unified logging system, which surfaces in Console.app with proper metadata, log levels, subsystem filtering, and persistence.

```swift
import os

let logger = Logger(subsystem: "com.mikemikula.myjob", category: "main")
logger.info("Job ran, next interval: \(interval)s")
logger.error("Failed: \(error)")

// Query from terminal:
// log stream --predicate 'subsystem == "com.mikemikula.myjob"'
```

### Sleep/Wake Events — Swift Advantage

If you need to react to sleep/wake events rather than just tolerate them, Python cannot easily tap into IOKit's power notifications. Swift can:

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil,
    queue: .main
) { _ in
    // system just woke — run immediately if overdue
}
```

### The Practical Recommendation

For a quick utility, Python wins on development speed and is completely fine. For something you're shipping, running on other people's machines, or that needs to be rock solid over weeks of uptime — Swift is worth the investment. The operational visibility from unified logging alone is compelling once you've used it.

For a launchd persistent-loop job specifically, a Swift script is genuinely compelling. You pay the compile cost once, then get native performance and full OS integration for the life of the process. When it matures, `swift package init --type executable` and compile it — the source code barely changes.

---

## 4. Compiled Runner + Plugin Architecture

A stable compiled Swift daemon that discovers, compiles, and dispatches to swappable job scripts. Essentially a mini launchd you control completely.

### Directory Layout

```
~/Library/Application Support/com.mikemikula.runner/
    runner                   ← compiled Swift daemon (launchd owns this)
    jobs/
        sync-photos/
            job.swift        ← or job.py, job.sh — anything executable
            .job-bin         ← compiled cache (auto-managed by runner)
            config.json
        check-mail/
            job.swift
            .job-bin
            config.json
        backup/
            job.py           ← Python jobs skip compilation entirely
            config.json
```

### config.json Schema

```json
{
  "intervalSeconds": 60,
  "enabled": true,
  "timeout": 30,
  "runAtWake": true,
  "backoffOnFailure": true
}
```

Read once at startup. The runner can also watch configs with `DispatchSource` for hot-reload without restart.

### Compilation Decision Logic

```swift
func needsCompile(jobDir: URL) -> Bool {
    guard let source = sourceURL(in: jobDir),
          source.pathExtension == "swift"   // non-Swift jobs skip compilation
    else { return false }

    let binary = binaryURL(in: jobDir)

    guard FileManager.default.fileExists(atPath: binary.path) else {
        return true   // no binary yet
    }

    let sourceDate = modificationDate(of: source)
    let binaryDate = modificationDate(of: binary)

    switch (sourceDate, binaryDate) {
    case let (s?, b?): return s > b   // source is newer than binary
    default:           return true    // can't determine — recompile to be safe
    }
}
```

### Compile with Error Capture

```swift
func compile(jobDir: URL) -> Bool {
    guard let source = sourceURL(in: jobDir) else { return false }
    let binary = binaryURL(in: jobDir)
    let name   = jobDir.lastPathComponent

    logger.info("Compiling \(name)...")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    process.arguments     = [source.path, "-O", "-o", binary.path]

    let stderr = Pipe()
    process.standardError = stderr

    try? process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let output = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        logger.error("Compile failed for \(name):\n\(output)")
        return false
    }

    logger.info("Compiled \(name) successfully")
    return true
}
```

Compile on a background queue so it does not stall the scheduler loop:

```swift
DispatchQueue.global(qos: .utility).async {
    self.compile(jobDir: jobDir)
}
```

### Hot-Reload Directory Watcher

The runner watches the jobs directory using `DispatchSource`. A debounce prevents spurious triggers from mid-save writes.

```swift
var debounceTimer: DispatchWorkItem?

func watchDirectory() {
    let fd = open(jobsDirectory.path, O_EVTONLY)
    guard fd >= 0 else { return }

    let watcher = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .delete, .rename],
        queue: .global()
    )

    watcher.setEventHandler { [weak self] in
        // Debounce — wait 1s for file saves to settle
        self?.debounceTimer?.cancel()
        let work = DispatchWorkItem { self?.syncJobs() }
        self?.debounceTimer = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    watcher.resume()
}
```

### Job Sync Logic

```swift
func syncJobs() {
    let discovered = Set(discoverJobs().map(\.lastPathComponent))
    let current    = Set(scheduledJobs.keys)

    // New jobs
    for name in discovered.subtracting(current) { addJob(name: name) }

    // Removed jobs
    for name in current.subtracting(discovered) { removeJob(name: name) }

    // Updated sources — recompile
    for name in discovered.intersection(current) {
        let jobDir = jobsDirectory.appendingPathComponent(name)
        if needsCompile(jobDir: jobDir) {
            // Wait for any running instance before replacing binary
            scheduledJobs[name]?.waitForCompletion()
            compile(jobDir: jobDir)
        }
    }
}
```

### Scheduler Loop

```swift
func runLoop() {
    while true {
        let now = Date.now

        for (name, var job) in scheduledJobs where job.nextRun <= now {
            DispatchQueue.global().async { job.run() }
            scheduledJobs[name]?.nextRun = now.addingTimeInterval(
                job.config.intervalSeconds
            )
        }

        Thread.sleep(forTimeInterval: 1.0)  // 1-second scheduler resolution
    }
}
```

### What You Get

- Hot-reloadable job configs without touching launchd
- Per-job timeouts launchd does not provide natively
- Centralized structured logging across all jobs via `os.log`
- Mixed job languages — Swift binaries, Python scripts, shell
- Sleep/wake awareness in one place, propagated to all jobs
- A single launchd plist to manage instead of one per job
- Drop a job directory in — it compiles and schedules automatically
- Remove a directory — binary cleaned up, job removed from schedule

### Per-Job Invocation Overhead

| Cost | Amount |
|---|---|
| `Process()` spawn | ~5–20ms |
| Swift script compile (first run only) | ~1–3 seconds |
| Swift binary (cached) | ~5–10ms |
| Python startup | ~50–100ms |
| Shell script | ~5ms |
| JSON config read | <1ms |

---

## 5. Installation & Location

### Recommended Path

For a personal daemon you build and run yourself, `~/Library/Application Support/` is the most macOS-idiomatic location. The `~` resolves correctly across your entire fleet regardless of machine or username.

```
~/Library/Application Support/com.mikemikula.runner/
    runner          ← compiled daemon binary
    jobs/           ← job plugin directories

~/Library/LaunchAgents/
    com.mikemikula.runner.plist   ← always here, always
```

### Conventional Locations

| Location | Convention |
|---|---|
| `/usr/local/bin/` | Admin-installed tools (Homebrew-style) |
| `/usr/local/libexec/` | Admin-installed background daemons |
| `~/bin/` or `~/.local/bin/` | Personal tools |
| `~/Library/Application Support/<name>/` | macOS-idiomatic for app support files |
| `/Applications/<name>.app/Contents/MacOS/` | If wrapped in an app bundle |

### Security Rules

- Binary must not be world-writable — launchd refuses to run it
- Correct permissions: `chmod 755 runner && chown mike:staff runner`
- SIP seals `/System/` — never write there, even as root
- `/usr/local/` is fine for admin-installed tools
- For cross-machine distribution, sign with at minimum an ad-hoc signature:

```bash
codesign --sign - --force --preserve-metadata=entitlements runner
```

### Working Directory

launchd defaults the working directory to `/`. Always use absolute paths in your daemon, or set it explicitly in the plist:

```xml
<key>WorkingDirectory</key>
<string>/Users/mike/Library/Application Support/com.mikemikula.runner</string>
```

### Install Script

```zsh
#!/bin/zsh

LABEL="com.mikemikula.runner"
SUPPORT="$HOME/Library/Application Support/$LABEL"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

mkdir -p "$SUPPORT/jobs"
cp runner "$SUPPORT/runner"
chmod 755 "$SUPPORT/runner"

# Unload if already registered
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null

# Install and start
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed: $LABEL"
launchctl list "$LABEL"
```

### Uninstall Script

```zsh
#!/bin/zsh

LABEL="com.mikemikula.runner"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SUPPORT="$HOME/Library/Application Support/$LABEL"

launchctl bootout "gui/$(id -u)/${LABEL}"
rm "$PLIST"
rm -rf "$SUPPORT"

echo "Removed: $LABEL"
```

### Multi-Machine Fleet Notes

Since `~` resolves correctly on every machine, the plist and support directory structure can live in a dotfiles repo with an install script that drops everything in the right place. The binary itself needs to be compiled per-architecture (Intel vs Apple Silicon) or built as a universal binary:

```bash
swiftc -O runner.swift -o runner \
    -target arm64-apple-macos13 \
    -target-variant x86_64-apple-macos13
```

---

*launchd & macOS Background Daemons — Research Reference*
