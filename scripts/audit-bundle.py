#!/usr/bin/env python3
"""Fail a release with missing resources, foreign dylibs, or a model spec that does not match the Modelfile."""
import json
import pathlib
import re
import subprocess
import sys
app = pathlib.Path(sys.argv[1]).resolve()
res = app / 'Contents/Resources'
for name in ['bin/voxtype', 'ollama/ollama', 'Modelfile', 'models.json']:
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
spec = json.loads((res / 'models.json').read_text())
if not re.fullmatch(r'[0-9a-f]{64}', spec['whisper']['sha256']): raise SystemExit('Bad Whisper checksum in models.json')
if not spec['cleanup']['digests'] or any(not re.fullmatch(r'sha256:[0-9a-f]{64}', d) for d in spec['cleanup']['digests']):
    raise SystemExit('Bad model digests in models.json')
base = re.search(r'^FROM\s+(\S+)', (res / 'Modelfile').read_text(), re.M).group(1)
if base != spec['cleanup']['model']: raise SystemExit(f'Modelfile builds on {base} but models.json pins {spec["cleanup"]["model"]}')
print('Bundle resources, linked libraries, and model spec verified.')
