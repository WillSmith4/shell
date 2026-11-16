"""Exercise the native engine over ACP in one disposable Simulator host."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
from probe_cleanup import stop_probe


def exchange(writer, reader, request, process):
    writer.write((json.dumps(request) + "\n").encode())
    deadline = time.monotonic() + 120
    pending = bytearray()
    while time.monotonic() < deadline:
        if not select.select([reader], [], [], 1)[0]:
            if process.poll() is not None:
                raise RuntimeError(f"host exited before reply {request['id']}")
            continue
        pending.extend(reader.read(65536))
        while b"\n" in pending:
            line, _, remainder = pending.partition(b"\n")
            pending = bytearray(remainder)
            message = json.loads(line)
            if message.get("id") == request["id"]:
                return message
    raise TimeoutError(f"no reply to {request['method']}")


def main(device, output):
    with tempfile.TemporaryDirectory(dir=output) as root:
        root = Path(root)
        incoming, outgoing = root / "requests", root / "responses"
        for path in (incoming, outgoing):
            os.mkfifo(path, 0o600)
        # Open before launch so startup never blocks on the other end of a FIFO.
        with os.fdopen(os.open(incoming, os.O_RDWR), "wb", buffering=0) as writer, \
                os.fdopen(os.open(outgoing, os.O_RDWR), "rb", buffering=0) as reader, \
                (output / "acp-host.txt").open("w") as host_log, \
                (output / "acp-replies.txt").open("w") as replies:
            command = ["xcrun", "simctl", "spawn", device, str(output / "test-load"),
                       str(output / "AgyEngine"), "acp", str(incoming), str(outgoing)]
            process = subprocess.Popen(command, stdout=host_log, stderr=host_log)
            try:
                for number, method, params in [
                    (1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}}),
                    (2, "session/new", {"cwd": str(root), "mcpServers": []}),
                    (3, "session/new", {"cwd": str(root), "mcpServers": []}),
                ]:
                    result = exchange(writer, reader, {"jsonrpc": "2.0", "id": number,
                                      "method": method, "params": params}, process)
                    if number == 1:
                        info = result["result"]["agentInfo"]
                        assert info["name"] == "Antigravity ACP Server" and info["version"] == "1.5.9", info
                        print(info, file=replies, flush=True)
                    else:
                        # A clean simulator has no account. Require the real auth
                        # boundary on both requests; never report a session opened.
                        error = result["error"]
                        print(number, error, file=replies, flush=True)
                        assert error["code"] == -32000 and "authentication required" in error["message"].lower(), error
                writer.close()
                if process.wait(timeout=30) != 0:
                    raise RuntimeError("host failed after ACP EOF")
                assert "Host resumed after agy 1" in (output / "acp-host.txt").read_text()
            finally:
                if process.poll() is None:
                    stop_probe(process, output / "acp-host.txt", output / "test-load")


if __name__ == "__main__":
    main(sys.argv[1], Path(sys.argv[2]).resolve())
