"""Observe the original agy TUI in an isolated PTY, without an account."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time


def observe(device, output, linux=None, repeat=False):
    output.mkdir(parents=True, exist_ok=True)
    prefix = "tui-reentry" if repeat else "tui"
    with tempfile.TemporaryDirectory(dir=output) as root:
        root = Path(root)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
        env = os.environ.copy()
        for name, value in {
            "HOME": str(root), "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_CACHE_HOME": str(root / "cache"), "TERM": "xterm-256color",
        }.items():
            env[("" if linux else "SIMCTL_CHILD_") + name] = value
        # Test a clean unauthenticated launch. Do not inherit account credentials.
        for name in list(env):
            if any(word in name.upper() for word in ("API_KEY", "AUTH_TOKEN", "ACCESS_TOKEN", "GOOGLE_APPLICATION_CREDENTIALS")):
                del env[name]
        command = ([linux] if linux else ["xcrun", "simctl", "spawn", device,
                   str(output / "test-load"), str(output / ("AgyEngineTUI" if repeat else "AgyEngine")),
                   "tui", os.ttyname(slave)])
        phases = []
        with (output / f"{prefix}-host.txt").open("w") as log, (output / f"{prefix}-terminal.txt").open("wb") as transcript:
            process = subprocess.Popen(command, stdin=slave if linux else subprocess.DEVNULL,
                                       stdout=slave if linux else log, stderr=slave if linux else log,
                                       cwd=root, env=env, start_new_session=True,
                                       preexec_fn=(lambda: fcntl.ioctl(slave, termios.TIOCSCTTY, 0)) if linux else None)
            try:
                steps = [("initial", b"", 90),
                                               ("down", b"\x1b[B", 4),
                                               ("up", b"\x1b[A", 4),
                                               ("cancel", b"\x03", 0.5),
                                               ("confirm-cancel", b"\x03", 10)]
                if repeat:
                    steps += [("down-again", b"\x1b[B", 4), ("up-again", b"\x1b[A", 4)]
                for label, keys, duration in steps:
                    if keys and process.poll() is None:
                        os.write(master, keys)
                    data = bytearray()
                    deadline = time.monotonic() + duration
                    while time.monotonic() < deadline:
                        if select.select([master], [], [], 0.2)[0]:
                            chunk = os.read(master, 65536)
                            if not chunk:
                                break
                            data.extend(chunk)
                            transcript.write(chunk)
                            transcript.flush()
                            # Standard terminal capability replies, no user consent.
                            if b"\x1b[6n" in chunk:
                                os.write(master, b"\x1b[1;1R")
                            if b"\x1b[c" in chunk:
                                os.write(master, b"\x1b[?1;2c")
                            if label == "initial" and b"Select login method:" in data and b"Navigate" in data:
                                break
                        elif process.poll() is not None:
                            break
                    phases.append({"phase": label, "bytes": len(data),
                                   "text": data.decode(errors="replace"), "host_exit": process.poll()})
                (output / f"{prefix}-phases.json").write_text(json.dumps(phases, indent=2))
                # Collection alone does not establish a functional UI. Fail if no
                # output was produced after navigation or the host never returned.
                if ("Select login method:" not in phases[0]["text"] or
                        not all("\x1b" in p["text"] for p in phases[:3])):
                    raise RuntimeError("Original TUI did not redraw in all navigation phases")
                if repeat:
                    assert "Select login method:" in phases[4]["text"], "Original UI did not reopen"
                    assert all("\x1b" in p["text"] for p in phases[5:]), "Reopened UI did not redraw"
                    assert process.poll() is None, "Host exited during second UI session"
                    return
                if process.wait(timeout=15) != 0:
                    raise RuntimeError("Host failed after canceling the original TUI")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                # A clean HOME contains no credentials; preserve only diagnostic logs.
                for number, path in enumerate(root.rglob("*.log")):
                    shutil.copyfile(path, output / f"{prefix}-engine-{number}.txt")
                os.close(master)
                os.close(slave)


if __name__ == "__main__":
    repeat = "--repeat-tui" in sys.argv
    linux = sys.argv[3] if len(sys.argv) > 3 and not repeat else None
    observe(sys.argv[1], Path(sys.argv[2]).resolve(), linux, repeat)
