#!/usr/bin/env python3
"""Regenerate Resources/models.json from a local Ollama store and a Whisper model file.

    ./scripts/pin-models.py <ollama-store> <whisper.bin> > Resources/models.json

The store must already hold the base model (`ollama pull qwen2.5:7b` with OLLAMA_MODELS set
to it). Every referenced blob is re-hashed so the pinned digests are known to be genuine.
"""
import hashlib
import json
import pathlib
import re
import sys
ROOT = pathlib.Path(__file__).resolve().parents[1]

def sha256(path):
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''): hasher.update(chunk)
    return hasher.hexdigest()

def pin(store, whisper, current):
    store, whisper = pathlib.Path(store), pathlib.Path(whisper)
    spec = json.loads(json.dumps(current))
    name, _, tag = spec['cleanup']['model'].partition(':')
    manifest = json.loads((store / 'manifests/registry.ollama.ai/library' / name / (tag or 'latest')).read_text())
    digests, total = [], 0
    for layer in [manifest['config'], *manifest['layers']]:
        digest = layer['digest']
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest): raise ValueError('Invalid model digest')
        if sha256(store / 'blobs' / digest.replace(':', '-')) != digest[7:]: raise ValueError(f'Corrupt blob: {digest}')
        digests.append(digest); total += int(layer['size'])
    spec['cleanup']['digests'] = digests
    spec['cleanup']['bytes'] = total
    spec['whisper']['sha256'] = sha256(whisper)
    spec['whisper']['bytes'] = whisper.stat().st_size
    return spec

if __name__ == '__main__':
    current = json.loads((ROOT / 'Resources/models.json').read_text())
    print(json.dumps(pin(sys.argv[1], sys.argv[2], current), indent=2))
