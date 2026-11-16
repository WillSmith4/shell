"""Pinned, experimental Mach-O retargeting; not an a-Shell command yet."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from embedded_image import library_commands

SHA256 = 'fad3628ad91fe8613a72f074a1c5fde7cd816517788a5b9be96703f7d256741a'

def patch(source, destination, platform, embedded=False, tui_loop=False, tui_gate=False, app=False):
    data = bytearray(source.read_bytes())
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError('Only the audited agy 1.5.9 macOS arm64 binary is accepted')
    magic, cpu, _, filetype, count, size, _, _ = struct.unpack_from('<8I', data)
    assert (magic, cpu, filetype) == (0xfeedfacf, 0x100000c, 2)
    commands = []
    changes = []
    if app:
        if not embedded or not tui_gate:
            raise ValueError('App build requires the embedded TUI gate')
        # Give Go private stdin/stdout/stderr and two stream handles owned by
        # the TUI. termio may redirect its stdout/stderr without replacing
        # process descriptors 0..2. command.m reserves these slots atomically.
        for off, old, register, fd in [
            (0x100834, '609743f9', 0, 96), (0x100870, '603f45f9', 0, 97),
            (0x1008ac, '604345f9', 0, 98),
            (0x1eddac, '610880d2', 0, 99), (0x1ede50, '610880d2', 0, 100),
        ]:
            if data[off:off+4] != bytes.fromhex(old):
                raise ValueError(f'Stdio instruction mismatch at {off:#x}')
            struct.pack_into('<I', data, off, 0xd2800000 | (fd << 5) | register)
        for off, old in [(0x1eddb0, 'e2031faa07faff97'), (0x1ede54, 'e2031faadef9ff97')]:
            if data[off:off+8] != bytes.fromhex(old):
                raise ValueError('Unexpected terminal duplication call')
            struct.pack_into('<II', data, off, 0xaa1f03e1, 0xd503201f)  # nil error, no duplicate
        changes.append('Application-owned terminal descriptors')
        # The host gate reuses main.main's language server on every UI launch.
        # On normal interactive exit, launchCLI closes its per-session store
        # and backend, then calls the process-wide server shutdown callback.
        # Keep the former cleanup and the deferred cleanup after the callback.
        # The shared CascadeManager must remain usable until the app exits.
        shutdown = 0x31e3b8c
        if data[shutdown:shutdown+12] != bytes.fromhex('1a8c40f9400340f900003fd6'):
            raise ValueError('Unexpected interactive CLI server shutdown callback')
        struct.pack_into('<I', data, shutdown, 0x14000003)  # b .+12
        changes.append('Keep the shared language server alive between interactive invocations')
    if tui_gate:
        if not embedded or tui_loop:
            raise ValueError('TUI gate requires embedded mode without the immediate-loop experiment')
        at = 0x103229ce4 - 0x100000000
        expected = bytes.fromhex('e00342f9e1031faac1bb37973b0c05b0')
        if data[at:at + 16] != expected:
            raise ValueError('Unexpected TUI-return instructions')
        # Reuse the original main frame and its existing call-site metadata.
        # syscall.Kill(INT_MIN, 0) is intercepted only by this engine's AgyLibC;
        # it parks the Go syscall until the host requests another invocation.
        call_pc = 0x103229cec
        kill_pc = 0x1000a3840
        instructions = [0x52b00000, 0xaa1f03e1,
                        0x94000000 | (((kill_pc - call_pc) // 4) & 0x03ffffff),
                        0x14000000 | (((0x103229cac - 0x103229cf0) // 4) & 0x03ffffff)]
        struct.pack_into('<4I', data, at, *instructions)
        changes.append('Experimental host-controlled TUI rendezvous in the existing Go runtime')
    if tui_loop:
        if not embedded:
            raise ValueError('The TUI reentry experiment requires the isolated embedded host')
        # main.main already owns the Go runtime and in-process server. After the
        # original UI returns, reuse its existing argument setup and call site.
        # No extra Go frame or runtime initialization is introduced. This probe
        # intentionally loops; it does not implement returning to the app shell.
        at = 0x103229ce4 - 0x100000000
        if data[at:at + 4] != bytes.fromhex('e00342f9'):
            raise ValueError('Unexpected instruction following MaybeLaunchCLI')
        struct.pack_into('<I', data, at, 0x14000000 | ((-0x38 // 4) & 0x03ffffff))
        changes.append('Experimental loop through original MaybeLaunchCLI without restarting Go')
    signature_offset = None
    offset = 32
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, offset)
        block = bytearray(data[offset:offset + length])
        if cmd == 0x32:
            struct.pack_into('<III', block, 8, platform, 17 << 16, 17 << 16)
            changes.append('LC_BUILD_VERSION: iOS' if platform == 2 else 'LC_BUILD_VERSION: iOS Simulator')
        elif cmd == 12:
            name_offset, = struct.unpack_from('<I', block, 8)
            old = block[name_offset:block.index(0, name_offset)].decode()
            new = old.replace('/Versions/A/', '/').replace('/Versions/C/', '/')
            if any(x in old for x in ['/CoreServices.framework/', '/IOKit.framework/', '/Security.framework/']):
                new = '@executable_path/libAgyProbe.dylib'
            if embedded and old == '/usr/lib/libSystem.B.dylib':
                new = '@loader_path/AgyLibC'
            if app and new == '@loader_path/AgyLibC':
                new = '@rpath/AgC.framework/AgC'
            if app and new == '@executable_path/libAgyProbe.dylib':
                new = '@rpath/AgCompat.framework/AgCompat'
            if new != old:
                encoded = new.encode() + b'\0'
                new_size = max(length, (name_offset + len(encoded) + 7) & ~7)
                struct.pack_into('<I', block, 4, new_size)
                block[name_offset:] = encoded.ljust(new_size - name_offset, b'\0')
                changes.append({'dependency': old, 'replacement': new})
        elif cmd == 0x1d:
            signature_offset, = struct.unpack_from('<I', block, 8)
            # codesign will generate a fresh ad-hoc signature after all patches.
            changes.append('Remove old code-signature load command')
            offset += length
            continue
        commands.append(block)
        offset += length
    assert offset == 32 + size
    if embedded:
        commands = library_commands(data, commands, signature_offset)
        changes.append('Convert executable to an embedded dynamic library')
    rebuilt = b''.join(commands)
    if len(rebuilt) > size:
        raise ValueError('Rebuilt load commands exceed the original header space')
    data[32:32 + size] = rebuilt.ljust(size, b'\0')
    struct.pack_into('<II', data, 16, len(commands), len(rebuilt))
    destination.write_bytes(data)
    destination.chmod(0o755)
    print(json.dumps({'source_sha256': SHA256, 'output_sha256': hashlib.sha256(data).hexdigest(),
                      'platform': platform, 'changes': changes}, indent=2))

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('source', type=Path)
    p.add_argument('destination', type=Path)
    p.add_argument('--platform', type=int, choices=[2, 7], default=7)
    p.add_argument('--embedded', action='store_true')
    p.add_argument('--tui-loop', action='store_true')
    p.add_argument('--tui-gate', action='store_true')
    p.add_argument('--app', action='store_true')
    a = p.parse_args()
    patch(a.source, a.destination, a.platform, a.embedded, a.tui_loop, a.tui_gate, a.app)
