#!/usr/bin/env python3
"""Check Mallard's signing setup without using any Keychain item, so it never asks for a password."""
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from development_signing import ROOT, load_identity

signing = load_identity()
app = ROOT / 'build/Mallard.app'
problems = []

# The built app should carry the saved certificate, not an ad-hoc signature.
team = None
with tempfile.TemporaryDirectory(prefix='signing-check-') as temporary:
    prefix = Path(temporary) / 'certificate'
    result = subprocess.run(['codesign', '-dv', f'--extract-certificates={prefix}', str(app)], capture_output=True, text=True)
    leaf = Path(f'{prefix}0')
    if result.returncode or not leaf.exists():
        problems.append('build/Mallard.app is missing or unsigned. Build it first: python3 scripts/build.py')
    elif hashlib.sha1(leaf.read_bytes()).hexdigest().upper() != signing['identity']:
        problems.append('build/Mallard.app is not signed with the saved identity in .local/signing.json.')
    found = re.search(r'^TeamIdentifier=(.+)$', result.stderr, re.M)
    if found and found.group(1) != 'not set':
        team = found.group(1)

# codesign runs in the apple: partition. Without it on the self-signed key, every signature asks for the login password.
partitions = None
if not signing.get('name', '').startswith('Apple Development'):
    dump = subprocess.run(['security', 'dump-keychain', '-a', signing['keychain']], capture_output=True, text=True).stdout
    for block in dump.split('keychain: ')[1:]:
        if 'class: 0x00000010' in block and '="Mallard Development"' in block:
            found = re.search(r'partition_id\s+(?:don\'t-require-password\s+)?description: ([^\n]+)', block)
            partitions = [item.strip() for item in found.group(1).split(',')] if found else []
    if partitions is None:
        problems.append('The Mallard Development private key was not found in Keychain.')

for problem in problems:
    print(problem)
if problems:
    sys.exit(1)
print(f'build/Mallard.app is signed with {signing.get("name", "Mallard Development")}.')
if partitions is not None:
    print('codesign can use the key without asking.' if 'apple:' in partitions else 'codesign will ask for your login password on each signature until you pick Always Allow on one of those prompts.')
if team:
    print(f'team ID {team} stays the same between builds, so Keychain access carries over after a rebuild.')
else:
    print('self-signed builds have no team ID, so macOS asks about Chromium Safe Storage once after each rebuild. Always Allow covers that build.')
