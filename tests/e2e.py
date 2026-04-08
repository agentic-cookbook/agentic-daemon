#!/usr/bin/env python3
"""End-to-end test for agentic-daemon.

Lifecycle: install → drop job → verify execution → verify re-execution → uninstall.
Must be run from the repo root. Requires no arguments.
"""

import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

LABEL = "com.agentic-cookbook.daemon"
SUPPORT_DIR = Path.home() / "Library" / "Application Support" / LABEL
JOBS_DIR = SUPPORT_DIR / "jobs"
LOGS_DIR = Path.home() / "Library" / "Logs" / LABEL
PLIST_DST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
BINARY = SUPPORT_DIR / "agentic-daemon"

MARKER_ID = uuid.uuid4().hex[:12]
MARKER_PATH = Path(f"/tmp/agentic-e2e-marker-{MARKER_ID}")
JOB_NAME = "e2e-test"

# Timeouts
DAEMON_START_TIMEOUT = 15
JOB_RUN_TIMEOUT = 60  # includes compile time
RERUN_TIMEOUT = 30


class E2EResult:
    def __init__(self):
        self.steps: list[tuple[str, bool, str]] = []

    def record(self, name: str, passed: bool, detail: str = ""):
        status = "PASS" if passed else "FAIL"
        self.steps.append((name, passed, detail))
        print(f"  [{status}] {name}" + (f" — {detail}" if detail else ""))

    @property
    def all_passed(self) -> bool:
        return all(passed for _, passed, _ in self.steps)

    def summary(self):
        total = len(self.steps)
        passed = sum(1 for _, p, _ in self.steps if p)
        failed = total - passed
        print(f"\n{'=' * 50}")
        if failed == 0:
            print(f"  ALL {total} STEPS PASSED")
        else:
            print(f"  {failed} FAILED, {passed} passed out of {total}")
            for name, ok, detail in self.steps:
                if not ok:
                    print(f"    FAIL: {name}" + (f" — {detail}" if detail else ""))
        print(f"{'=' * 50}")


def repo_root() -> Path:
    """Find and validate repo root."""
    # Try current directory first, then script's parent's parent
    candidates = [Path.cwd(), Path(__file__).resolve().parent.parent]
    for p in candidates:
        if (p / "install.sh").exists() and (p / "AgenticDaemon").exists():
            return p
    return candidates[0]


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def is_daemon_loaded() -> bool:
    r = run(["launchctl", "list", LABEL])
    return r.returncode == 0


def is_daemon_running() -> bool:
    """Check if the daemon process is actually running."""
    r = run(["pgrep", "-f", str(BINARY)])
    return r.returncode == 0


def poll(predicate, timeout: float, interval: float = 0.5) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def make_test_job():
    """Create a test job that writes a marker file."""
    job_dir = JOBS_DIR / JOB_NAME
    job_dir.mkdir(parents=True, exist_ok=True)

    swift_source = f"""\
import Foundation
let marker = "{MARKER_PATH}"
let timestamp = ISO8601DateFormatter().string(from: Date())
let content = "e2e-ok \\(timestamp)"
try! content.write(toFile: marker, atomically: true, encoding: .utf8)
"""
    (job_dir / "job.swift").write_text(swift_source)

    config = {"intervalSeconds": 5, "timeout": 10, "enabled": True}
    (job_dir / "config.json").write_text(json.dumps(config))


def cleanup_test_job():
    job_dir = JOBS_DIR / JOB_NAME
    if job_dir.exists():
        shutil.rmtree(job_dir)


def uninstall_daemon(root: Path):
    """Run uninstall, piping 'y' to the log removal prompt."""
    subprocess.run(
        ["bash", str(root / "uninstall.sh")],
        input="y\n",
        capture_output=True,
        text=True,
    )


def get_daemon_logs(last_seconds: int = 120) -> str:
    """Fetch recent daemon logs from unified logging."""
    r = run([
        "log", "show",
        "--predicate", f'subsystem == "{LABEL}"',
        "--last", f"{last_seconds}s",
        "--style", "compact",
    ])
    return r.stdout if r.returncode == 0 else ""


# ── Main ──────────────────────────────────────────────────────────────

def main():
    root = repo_root()
    result = E2EResult()

    print(f"\nagentic-daemon E2E Test")
    print(f"  Repo:   {root}")
    print(f"  Marker: {MARKER_PATH}")
    print(f"{'=' * 50}\n")

    # ── Pre-flight ────────────────────────────────────────────────────

    print("Phase 1: Pre-flight")

    result.record(
        "repo structure",
        (root / "install.sh").exists() and (root / "AgenticDaemon").exists(),
        str(root),
    )

    already_installed = is_daemon_loaded()
    if already_installed:
        result.record("not already installed", False, "daemon already loaded — aborting to avoid clobbering")
        result.summary()
        return 1

    result.record("not already installed", True)

    swift_check = run(["swift", "--version"])
    result.record("swift available", swift_check.returncode == 0)

    if not result.all_passed:
        result.summary()
        return 1

    # ── Install ───────────────────────────────────────────────────────

    print("\nPhase 2: Install")

    try:
        install = subprocess.run(
            ["bash", str(root / "install.sh")],
            capture_output=True,
            text=True,
            timeout=120,
        )
        result.record("install.sh succeeds", install.returncode == 0, install.stderr.strip()[-200:] if install.returncode != 0 else "")
    except subprocess.TimeoutExpired:
        result.record("install.sh succeeds", False, "timed out after 120s")

    if not result.all_passed:
        print("\nInstall failed, cleaning up...")
        uninstall_daemon(root)
        result.summary()
        return 1

    try:
        result.record("binary exists", BINARY.exists(), str(BINARY))
        result.record("plist installed", PLIST_DST.exists())
        result.record("launchd loaded", is_daemon_loaded())

        daemon_started = poll(is_daemon_running, DAEMON_START_TIMEOUT)
        result.record("daemon process running", daemon_started, f"timeout={DAEMON_START_TIMEOUT}s")

        if not result.all_passed:
            result.summary()
            return 1

        # ── Drop test job ─────────────────────────────────────────────

        print("\nPhase 3: Drop test job")

        make_test_job()
        job_dir = JOBS_DIR / JOB_NAME
        result.record("job directory created", job_dir.exists())
        result.record("job.swift written", (job_dir / "job.swift").exists())
        result.record("config.json written", (job_dir / "config.json").exists())

        # ── Verify first execution ────────────────────────────────────

        print("\nPhase 4: Verify first execution")

        marker_appeared = poll(lambda: MARKER_PATH.exists(), JOB_RUN_TIMEOUT, interval=1.0)
        result.record("marker file created", marker_appeared, f"timeout={JOB_RUN_TIMEOUT}s")

        if marker_appeared:
            content = MARKER_PATH.read_text()
            result.record("marker content valid", content.startswith("e2e-ok"), repr(content[:80]))
        else:
            result.record("marker content valid", False, "marker never appeared")
            # Dump logs to help debug
            logs = get_daemon_logs()
            if logs:
                print(f"\n  Recent daemon logs:\n{logs[:2000]}")

        # ── Check logs ────────────────────────────────────────────────

        print("\nPhase 5: Verify logs")

        # os.log info-level messages aren't persisted — only launchd wrapper
        # messages appear in `log show`. The marker file already proves the
        # full pipeline (discover → compile → schedule → run) worked.
        logs = get_daemon_logs()
        result.record("daemon appears in unified log", LABEL in logs, "checked for launchd service entry")

        # ── Verify re-execution ───────────────────────────────────────

        print("\nPhase 6: Verify re-execution")

        if marker_appeared:
            MARKER_PATH.unlink()
            result.record("marker deleted", not MARKER_PATH.exists())

            reran = poll(lambda: MARKER_PATH.exists(), RERUN_TIMEOUT, interval=1.0)
            result.record("job re-executed on schedule", reran, f"timeout={RERUN_TIMEOUT}s")
        else:
            result.record("marker deleted", False, "skipped — first run failed")
            result.record("job re-executed on schedule", False, "skipped")

    finally:
        # ── Cleanup & Uninstall ───────────────────────────────────────

        print("\nPhase 7: Cleanup & Uninstall")

        cleanup_test_job()
        result.record("test job removed", not (JOBS_DIR / JOB_NAME).exists())

        if MARKER_PATH.exists():
            MARKER_PATH.unlink()

        uninstall_daemon(root)

        daemon_unloaded = poll(lambda: not is_daemon_loaded(), 10)
        result.record("daemon unloaded", daemon_unloaded, "polled up to 10s")

        daemon_stopped = poll(lambda: not is_daemon_running(), 10)
        result.record("daemon process stopped", daemon_stopped)

        result.record("plist removed", not PLIST_DST.exists())
        result.record("support dir removed", not SUPPORT_DIR.exists())

    result.summary()
    return 0 if result.all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
