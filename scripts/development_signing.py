#!/usr/bin/env python3
"""Keep the same local signing identity between builds."""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / '.local/signing.json'
PREVIOUS = ROOT / '.local/signing-previous.json'
APPLE_IDENTITY = re.compile(r'([0-9A-F]{40}) "(Apple Development: [^"]+)"')


def run(*args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise SystemExit(result.stderr.strip() or 'Signing setup failed.')
    return result.stdout


def load_identity():
    if not CONFIG.exists():
        raise SystemExit('Set up local signing first: python3 scripts/development_signing.py')
    config = json.loads(CONFIG.read_text())
    identity = config['identity']
    if len(identity) != 40 or any(c not in '0123456789ABCDEF' for c in identity):
        raise SystemExit('The local signing fingerprint is invalid.')
    identities = run('security', 'find-identity', '-p', 'codesigning', config['keychain'])
    if identity not in identities:
        raise SystemExit('The saved signing identity is missing from Keychain. Restore it before rebuilding; creating a new one would reset app permissions.')
    return config


def save(config):
    CONFIG.parent.mkdir(mode=0o700, exist_ok=True)
    CONFIG.write_text(json.dumps(config, indent=2) + '\n')
    CONFIG.chmod(0o600)


def use_apple_development(fingerprint=None):
    """Sign with an Apple Development certificate from Xcode.

    Its team ID gives every build the same Keychain identity, so rebuilds stop
    asking about Chromium Safe Storage. A self-signed certificate can't do that.
    """
    os.umask(0o077)
    keychain = run('security', 'default-keychain', '-d', 'user').strip().strip('"')
    # -v leaves out expired and revoked certificates.
    found = APPLE_IDENTITY.findall(run('security', 'find-identity', '-v', '-p', 'codesigning', keychain))
    if fingerprint:
        found = [entry for entry in found if entry[0] == fingerprint.upper()]
    if not found:
        raise SystemExit('No usable Apple Development certificate was found. In Xcode, open Settings > Accounts, sign in with your Apple ID, select your Personal Team, click Manage Certificates, then add an Apple Development certificate.')
    if len(found) > 1:
        listing = '\n'.join(f'  {identity}  {name}' for identity, name in found)
        raise SystemExit(f'More than one Apple Development certificate was found. Run this again with the fingerprint to use:\n{listing}')
    identity, name = found[0]
    if CONFIG.exists():
        current = json.loads(CONFIG.read_text())
        if current.get('identity') == identity:
            print(f'Already signing with {name}.')
            return
        PREVIOUS.write_text(CONFIG.read_text())
        PREVIOUS.chmod(0o600)
    save({'identity': identity, 'keychain': keychain, 'name': name})
    load_identity()
    print(f'Mallard now signs with {name}. The previous setting is saved in .local/signing-previous.json.')
    print('The next build asks about Chromium Safe Storage one last time. Pick Always Allow.')


def setup():
    if CONFIG.exists():
        load_identity()
        print('Local signing is already set up.')
        return
    os.umask(0o077)
    keychain = run('security', 'default-keychain', '-d', 'user').strip().strip('"')
    if not Path(keychain).is_file():
        raise SystemExit('No user Keychain was found.')
    identities = run('security', 'find-identity', '-p', 'codesigning', keychain)
    existing = set(re.findall(r'([0-9A-F]{40}) "Mallard Development"', identities))
    if len(existing) > 1:
        raise SystemExit('More than one Mallard Development identity exists. Restore .local/signing.json to select the original one.')
    if existing:
        CONFIG.parent.mkdir(mode=0o700, exist_ok=True)
        CONFIG.write_text(json.dumps({'identity': existing.pop(), 'keychain': keychain}, indent=2) + '\n')
        CONFIG.chmod(0o600)
        print('Reused the existing Mallard signing identity.')
        return
    with tempfile.TemporaryDirectory(prefix='mallard-signing-') as temporary:
        directory = Path(temporary)
        config = directory / 'certificate.cnf'
        key, certificate = directory / 'key.pem', directory / 'certificate.pem'
        der, archive = directory / 'certificate.der', directory / 'identity.p12'
        config.write_text('''[req]
prompt = no
distinguished_name = name
x509_extensions = usage
[name]
CN = Mallard Development
[usage]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
        run('/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256', '-days', '3650', '-config', str(config), '-keyout', str(key), '-out', str(certificate))
        run('/usr/bin/openssl', 'x509', '-in', str(certificate), '-outform', 'DER', '-out', str(der))
        identity = hashlib.sha1(der.read_bytes()).hexdigest().upper()
        password = secrets.token_urlsafe(32)
        environment = dict(os.environ, MALLARD_SIGNING_TEMP_PASSWORD=password)
        run('/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(certificate), '-name', 'Mallard Development', '-out', str(archive), '-passout', 'env:MALLARD_SIGNING_TEMP_PASSWORD', env=environment)
        run('security', 'import', str(archive), '-k', keychain, '-P', password, '-x', '-T', '/usr/bin/codesign')
        CONFIG.parent.mkdir(mode=0o700, exist_ok=True)
        CONFIG.write_text(json.dumps({'identity': identity, 'keychain': keychain}, indent=2) + '\n')
        CONFIG.chmod(0o600)
    load_identity()
    print('Created a local Mallard signing identity. Its private key is stored in Keychain.')


if __name__ == '__main__':
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == '--apple':
        use_apple_development(sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        setup()
