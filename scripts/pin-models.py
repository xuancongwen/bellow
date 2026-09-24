#!/usr/bin/env python3
"""Regenerate Resources/models.json from downloaded model files.

    ./scripts/pin-models.py <tier> <weights.gguf> <whisper.bin> > Resources/models.json

<tier> is a name from the "tiers" list (max, standard). The tier's Modelfile in Resources/ (copied
byte-for-byte from voxtype-llm-wrapper) carries "# gguf: URL" and "# sha256: HASH" lines for its
base weights; this script takes the URL from there, re-hashes the downloaded file, checks it against
the Modelfile's hash, and pins URL, checksum, and size. Whisper is re-hashed the same way.
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

def pin(tier, gguf, whisper, current, resources=ROOT / 'Resources'):
    gguf, whisper = pathlib.Path(gguf), pathlib.Path(whisper)
    spec = json.loads(json.dumps(current))
    cleanup = next((t.get('cleanup') for t in spec['tiers'] if t['name'] == tier), None)
    if cleanup is None: raise ValueError(f'Tier {tier!r} has no cleanup entry to pin')
    text = (pathlib.Path(resources) / cleanup['modelfile']).read_text()
    url = re.search(r'^# gguf:\s+(\S+)', text, re.M)
    want = re.search(r'^# sha256:\s+([0-9a-f]{64})', text, re.M)
    base = re.search(r'^FROM\s+(\S+)', text, re.M)
    if not (url and want and base): raise ValueError(f'{cleanup["modelfile"]} lacks the FROM, "# gguf:", or "# sha256:" line')
    if base.group(1) != 'models/' + url.group(1).rsplit('/', 1)[1]: raise ValueError(f'{cleanup["modelfile"]}: FROM does not name the downloaded file')
    digest = sha256(gguf)
    if digest != want.group(1): raise ValueError(f'Corrupt weights: {gguf} hashes to {digest}, Modelfile expects {want.group(1)}')
    cleanup['url'] = url.group(1)
    cleanup['sha256'] = digest
    cleanup['bytes'] = gguf.stat().st_size
    spec['whisper']['sha256'] = sha256(whisper)
    spec['whisper']['bytes'] = whisper.stat().st_size
    return spec

if __name__ == '__main__':
    if len(sys.argv) != 4: raise SystemExit(__doc__)
    current = json.loads((ROOT / 'Resources/models.json').read_text())
    print(json.dumps(pin(sys.argv[1], sys.argv[2], sys.argv[3], current), indent=2))
