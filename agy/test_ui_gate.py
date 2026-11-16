"""Require three original-TUI invocations with host control between them."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
from probe_cleanup import stop_probe


def main(device, output, pipes=False, command=False):
    prefix = 'app-command' if command else 'pipe-gate' if pipes else 'tui-gate'
    with tempfile.TemporaryDirectory(dir=output) as directory:
        root = Path(directory)
        control_path = root / "control"
        os.mkfifo(control_path, 0o600)
        control = os.open(control_path, os.O_RDWR)
        if pipes:
            input_path, output_path, host_path = root / 'input', root / 'output', root / 'host-input'
            inputs = [root / f'input-{n}' for n in (1, 2, 3)] if command else [input_path]
            outputs = [root / f'output-{n}' for n in (1, 2, 3)] if command else [output_path]
            for path in (*inputs, *outputs, host_path):
                os.mkfifo(path, 0o600)
            host_input = os.open(host_path, os.O_RDWR)
            os.write(host_input, b'HHH')
            writers = [os.open(p, os.O_RDWR) for p in inputs]
            masters = [os.open(p, os.O_RDWR) for p in outputs]
            writer, master = writers[0], masters[0]
            slave = None
            terminal_args = ['pipe-gate', str(input_path), str(control_path), str(output_path), str(host_path)]
        else:
            master, slave = pty.openpty()
            writer = master
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
            terminal_args = ['tui-gate', os.ttyname(slave), str(control_path)]
        env = os.environ.copy()
        for key in list(env):
            if any(s in key.upper() for s in ("API_KEY", "AUTH_TOKEN", "ACCESS_TOKEN", "GOOGLE_APPLICATION_CREDENTIALS")):
                del env[key]
        for key, value in {"HOME": str(root), "XDG_CONFIG_HOME": str(root / "config"),
                           "XDG_CACHE_HOME": str(root / "cache"), "TERM": "xterm-256color",
                           "AGY_CLI_DISABLE_AUTO_UPDATE": "true"}.items():
            env["SIMCTL_CHILD_" + key] = value
        log_path = output / f"{prefix}-host.txt"
        phases = []
        with log_path.open("w") as log, (output / f"{prefix}-terminal.txt").open("wb") as terminal:
            executable = output / ("test-command" if command else "test-load")
            args = terminal_args[1:] if command else [str(output / "AgyEngineGate"), *terminal_args]
            process = subprocess.Popen(["xcrun", "simctl", "spawn", device, str(executable), *args],
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
                            os.write(writer, b"\x1b[1;1R")
                        if b"\x1b[c" in chunk:
                            os.write(writer, b"\x1b[?1;2c")
                    if until and until(data):
                        break
                    if process.poll() is not None:
                        break
                phases.append({"phase": label, "text": data.decode(errors="replace")})
                (output / f"{prefix}-phases.json").write_text(json.dumps(phases, indent=2))
                return data

            try:
                server_port = None
                for attempt in range(1, 4):
                    if command:
                        master, writer = masters[attempt - 1], writers[attempt - 1]
                    if attempt > 1:
                        os.write(control, b"R")
                    screen = read_phase(f"open-{attempt}", 90,
                                        lambda data: b"Select login method:" in data and b"Navigate" in data)
                    assert b"Select login method:" in screen, f"No original menu on invocation {attempt}"
                    if command and server_port is None:
                        for path in root.rglob("*.log"):
                            match = re.search(r"Language server listening on random port at (\d+) for HTTP\b",
                                              path.read_text(errors="replace"))
                            if match:
                                server_port = int(match[1])
                                break
                        assert server_port, "Missing the embedded language server's HTTP port"
                    for name, key in [("down", b"\x1b[B"), ("up", b"\x1b[A")]:
                        os.write(writer, key)
                        redraw = read_phase(f"{name}-{attempt}", 1)
                        assert b"\x1b" in redraw and b">" in redraw, f"No selection redraw: {name}-{attempt}"
                    os.write(writer, b"\x03")
                    read_phase(f"cancel-{attempt}", 0.3)
                    os.write(writer, b"\x03")
                    marker = f"HOST-COMMAND-OK {attempt}"
                    tail = read_phase(f"return-{attempt}", 30, lambda data: marker in log_path.read_text() and (not command or b'1.5.9' in data))
                    if command:
                        assert b'1.5.9' in tail, "Version missing after UI exit"
                    assert marker in log_path.read_text(), f"Host did not regain control after invocation {attempt}"
                    if command and attempt < 3:
                        # Returning to the shell used to shut down this server.
                        # The next TUI still opened, but could not start a conversation.
                        with socket.create_connection(("localhost", server_port), timeout=3):
                            pass
                    if attempt < 3:
                        idle = read_phase(f"idle-{attempt}", 1)
                        assert b"Select login method:" not in idle, "UI reopened without a host request"
                        assert process.poll() is None, "Host terminated between invocations"
                assert process.wait(timeout=15) == 0, "Test host failed at completion"
                if not command:
                    assert log_path.read_text().count("Command thread ") == 1, "Runtime entry was called more than once"
            finally:
                if process.poll() is None:
                    stop_probe(process, log_path, executable)
                for number, path in enumerate(root.rglob("*.log")):
                    shutil.copyfile(path, output / f"{prefix}-engine-{number}.txt")
                os.close(control)
                if pipes:
                    for fd in masters + writers: os.close(fd)
                else:
                    os.close(master)
                if slave is not None: os.close(slave)
                if pipes: os.close(host_input)


if __name__ == "__main__":
    main(sys.argv[1], Path(sys.argv[2]).resolve(), '--pipes' in sys.argv or '--command' in sys.argv, '--command' in sys.argv)
