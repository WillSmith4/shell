#!/usr/bin/env python3
"""Reject an AI command bundle whose actual Mach-O minimum exceeds iPadOS 17."""
import plistlib
from pathlib import Path
import re
import subprocess
import sys

app = Path(sys.argv[1])
def version(value):
    return tuple((list(map(int, value.split('.'))) + [0, 0, 0])[:3])

for framework in ('codex', 'node', 'ios_system'):
    root = app / 'Frameworks' / f'{framework}.framework'
    with (root / 'Info.plist').open('rb') as source:
        info = plistlib.load(source)
    minimum = version(info['MinimumOSVersion'])
    assert minimum <= (17, 0, 0), (framework, minimum)
    binary = root / info['CFBundleExecutable']
    output = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
    platforms = re.findall(r'^\s*platform\s+(\S+)', output, re.M)
    versions = re.findall(r'^\s*minos\s+([\d.]+)', output, re.M)
    assert platforms == ['IOS'] and len(versions) == 1, output
    assert version(versions[0]) <= (17, 0, 0), output
    print(f'{framework}: device minimum iOS {versions[0]}')
with (app / 'Info.plist').open('rb') as source:
    info = plistlib.load(source)
assert version(info['MinimumOSVersion']) <= (17, 0, 0)
