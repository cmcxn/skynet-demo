#!/usr/bin/env python3
"""Test the Windows ZIP under Wine against disposable PostgREST and CloudBase."""
import argparse
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import time
import uuid
import zipfile

ROOT = Path(__file__).resolve().parent.parent
read_config = runpy.run_path(str(ROOT / 'scripts/test-postgrest-config.py'))['read_config']


def command(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=90, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cloud-config', type=Path, default=ROOT / '.local/postgrest-cloudbase.env')
    options = parser.parse_args()
    cloud = read_config(options.cloud_config)
    image = os.getenv('POSTGREST_WINE_IMAGE', 'skynet-wine-test:10.0-amd64')
    results = ROOT / '.local/postgrest-wine-results'
    results.mkdir(parents=True, exist_ok=True)
    prefix = ROOT / '.local/postgrest-wineprefix'
    prefix.mkdir(parents=True, exist_ok=True)
    tag = 'skynet-pgrst-wine-' + uuid.uuid4().hex[:12]
    try:
        command(['docker', 'network', 'create', tag])
        command(['docker', 'run', '-d', '--name', tag+'-db', '--network', tag,
                 '--network-alias', 'db', '-e', 'POSTGRES_PASSWORD=local-test-only',
                 '-v', f'{ROOT}/components/skynet-postgrest/tests/init.sql:/docker-entrypoint-initdb.d/init.sql:ro',
                 'postgres:16-alpine'])
        for _ in range(60):
            ready = subprocess.run(['docker','exec',tag+'-db','psql','-U','postgres','-tAc',
                                    "SELECT to_regclass('public.skynet_postgrest_test_20261026')"],
                                   capture_output=True, text=True, timeout=10)
            if ready.returncode == 0 and 'skynet_postgrest_test_20261026' in ready.stdout:
                break
            time.sleep(1)
        else:
            raise RuntimeError('PostgreSQL readiness timeout')
        command(['docker','run','-d','--name',tag+'-rest','--network',tag,
                 '-e','PGRST_DB_URI=postgres://postgres:local-test-only@db:5432/postgres',
                 '-e','PGRST_DB_SCHEMAS=public','-e','PGRST_DB_ANON_ROLE=web_anon',
                 'postgrest/postgrest:v12.2.12'])
        for _ in range(30):
            logs = command(['docker','logs',tag+'-rest'])
            if 'Schema cache loaded' in logs.stdout + logs.stderr:
                break
            time.sleep(1)
        else:
            raise RuntimeError('PostgREST readiness timeout')
        host = command(['docker','inspect','-f','{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}',tag+'-rest']).stdout.strip()
        local = {'DB_REST_URL': f'http://{host}:3000', 'DB_REST_TOKEN': '', 'DB_TIMEOUT_TICKS': '3000'}
        # Test the actual distributable archive, never a source-mounted service.
        with tempfile.TemporaryDirectory(prefix='.postgrest-wine-', dir=ROOT/'dist') as stage:
            with zipfile.ZipFile(ROOT/'dist/skynet-windows-x64.zip') as archive:
                archive.extractall(stage)
            package = Path(stage)/'skynet-windows-x64'
            print(command(['python3',str(ROOT/'scripts/ci/windows-package.py'),str(package)]).stdout, end='', flush=True)
            base = ['docker','run','--rm','--platform','linux/amd64','--network',tag,
                    '-v',f'{package}:/portable:ro','-v',f'{prefix}:/wineprefix',
                    '-w','/portable','-e','WINEPREFIX=/wineprefix','-e','WINEDEBUG=-all',
                    '-e','XDG_RUNTIME_DIR=/tmp']
            print(command(base + ['--entrypoint','sh',image,'-ec',
                                  'timeout 60 /usr/lib/wine/wine64 wineboot -u; timeout 20 /usr/lib/wine/wineserver -w']).stdout, end='', flush=True)
            for label, config in [('selfhost',local),('cloudbase',cloud)]:
                env = {**os.environ, **config, 'DB_TEST_RUN_ID':str(uuid.uuid4())}
                settings = package/'postgrest-settings.bat'
                if label == 'selfhost':
                    # Exercise the private Windows settings-file path as well.
                    settings.write_bytes(('@echo off\r\n' + ''.join(
                        f'set "{key}={value}"\r\n' for key,value in config.items())).encode())
                args = base[:]
                keys = ('DB_TEST_RUN_ID',) if label == 'selfhost' else (*config, 'DB_TEST_RUN_ID')
                for key in keys:
                    args += ['-e',key]
                args += ['--entrypoint','sh',image,'-ec',
                         'timeout 120 /usr/lib/wine/wine64 cmd /c test-postgrest.bat']
                run = subprocess.run(args, env=env, capture_output=True, text=True, timeout=150)
                if settings.exists():
                    settings.unlink()
                output = run.stdout + run.stderr
                if config['DB_REST_TOKEN']:
                    output = output.replace(config['DB_REST_TOKEN'],'[redacted]')
                (results/(label+'.log')).write_text(output)
                print(output, end='', flush=True)
                if run.returncode or 'PASS: 8 shared PostgREST integration groups' not in output:
                    raise RuntimeError(f'{label} Wine test failed (exit {run.returncode}); see local log')
                print(f'PASS Windows x64 / Wine {label}: 8/8', flush=True)
    finally:
        subprocess.run(['docker','rm','-f',tag+'-rest',tag+'-db'], capture_output=True, timeout=30)
        subprocess.run(['docker','network','rm',tag], capture_output=True, timeout=30)


if __name__ == '__main__':
    main()
