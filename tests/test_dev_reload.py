#!/usr/bin/env python3
"""
End-to-end tests for dev-reload.py.

Validates: build → bootstrap → PID visible → kickstart → PID still visible → cleanup.

Usage:
    python3 tests/test_dev_reload.py

Note: This test builds a debug binary and bootstraps the daemon under launchd.
It will stop and unregister the daemon when done. Run from the repo root.
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

LABEL = "com.agentic-cookbook.daemon"
repo = Path(__file__).parent.parent.resolve()
dev_reload = repo / "dev-reload.py"


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(list(args), capture_output=True, text=True, check=check)


def daemon_pid() -> str:
    result = run("launchctl", "list", LABEL, check=False)
    if result.returncode != 0:
        return ""
    for line in result.stdout.splitlines():
        if '"PID"' in line:
            return line.split()[-1].rstrip(",").strip('"')
    return ""


def wait_for_pid(timeout: int = 15) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        pid = daemon_pid()
        if pid:
            return pid
        time.sleep(0.5)
    return ""


def bootout() -> None:
    run("launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}", check=False)
    time.sleep(1)


def test_full_reload() -> None:
    print("test_full_reload: build + bootstrap + verify PID ...")
    bootout()  # clean slate
    result = subprocess.run(
        [sys.executable, str(dev_reload)],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("FAIL: dev-reload.py exited non-zero")
        print(result.stdout[-2000:])
        print(result.stderr[-1000:], file=sys.stderr)
        sys.exit(1)
    pid = wait_for_pid()
    if not pid:
        print("FAIL: no PID after full reload")
        sys.exit(1)
    print(f"  PASS (PID {pid})")


def test_quick_reload() -> None:
    print("test_quick_reload: kickstart without rebuild ...")
    result = subprocess.run(
        [sys.executable, str(dev_reload), "--quick"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("FAIL: dev-reload.py --quick exited non-zero")
        print(result.stdout[-2000:])
        print(result.stderr[-1000:], file=sys.stderr)
        sys.exit(1)
    pid = wait_for_pid()
    if not pid:
        print("FAIL: no PID after quick reload")
        sys.exit(1)
    print(f"  PASS (PID {pid})")


def cleanup() -> None:
    print("cleanup: stopping dev daemon ...")
    bootout()
    print("  done")


def main() -> None:
    if not dev_reload.exists():
        print(f"error: dev-reload.py not found at {dev_reload}", file=sys.stderr)
        sys.exit(1)

    try:
        test_full_reload()
        test_quick_reload()
    finally:
        cleanup()

    print()
    print("All dev-reload tests passed.")


if __name__ == "__main__":
    main()
