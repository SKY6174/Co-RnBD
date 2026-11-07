"""Offline CLI 3 compatibility check; no Docker, credentials, or hosted writes.
python3 scripts/verify-supabase-cli.py (Python 3.11+)
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
CLI = ['sh', str(ROOT / 'scripts/supabase.sh')]
VERSION = (ROOT / '.supabase-cli-version').read_text().strip()
assert re.fullmatch(r'3\.\d+\.\d+', VERSION), 'Pin a reviewed stable CLI 3 release'


def run(*args, **kwargs):
    return subprocess.run(CLI + list(args), capture_output=True, text=True,
                          timeout=60, **kwargs)


assert run('--version', check=True).stdout.strip() == VERSION
config = tomllib.loads((ROOT / 'supabase/config.toml').read_text())
assert config['project_id'], 'Keep local container names stable across upgrades'
assert config['local_smtp']['enabled'] is True
assert 'inbucket' not in config
assert 'orioledb_version' not in config['experimental']
assert 'orioledb_version' in config['db']
assert config['auth']['enable_signup'] is True
for provider, enabled in [('email', True), ('sms', False)]:
    assert config['auth'][provider]['enabled'] is enabled
    assert 'enable_signup' not in config['auth'][provider]
print('PASS: pinned CLI version and current configuration keys')

# The real CLI parses config and resolves a local target, but only prints a dump
# recipe. Never execute or log that recipe (it can include credentials).
dump = run('db', 'dump', '--dry-run', check=True)
assert 'Target: local stack' in dump.stderr, 'CLI must default to the local stack'
assert not re.search(r'WARN|deprecated|no longer supported', dump.stderr, re.I), dump.stderr
assert 'pg_dump' in dump.stdout
for command in [('migration', 'list'), ('db', 'push'), ('db', 'query')]:
    help_text = run(*command, '--help', check=True).stdout
    assert '--remote' in help_text and '--yes' in help_text
assert '--read-only' in run('db', 'query', '--help', check=True).stdout
print('PASS: real CLI config parsing, local default, remote and consent flags')

# Reject incompatible versions before they can perform any database operation.
with tempfile.TemporaryDirectory(prefix='co-rnbd-cli-check-') as temp:
    fake = Path(temp) / 'supabase'
    marker = Path(temp) / 'executed'
    fake.write_text('#!/bin/sh\nif [ "$1" = "--version" ]; then echo 2.122.0; '
                    'else touch "$CLI_TEST_MARKER"; fi\n')
    fake.chmod(0o755)
    env = {**os.environ, 'PATH': temp + os.pathsep + os.environ['PATH'],
           'CLI_TEST_MARKER': str(marker)}
    rejected = run('db', 'push', env=env)
    assert rejected.returncode != 0 and 'required; found' in rejected.stderr
    assert not marker.exists(), 'An incompatible CLI must never run the command'
print('PASS: incompatible CLI cannot execute a database command')
