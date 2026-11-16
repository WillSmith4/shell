"""Terminate only the disposable Simulator host owned by a probe."""
import os
import re
import shlex
import signal
import subprocess
import time


def stop_probe(process, log_path, executable):
    # simctl is a launcher. Killing only the launcher can leave the actual Go
    # process running and writing into a TemporaryDirectory during cleanup.
    match = re.search(r'^Probe host pid (\d+)$', log_path.read_text(), re.MULTILINE)
    if match:
        pid = int(match.group(1))
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True)
        command = shlex.split(result.stdout.strip())
        if command and command[0] == str(executable):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
                if not state.stdout.strip() or state.stdout.strip().startswith('Z'):
                    break
                time.sleep(0.1)
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)
