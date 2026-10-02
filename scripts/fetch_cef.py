#!/usr/bin/env python3
"""Fetch the pinned CEF distribution into the project's ignored dependency folder."""
import hashlib
import json
import platform
from pathlib import Path
import tarfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = json.loads((ROOT / 'dependencies.json').read_text())['cef']
if platform.machine() != 'arm64' or platform.system() != 'Darwin':
    raise SystemExit('This first build targets Apple-silicon macOS.')
deps = ROOT / '.deps'
deps.mkdir(exist_ok=True)
archive = deps / spec['archive']
cef = deps / 'cef'
if cef.exists() and (cef / 'include/cef_version.h').exists():
    print(cef)
    raise SystemExit(0)
if not archive.exists():
    temporary = archive.with_suffix('.partial')
    url = spec['source'] + urllib.parse.quote(spec['archive'])
    print('Downloading pinned CEF framework...', flush=True)
    with urllib.request.urlopen(url) as response, temporary.open('wb') as target:
        size = 0
        checkpoint = 0
        while chunk := response.read(1024 * 1024):
            target.write(chunk)
            size += len(chunk)
            if size // (32 * 1024 * 1024) > checkpoint:
                checkpoint = size // (32 * 1024 * 1024)
                print(f'{size // (1024 * 1024)} MiB downloaded', flush=True)
    temporary.rename(archive)
digest = hashlib.sha1()
with archive.open('rb') as source:
    while chunk := source.read(1024 * 1024):
        digest.update(chunk)
if digest.hexdigest() != spec['sha1']:
    raise SystemExit('CEF archive checksum mismatch; refusing to extract.')
print('Checksum verified. Extracting...', flush=True)
with tarfile.open(archive) as source:
    top = source.getnames()[0].split('/')[0]
    source.extractall(deps, filter='data')
extracted = deps / top
extracted.rename(cef)
print(cef)
