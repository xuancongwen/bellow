#!/usr/bin/env python3
"""Fail a release with missing models, foreign dylibs, or inconsistent model hashes."""
import hashlib
import json
import pathlib
import subprocess
import sys
app = pathlib.Path(sys.argv[1]).resolve()
res = app / 'Contents/Resources'
for name in ['bin/voxtype', 'ollama/ollama', 'whisper.bin', 'Modelfile', 'models/inventory.json']:
    if not (res / name).is_file(): raise SystemExit(f'Missing bundle resource: {name}')
for file in app.rglob('*'):
    if not file.is_file(): continue
    kind = subprocess.check_output(['file', '-b', str(file)], text=True)
    if 'Mach-O' not in kind: continue
    linked = subprocess.check_output(['otool', '-L', str(file)], text=True).splitlines()[1:]
    for line in linked:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith('/') and not dependency.startswith(('/System/', '/usr/lib/')):
            raise SystemExit(f'Nonportable dependency in {file.name}: {dependency}')
inventory = json.loads((res / 'models/inventory.json').read_text())
for name, expected in inventory.items():
    hasher = hashlib.sha256()
    with (res / 'models' / name).open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''): hasher.update(chunk)
    if hasher.hexdigest() != expected: raise SystemExit(f'Model digest mismatch: {name}')
print('Bundle resources, linked libraries, and model digests verified.')
