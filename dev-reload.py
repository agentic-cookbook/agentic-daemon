#!/usr/bin/env python3
"""
Development reload script for agentic-daemon.

Builds the debug binary and dylib, writes a dev launchd plist pointing at them,
and hot-swaps the running daemon so changes take effect immediately.

Usage:
    python3 dev-reload.py          # build + full reload
    python3 dev-reload.py --quick  # skip build, just kickstart
"""

import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path

LABEL = "com.agentic-cookbook.daemon"
BOOTSTRAP_RETRIES = 3
BOOTSTRAP_RETRY_DELAY = 2   # seconds between retries
PID_WAIT_TIMEOUT = 10       # seconds to wait for daemon PID after bootstrap

repo = Path(__file__).parent.resolve()
pkg_dir = repo / "AgenticDaemon"
build_dir = repo / ".build" / "debug"
binary = build_dir / "agentic-daemon"
dylib = build_dir / "libAgenticJobKit.dylib"

home = Path.home()
support_dir = home / "Library" / "Application Support" / LABEL
lib_dir = support_dir / "lib"
logs_dir = home / "Library" / "Logs" / LABEL
plist_dst = home / "Library" / "LaunchAgents" / f"{LABEL}.plist"

uid = os.getuid()
gui = f"gui/{uid}"
target = f"{gui}/{LABEL}"


def build() -> None:
    print("Building (debug)...")
    result = subprocess.run(["swift", "build", "--package-path", str(pkg_dir)])
    if result.returncode != 0:
        sys.exit(result.returncode)
    print()


def check_binary() -> None:
    if not binary.exists():
        print(f"error: binary not found: {binary}", file=sys.stderr)
        print("Run without --quick to build first.", file=sys.stderr)
        sys.exit(1)


def deploy_dylib() -> None:
    """Copy freshly-built dylib into Application Support so jobs compiled against
    the installed lib pick up new AgenticJobKit changes immediately."""
    if not dylib.exists():
        return
    if not lib_dir.exists():
        return  # not installed — nothing to update
    dst = lib_dir / "libAgenticJobKit.dylib"
    shutil.copy2(dylib, dst)
    dst.chmod(0o755)

    # Copy swift module metadata if present
    modules_src = build_dir / "Modules"
    modules_dst = lib_dir / "Modules"
    if modules_src.exists() and modules_dst.exists():
        for ext in ("swiftmodule", "swiftdoc", "abi.json", "swiftsourceinfo"):
            src = modules_src / f"AgenticJobKit.{ext}"
            if src.exists():
                shutil.copy2(src, modules_dst / f"AgenticJobKit.{ext}")

    print(f"AgenticJobKit deployed: {lib_dir}")


def write_dev_plist() -> None:
    logs_dir.mkdir(parents=True, exist_ok=True)
    plist: dict = {
        "Label": LABEL,
        "ProgramArguments": [str(binary)],
        "KeepAlive": True,
        "RunAtLoad": True,
        "ThrottleInterval": 10,
        "WorkingDirectory": str(support_dir),
        "StandardOutPath": str(logs_dir / "stdout.log"),
        "StandardErrorPath": str(logs_dir / "stderr.log"),
    }
    with open(plist_dst, "wb") as f:
        plistlib.dump(plist, f)


def bootout() -> None:
    """Unload unconditionally. Ignores 'not loaded'. Sleeps 1s after."""
    subprocess.run(["launchctl", "bootout", target], capture_output=True)
    time.sleep(1)


def bootstrap() -> None:
    """Write dev plist and bootstrap, retrying on transient failures."""
    write_dev_plist()
    for attempt in range(1, BOOTSTRAP_RETRIES + 1):
        result = subprocess.run(
            ["launchctl", "bootstrap", gui, str(plist_dst)],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return
        if attempt < BOOTSTRAP_RETRIES:
            print(f"  bootstrap attempt {attempt} failed (exit {result.returncode}), retrying...")
            bootout()
            time.sleep(BOOTSTRAP_RETRY_DELAY)
        else:
            msg = result.stderr.strip() or result.stdout.strip()
            print(f"error: bootstrap failed after {BOOTSTRAP_RETRIES} attempts", file=sys.stderr)
            if msg:
                print(f"  {msg}", file=sys.stderr)
            print(f"  Check logs: tail -f {logs_dir / 'stderr.log'}", file=sys.stderr)
            sys.exit(1)


def kickstart() -> None:
    """Kickstart the running daemon. Falls back to bootout+bootstrap if it fails."""
    result = subprocess.run(
        ["launchctl", "kickstart", "-k", target],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"  kickstart failed (exit {result.returncode}), falling back to full reload...")
        bootout()
        bootstrap()


def reload_daemon() -> None:
    is_registered = subprocess.run(
        ["launchctl", "list", LABEL], capture_output=True
    ).returncode == 0

    if is_registered:
        try:
            with open(plist_dst, "rb") as f:
                existing = plistlib.load(f)
            already_dev = existing.get("ProgramArguments", [None])[0] == str(binary)
        except Exception:
            already_dev = False

        if already_dev:
            print("Restarting daemon (kickstart)...")
            kickstart()
        else:
            print("Replacing plist with dev plist...")
            bootout()
            bootstrap()
    else:
        print("Bootstrapping dev daemon...")
        bootstrap()


def wait_for_pid(timeout: int = PID_WAIT_TIMEOUT) -> str:
    """Poll launchctl until the daemon has a PID or timeout expires."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = subprocess.run(
            ["launchctl", "list", LABEL], capture_output=True, text=True
        )
        if result.returncode == 0:
            pid_lines = [l for l in result.stdout.splitlines() if '"PID"' in l]
            if pid_lines:
                return pid_lines[0].split()[-1].rstrip(",")
        time.sleep(0.5)
    return ""


def verify() -> None:
    pid = wait_for_pid()
    if pid:
        print(f"Daemon running (PID {pid})")
    else:
        print("warning: daemon registered but no PID — may be starting or crashed")
        print(f"  Check logs: tail -f {logs_dir / 'stderr.log'}", file=sys.stderr)
        sys.exit(1)


def main() -> None:
    quick = "--quick" in sys.argv

    if not quick:
        build()

    check_binary()
    deploy_dylib()
    reload_daemon()
    print()
    verify()

    print()
    print(f"  Daemon:  {binary}")
    print(f"  Logs:    tail -f {logs_dir / 'stdout.log'}")
    print()
    print("Quick reload after next build:")
    print(f"  swift build --package-path AgenticDaemon && python3 {Path(__file__).name} --quick")
    print()
    print("Check status:")
    print("  agd status")
    print(f"  # or: launchctl list {LABEL}")


if __name__ == "__main__":
    main()
