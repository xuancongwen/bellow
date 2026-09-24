#!/usr/bin/env python3
"""Fail a release with missing resources, foreign dylibs, or a model spec that does not match the Modelfile."""
import json
import pathlib
import re
import subprocess
import sys
app = pathlib.Path(sys.argv[1]).resolve()
res = app / 'Contents/Resources'
for name in ['bin/voxtype', 'ollama/ollama', 'ollama/llama-server', 'ollama/LLAMA_CPP_LICENSE', 'models.json', 'AppIcon.icns', 'licenses/THIRD-PARTY-NOTICES.md', 'licenses/VOXTYPE-CRATES.txt',
             'licenses/BELLOW-LICENSE', 'licenses/VOXTYPE-LICENSE', 'licenses/WHISPER-CPP-LICENSE', 'licenses/OLLAMA-LICENSE',
             'licenses/WHISPER-LICENSE', 'licenses/QWEN-LICENSE']:
    if not (res / name).is_file(): raise SystemExit(f'Missing bundle resource: {name}')
for file in app.rglob('*'):
    if file.is_symlink() and not file.exists(): raise SystemExit(f'Dangling symlink in bundle: {file}')
    if not file.is_file(): continue
    kind = subprocess.check_output(['file', '-b', str(file)], text=True)
    if 'Mach-O' not in kind: continue
    if 'arm64' not in subprocess.check_output(['lipo', '-archs', str(file)], text=True): raise SystemExit(f'Non-arm64 Mach-O in bundle: {file.name}')
    linked = subprocess.check_output(['otool', '-L', str(file)], text=True).splitlines()[1:]
    for line in linked:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith('/') and not dependency.startswith(('/System/', '/usr/lib/')):
            raise SystemExit(f'Nonportable dependency in {file.name}: {dependency}')
spec = json.loads((res / 'models.json').read_text())
if not re.fullmatch(r'[0-9a-f]{64}', spec['whisper']['sha256']): raise SystemExit('Bad Whisper checksum in models.json')
pinned = [t for t in spec['tiers'] if t.get('cleanup')]
if not pinned: raise SystemExit('models.json pins no cleanup model for any tier')
for tier in pinned:
    cleanup = tier['cleanup']
    if not re.fullmatch(r'[0-9a-f]{64}', cleanup['sha256']): raise SystemExit(f'Bad weights checksum for the {tier["name"]} tier in models.json')
    modelfile = res / cleanup['modelfile']
    if not modelfile.is_file(): raise SystemExit(f'Missing {cleanup["modelfile"]} for the {tier["name"]} tier')
    text = modelfile.read_text()
    base = re.search(r'^FROM\s+(\S+)', text, re.M).group(1)
    if base != 'models/' + cleanup['url'].rsplit('/', 1)[1]: raise SystemExit(f'{cleanup["modelfile"]} builds on {base} but models.json pins {cleanup["url"]}')
    if re.search(r'^# gguf:\s+(\S+)', text, re.M).group(1) != cleanup['url']: raise SystemExit(f'{cleanup["modelfile"]} names a different download URL than models.json')
    if re.search(r'^# sha256:\s+(\S+)', text, re.M).group(1) != cleanup['sha256']: raise SystemExit(f'{cleanup["modelfile"]} names a different checksum than models.json')
if (res / 'ollama').glob('*.so') and list((res / 'ollama').glob('*.so')): raise SystemExit('x86_64 CPU backends left in the Ollama directory')
if list((res / 'ollama').glob('mlx_metal_*')): raise SystemExit('MLX bundles left in the Ollama directory')
for line in (res / 'licenses/VOXTYPE-CRATES.txt').read_text().splitlines():
    license = line.split('|')[1]
    if re.search(r'GPL|SSPL|BUSL|Commons Clause|NC\b|proprietary', license, re.I) or license.strip() in ('', 'N/A'):
        raise SystemExit(f'Crate with a non-permissive or unknown license: {line}')
print('Bundle resources, linked libraries, licenses, and model spec verified.')
