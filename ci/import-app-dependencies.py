#!/usr/bin/env python3
"""Map exported device frameworks into the project's existing build references."""
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
export = root / '.build/installed-app'
manifest = json.loads((export / 'manifest.json').read_text())
print('Using installed full-app dependencies:', manifest['version'], 'build', manifest['build'])
project = json.loads(subprocess.check_output([
    'plutil', '-convert', 'json', '-o', '-', str(root / 'a-Shell.xcodeproj/project.pbxproj')
]))
shutil.copytree(export / 'Library', root / 'Resources/Library', dirs_exist_ok=True)
for item in project['objects'].values():
    if item.get('isa') != 'PBXFileReference' or item.get('sourceTree') == 'SDKROOT':
        continue
    relative = item.get('path', '')
    if not relative.endswith(('.framework', '.xcframework')) or '$(' in relative:
        continue
    target = (root / relative).resolve()
    if not target.is_relative_to(root):
        raise ValueError(f'Build reference escapes checkout: {relative}')
    if target.exists():
        continue
    source = export / 'Frameworks' / (target.stem + '.framework')
    if not source.is_dir():
        print('Not supplied by installed app:', relative)
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.suffix == '.framework':
        shutil.copytree(source, target)
    else:
        subprocess.run(['xcodebuild', '-create-xcframework', '-framework', str(source), '-output', str(target)], check=True)
