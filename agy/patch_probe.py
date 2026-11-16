"""Pinned, experimental Mach-O retargeting; not an a-Shell command yet."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from embedded_image import library_commands

SHA256 = 'fad3628ad91fe8613a72f074a1c5fde7cd816517788a5b9be96703f7d256741a'

def patch(source, destination, platform, embedded=False):
    data = bytearray(source.read_bytes())
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError('Only the audited agy 1.5.9 macOS arm64 binary is accepted')
    magic, cpu, _, filetype, count, size, _, _ = struct.unpack_from('<8I', data)
    assert (magic, cpu, filetype) == (0xfeedfacf, 0x100000c, 2)
    commands = []
    changes = []
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
            if new != old:
                encoded = new.encode() + b'\0'
                assert len(encoded) <= length - name_offset
                block[name_offset:] = encoded.ljust(length - name_offset, b'\0')
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
    a = p.parse_args()
    patch(a.source, a.destination, a.platform, a.embedded)
