#!/usr/bin/env python3
"""Run the same Skynet tests with a selected dotenv profile; never shell-source it."""
import argparse
import os
from pathlib import Path
import subprocess
import uuid


def read_config(path):
    config = {}
    allowed = {'DB_REST_URL', 'DB_REST_TOKEN', 'DB_TIMEOUT_TICKS'}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        line = line.removeprefix('export ')
        if '=' not in line:
            raise ValueError(f'Invalid config line {number}')
        key, value = line.split('=', 1)
        key, value = key.strip(), value.strip()
        if key not in allowed:
            raise ValueError(f'Unknown config key on line {number}: {key}')
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        config[key] = value
    if not config.get('DB_REST_URL'):
        raise ValueError('Missing DB_REST_URL')
    config.setdefault('DB_REST_TOKEN', '')
    config.setdefault('DB_TIMEOUT_TICKS', '3000')
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=Path)
    parser.add_argument('--packaged', action='store_true', help='Use bundled modules/tests without mounting source')
    parser.add_argument('--network', help='Docker network mode, e.g. container:<name>')
    options = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    config = read_config(options.config)
    env = {**os.environ, **config, 'DB_TEST_RUN_ID': str(uuid.uuid4())}
    args = ['docker', 'run', '--rm', '-w', '/skynet']
    if not options.packaged:
        args += ['-v', f'{root}:/workspace:ro']
    if options.network:
        args += ['--network', options.network]
    for key in (*config, 'DB_TEST_RUN_ID'):
        args += ['-e', key]
    test_config = 'tests/postgrest/config' if options.packaged else '/workspace/components/skynet-postgrest/tests/config'
    args += ['--entrypoint', 'sh', os.getenv('POSTGREST_SKYNET_IMAGE', 'skynet-demo:master-64391f7'),
             '-ec', f'timeout 120 ./skynet {test_config}']
    result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=150)
    output = result.stdout + result.stderr
    if config['DB_REST_TOKEN']:
        output = output.replace(config['DB_REST_TOKEN'], '[redacted]')
    print(output, end='')
    return 0 if result.returncode == 0 and 'PASS: 8 shared PostgREST integration groups' in output else 1


if __name__ == '__main__':
    raise SystemExit(main())
