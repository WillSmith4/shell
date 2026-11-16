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


def observe(device, output, linux=None):
    output.mkdir(parents=True, exist_ok=True)
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
                   str(output / "test-load"), str(output / "AgyEngine"), "tui", os.ttyname(slave)])
        phases = []
        with (output / "tui-host.txt").open("w") as log, (output / "tui-terminal.txt").open("wb") as transcript:
            process = subprocess.Popen(command, stdin=slave if linux else subprocess.DEVNULL,
                                       stdout=slave if linux else log, stderr=slave if linux else log,
                                       cwd=root, env=env, start_new_session=True,
                                       preexec_fn=(lambda: fcntl.ioctl(slave, termios.TIOCSCTTY, 0)) if linux else None)
            try:
                for label, keys, duration in [("initial", b"", 90),
                                               ("down", b"\x1b[B", 4),
                                               ("up", b"\x1b[A", 4),
                                               ("cancel", b"\x03", 5)]:
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
                        elif process.poll() is not None:
                            break
                    phases.append({"phase": label, "bytes": len(data),
                                   "text": data.decode(errors="replace"), "host_exit": process.poll()})
                (output / "tui-phases.json").write_text(json.dumps(phases, indent=2))
                # Collection alone does not establish a functional UI. Fail if no
                # output was produced after navigation or the host never returned.
                if not all("\x1b[" in p["text"] for p in phases[:3]):
                    raise RuntimeError("Original TUI did not redraw in all navigation phases")
                if process.wait(timeout=15) != 0:
                    raise RuntimeError("Host failed after canceling the original TUI")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                # A clean HOME contains no credentials; preserve only diagnostic logs.
                for number, path in enumerate(root.rglob("*.log")):
                    shutil.copyfile(path, output / f"tui-engine-{number}.txt")
                os.close(master)
                os.close(slave)


if __name__ == "__main__":
    observe(sys.argv[1], Path(sys.argv[2]).resolve(), sys.argv[3] if len(sys.argv) > 3 else None)
