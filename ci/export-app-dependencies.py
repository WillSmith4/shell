#!/usr/bin/env python3
"""Run inside full a-Shell to export its immutable build dependencies only."""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import tarfile


def main():
    app = Path(os.environ['APPDIR']).resolve()
    if app.suffix != '.app':
        raise SystemExit('APPDIR must identify the installed application bundle.')
    with (app / 'Info.plist').open('rb') as source:
        info = plistlib.load(source)
    if 'a-shell' not in info.get('CFBundleIdentifier', '').lower():
        raise SystemExit('This is not an a-Shell bundle.')
    if not (app / 'Library/lib/python3.13').is_dir() or not (app / 'Frameworks/Python.framework').is_dir():
        raise SystemExit('The installed full app must contain Python 3.13 and its framework.')
    output = Path(sys.argv[1] if len(sys.argv) > 1 else 'a-shell-build-dependencies.tar.gz').resolve()
    if output.exists():
        raise SystemExit(f'Refusing to overwrite {output}')
    manifest = json.dumps({
        'bundle_id': info['CFBundleIdentifier'],
        'version': info.get('CFBundleShortVersionString'),
        'build': info.get('CFBundleVersion'),
        'contents': ['Frameworks', 'Library'],
        'source': 'immutable installed app bundle; no Documents, preferences or account files',
    }, indent=2).encode()
    # No user HOME, Documents, shared app group, login or session directories.
    with tarfile.open(output, 'x:gz', compresslevel=1) as archive:
        for name in ('Frameworks', 'Library'):
            print(f'Adding app bundle {name}...', flush=True)
            archive.add(app / name, arcname='.build/installed-app/' + name)
        entry = tarfile.TarInfo('.build/installed-app/manifest.json')
        entry.size = len(manifest)
        archive.addfile(entry, io.BytesIO(manifest))
    digest = hashlib.sha256()
    with output.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    print(output)
    print('SHA256:', digest.hexdigest())
    print('App:', info.get('CFBundleShortVersionString'), 'build', info.get('CFBundleVersion'))


if __name__ == '__main__':
    main()
