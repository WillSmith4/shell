"""Require three original-TUI invocations with host control between them."""
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


def main(device, output):
    with tempfile.TemporaryDirectory(dir=output) as directory:
        root = Path(directory)
        control_path = root / "control"
        os.mkfifo(control_path, 0o600)
        control = os.open(control_path, os.O_RDWR)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
        env = os.environ.copy()
        for key in list(env):
            if any(s in key.upper() for s in ("API_KEY", "AUTH_TOKEN", "ACCESS_TOKEN", "GOOGLE_APPLICATION_CREDENTIALS")):
                del env[key]
        for key, value in {"HOME": str(root), "XDG_CONFIG_HOME": str(root / "config"),
                           "XDG_CACHE_HOME": str(root / "cache"), "TERM": "xterm-256color"}.items():
            env["SIMCTL_CHILD_" + key] = value
        log_path = output / "tui-gate-host.txt"
        phases = []
        with log_path.open("w") as log, (output / "tui-gate-terminal.txt").open("wb") as terminal:
            process = subprocess.Popen(["xcrun", "simctl", "spawn", device, str(output / "test-load"),
                                        str(output / "AgyEngineGate"), "tui-gate", os.ttyname(slave), str(control_path)],
                                       stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=env, cwd=root)

            def read_phase(label, seconds, until=None):
                data = bytearray()
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.1)[0]:
                        chunk = os.read(master, 65536)
                        data.extend(chunk)
                        terminal.write(chunk)
                        terminal.flush()
                        if b"\x1b[6n" in chunk:
                            os.write(master, b"\x1b[1;1R")
                        if b"\x1b[c" in chunk:
                            os.write(master, b"\x1b[?1;2c")
                    if until and until(data):
                        break
                    if process.poll() is not None:
                        break
                phases.append({"phase": label, "text": data.decode(errors="replace")})
                (output / "tui-gate-phases.json").write_text(json.dumps(phases, indent=2))
                return data

            try:
                for attempt in range(1, 4):
                    if attempt > 1:
                        os.write(control, b"R")
                    screen = read_phase(f"open-{attempt}", 90,
                                        lambda data: b"Select login method:" in data and b"Navigate" in data)
                    assert b"Select login method:" in screen, f"No original menu on invocation {attempt}"
                    for name, key in [("down", b"\x1b[B"), ("up", b"\x1b[A")]:
                        os.write(master, key)
                        redraw = read_phase(f"{name}-{attempt}", 1)
                        assert b"\x1b" in redraw and b">" in redraw, f"No selection redraw: {name}-{attempt}"
                    os.write(master, b"\x03")
                    read_phase(f"cancel-{attempt}", 0.3)
                    os.write(master, b"\x03")
                    marker = f"HOST-COMMAND-OK {attempt}"
                    read_phase(f"return-{attempt}", 30, lambda data: marker in log_path.read_text())
                    assert marker in log_path.read_text(), f"Host did not regain control after invocation {attempt}"
                    if attempt < 3:
                        idle = read_phase(f"idle-{attempt}", 1)
                        assert b"Select login method:" not in idle, "UI reopened without a host request"
                        assert process.poll() is None, "Host terminated between invocations"
                assert process.wait(timeout=15) == 0, "Test host failed at completion"
                assert log_path.read_text().count("Command thread ") == 1, "Runtime entry was called more than once"
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                for number, path in enumerate(root.rglob("*.log")):
                    shutil.copyfile(path, output / f"tui-gate-engine-{number}.txt")
                os.close(control)
                os.close(master)
                os.close(slave)


if __name__ == "__main__":
    main(sys.argv[1], Path(sys.argv[2]).resolve())
