#!/usr/bin/env python3
"""Check Mallard's signing setup without using any Keychain item, so it never asks for a password."""
import re
import subprocess
import sys
from development_signing import ROOT, load_identity

signing = load_identity()
app = ROOT / 'build/Mallard.app'
problems = []

# The built app should carry the saved identity, not an ad-hoc signature.
result = subprocess.run(['codesign', '-d', '-r-', str(app)], capture_output=True, text=True)
requirement = re.search(r'^designated => (.+)$', result.stdout + result.stderr, re.M)
if not requirement:
    problems.append('build/Mallard.app is missing or unsigned. Build it first: python3 scripts/build.py')
elif f'certificate leaf = h"{signing["identity"].lower()}"' not in requirement.group(1).lower():
    problems.append('build/Mallard.app is not signed with the saved Mallard Development identity.')

# codesign runs in the apple: partition. Without it on the key, every signature asks for the login password.
dump = subprocess.run(['security', 'dump-keychain', '-a', signing['keychain']], capture_output=True, text=True).stdout
partitions = None
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
print('build/Mallard.app is signed with the saved identity.')
if 'apple:' in partitions:
    print('codesign can use the key without asking.')
else:
    print('codesign will ask for your login password on each signature until you pick Always Allow on one of those prompts.')
print('self-signed builds have no team ID, so macOS asks about Chromium Safe Storage once after each rebuild. Always Allow covers that build.')
