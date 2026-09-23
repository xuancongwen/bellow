#!/usr/bin/env python3
"""Export only requested Ollama manifests/blobs; verify every blob digest."""
import hashlib
import json
import pathlib
import re
import shutil
import sys

def package(source, target):
    source, target = pathlib.Path(source), pathlib.Path(target)
    inventory = {}
    for name, tag in [('qwen2.5', '7b'), ('voxtype-llm-wrapper', 'latest')]:
        relative = pathlib.Path('manifests/registry.ollama.ai/library') / name / tag
        manifest = source / relative
        data = json.loads(manifest.read_text())
        output = target / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(manifest, output)
        inventory[str(relative)] = hashlib.sha256(manifest.read_bytes()).hexdigest()
        for layer in [data['config'], *data['layers']]:
            digest = layer['digest']
            if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
                raise ValueError('Invalid model digest')
            blob = source / 'blobs' / digest.replace(':', '-')
            hasher = hashlib.sha256()
            with blob.open('rb') as stream:
                for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''): hasher.update(chunk)
            if hasher.hexdigest() != digest[7:]: raise ValueError(f'Corrupt blob: {digest}')
            dest = target / 'blobs' / blob.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            if not dest.exists(): shutil.copy2(blob, dest)
            inventory[str(dest.relative_to(target))] = digest[7:]
    (target / 'inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')

if __name__ == '__main__': package(*sys.argv[1:])
