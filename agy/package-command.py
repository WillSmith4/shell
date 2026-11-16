"""Add the native agy frameworks to a separately signed a-Shell build."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile
import zipfile

APP = 'Payload/a-Shell.app/'
FRAMEWORKS = ('AgC', 'AgCompat', 'AgyEngine', 'agy')
DICTIONARY = APP + 'commandDictionary.plist'


def require_device_library(data, name):
    magic, cpu, _, kind, count = struct.unpack_from('<5I', data)
    if (magic, cpu, kind) != (0xfeedfacf, 0x100000c, 6):
        raise ValueError(f'{name} is not an ARM64 dynamic library')
    offset = 32
    for _ in range(count):
        cmd, size = struct.unpack_from('<II', data, offset)
        if cmd == 0x32 and struct.unpack_from('<II', data, offset + 8) == (2, 17 << 16):
            return
        offset += size
    raise ValueError(f'{name} is not built for an iOS 17 device')


def package(base, frameworks, destination):
    if destination.exists():
        raise FileExistsError(destination)
    with zipfile.ZipFile(base) as original, tempfile.TemporaryDirectory() as work, \
            tempfile.TemporaryDirectory(dir=destination.parent) as dest_dir:
        root = Path(work)
        additions = {}
        plist = plistlib.loads(original.read(DICTIONARY))
        if 'agy' in plist:
            raise ValueError('Input IPA already contains agy')
        spec = Path(__file__).resolve().parents[1] / 'Resources/commandDictionary.plist'
        plist['agy'] = plistlib.loads(spec.read_bytes())['agy']
        additions[DICTIONARY] = (plistlib.dumps(plist, fmt=plistlib.FMT_BINARY, sort_keys=False), 0o644)
        additions[APP + 'bin/agy'] = (b'', 0o644)
        with zipfile.ZipFile(frameworks) as built:
            for name in FRAMEWORKS:
                prefix = name + '.framework/'
                require_device_library(built.read(prefix + name), name)
                if plistlib.loads(built.read(prefix + 'Info.plist'))['CFBundleExecutable'] != name:
                    raise ValueError(f'Wrong executable in {name} Info.plist')
                for info in built.infolist():
                    if not info.filename.startswith(prefix) or info.is_dir():
                        continue
                    parts = info.filename.split('/')
                    if any(p in ('', '.', '..') for p in parts):
                        raise ValueError('Invalid framework archive path')
                    if not stat.S_ISREG(info.external_attr >> 16):
                        raise ValueError('Unexpected framework member type')
                    path = APP + 'Frameworks/' + info.filename
                    if path in additions or path in original.NameToInfo:
                        raise ValueError(f'Duplicate framework member: {path}')
                    additions[path] = (built.read(info), (info.external_attr >> 16) & 0o777)
        for path, (data, mode) in additions.items():
            target = root / path
            target.parent.mkdir(exist_ok=True, parents=True)
            target.write_bytes(data)
            target.chmod(mode)
        result = Path(dest_dir) / 'a-Shell.ipa'
        shutil.copyfile(base, result)
        subprocess.run(['zip', '-q', str(result), *additions], cwd=root, check=True)
        with zipfile.ZipFile(result) as packaged:
            names = packaged.namelist()
            if len(names) != len(set(names)) or set(names) != set(original.namelist()) | set(additions):
                raise ValueError('IPA member list mismatch')
            for src in original.infolist():
                if src.filename == DICTIONARY:
                    continue
                dst = packaged.getinfo(src.filename)
                if (src.CRC, src.file_size, src.external_attr) != (dst.CRC, dst.file_size, dst.external_attr):
                    raise ValueError(f'Existing IPA member changed: {src.filename}')
            for path, (data, mode) in additions.items():
                if packaged.read(path) != data or ((packaged.getinfo(path).external_attr >> 16) & 0o777) != mode:
                    raise ValueError(f'Incorrect data or permissions: {path}')
            damaged = packaged.testzip()
            if damaged:
                raise ValueError(f'CRC check failed: {damaged}')
        result.rename(destination)
        with destination.open('rb') as stream:
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1 << 20), b''):
                digest.update(block)
        print(f'{digest.hexdigest()}  {destination}')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('base', type=Path)
    ap.add_argument('frameworks', type=Path)
    ap.add_argument('destination', type=Path)
    args = ap.parse_args()
    package(args.base.resolve(), args.frameworks.resolve(), args.destination.resolve())
