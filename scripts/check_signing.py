#!/usr/bin/env python3
"""Check that a changed binary keeps access to its own test Keychain item."""
from pathlib import Path
import re
import subprocess
import tempfile
import uuid
from development_signing import ROOT, load_identity

signing = load_identity()
service = 'com.ewoudvv.Mallard.signing-test.' + str(uuid.uuid4())
(ROOT / 'build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='signing-check-', dir=ROOT / 'build') as temporary:
    binary = Path(temporary) / 'MallardSigningProbe'
    requirements, hashes = [], []
    created = False
    try:
        for revision in (1, 2):
            compiled = Path(temporary) / f'build-{revision}'
            subprocess.run(['clang', '-fobjc-arc', '-Wno-deprecated-declarations', '-framework', 'Foundation', '-framework', 'Security', f'-DPROBE_REVISION={revision}', str(ROOT / 'Tests/SigningProbe.m'), '-o', str(compiled)], check=True)
            subprocess.run(['codesign', '--force', '--sign', signing['identity'], '--keychain', signing['keychain'], '--timestamp=none', '--identifier', 'com.ewoudvv.Mallard.signing-check', str(compiled)], check=True)
            compiled.replace(binary)
            result = subprocess.run(['codesign', '-d', '-r-', '--verbose=4', str(binary)], capture_output=True, text=True, check=True)
            description = result.stdout + result.stderr
            requirements.append(re.search(r'^designated => .+$', description, re.M).group())
            hashes.append(re.search(r'^CDHash=(.+)$', description, re.M).group(1))
            if revision == 1:
                subprocess.run([str(binary), 'create', service], check=True)
                created = True
            subprocess.run([str(binary), 'read', service], check=True)
        if requirements[0] != requirements[1] or hashes[0] == hashes[1]:
            raise SystemExit('The two builds did not have different hashes and the same signing requirement.')
        print('Changed builds kept the same identity and read their test item without a password prompt.')
    finally:
        if created:
            subprocess.run([str(binary), 'delete', service], check=True)
