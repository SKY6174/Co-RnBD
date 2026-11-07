"""Prepare a NEW disposable, unlinked local Supabase. Never loads a production env.
python3 scripts/prepare-lifecycle-env.py --output /tmp/co-rnbd-lifecycle-run
The output directory must not exist. Stop with the command printed after setup.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
local = Path(tempfile.mkdtemp(prefix='co-rnbd-e2e-'))
project = local.name
env = {k: v for k, v in os.environ.items()
       if not k.startswith(('SUPABASE_', 'PG', 'S3_', 'OPENAI_'))}
ports = {'api': 55461, 'db': 55462, 'shadow': 55460, 'studio': 55463, 'smtp': 55464}
for port in ports.values():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', port))
config = (ROOT / 'supabase/config.toml').read_text()
config = config.replace('project_id = "Co-RnBD"', f'project_id = "{project}"')
for old, new in [(54321, ports['api']), (54322, ports['db']), (54320, ports['shadow']),
                 (54323, ports['studio']), (54324, ports['smtp']), (54327, 55467), (54329, 55469)]:
    config = config.replace(str(old), str(new))
config = config.replace('http://127.0.0.1:3000', 'http://127.0.0.1:8786')
config = config.replace('https://127.0.0.1:3000', 'http://127.0.0.1:8786/**')
config = config.replace('sql_paths = ["./seed.sql"]', 'sql_paths = []')
(local / 'supabase').mkdir()
(local / 'supabase/config.toml').write_text(config)
for folder in ('migrations', 'templates'):
    shutil.copytree(ROOT / 'supabase' / folder, local / 'supabase' / folder)
cli = ['sh', str(ROOT / 'scripts/supabase.sh'), '--workdir', str(local)]
meta = {'local': str(local), 'project': project, 'base': 'http://127.0.0.1:8786',
        'api': f'http://127.0.0.1:{ports["api"]}', 'db_port': ports['db']}
(out / 'environment.json').write_text(json.dumps(meta, indent=2))
assert not (local / '.env').exists() and not (local / 'supabase/.temp/project-ref').exists()
print('Starting fresh local project ' + project + ' (no remote project link)', flush=True)
result = subprocess.run(cli + ['start', '--exclude',
    'studio,postgres-meta,realtime,edge-runtime,imgproxy,logflare,vector,supavisor'],
    env=env, capture_output=True, text=True)
if result.returncode:
    # Start can print local credentials, so keep the diagnostic private and do not
    # echo captured output to CI or the conversation.
    diagnostic = out / '.env.start-diagnostic'
    diagnostic.write_text(result.stdout + result.stderr)
    diagnostic.chmod(0o600)
    raise RuntimeError('Local start failed; private diagnostic: ' + str(diagnostic))
status = json.loads(subprocess.run(cli + ['status', '-o', 'json'], env=env,
    check=True, capture_output=True, text=True).stdout)
assert status['API_URL'] == meta['api'], 'Unexpected API target'
assert '127.0.0.1' in status['DB_URL'], 'Local database only'
secret_file = out / '.env.local-status.json'
secret_file.write_text(json.dumps(status))
secret_file.chmod(0o600)
print('PASS: fresh local Auth/Postgres/Storage and all repository migrations ready', flush=True)
print('Stop this project only: sh scripts/supabase.sh --workdir ' + str(local) + ' stop', flush=True)
