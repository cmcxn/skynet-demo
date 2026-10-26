#!/usr/bin/env python3
"""Run identical Skynet pgvector/PostgREST tests locally and on CloudBase."""
import argparse
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import time
from urllib.parse import urlsplit
import uuid

ROOT = Path(__file__).resolve().parent.parent
read_config = runpy.run_path(str(ROOT/'scripts/test-postgrest-config.py'))['read_config']
TABLE = 'skynet_pgvector_test_20261026'


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


def cloud_sql(config, sql):
    host = urlsplit(config['DB_REST_URL']).hostname or ''
    suffix = '.api.tcloudbasegateway.com'
    assert host.endswith(suffix), 'Expected domestic CloudBase gateway URL'
    env_id = host[:-len(suffix)]
    token = config['DB_REST_TOKEN']
    env = {**os.environ, 'CLOUDBASE_ENV_ID':env_id, 'CLOUDBASE_API_KEY':token}
    result = subprocess.run(['npx','--yes','--package','@cloudbase/cli','tcb','db','execute',
                             '-e',env_id,'--sql',sql,'--json'],env=env,
                            capture_output=True,text=True,timeout=90)
    if result.returncode:
        raise RuntimeError((result.stdout+result.stderr).replace(token,'[redacted]'))
    data = json.loads(result.stdout).get('data', {})
    return [json.loads(row) if isinstance(row,str) else row for row in data.get('Rows') or []]


def statements(schema='public'):
    sql = (ROOT/'components/skynet-postgrest/tests/pgvector-setup.sql').read_text()
    assert re.fullmatch(r'[a-z_][a-z0-9_]*',schema), 'Unexpected vector schema'
    sql = sql.replace('public.vector',schema+'.vector')
    sql = sql.replace('SET search_path = pg_catalog, public',f'SET search_path = pg_catalog, public, {schema}')
    return [part.strip() for part in sql.split('-- statement boundary') if part.strip()]


def prepare_cloud(config):
    query = lambda sql: cloud_sql(config,sql)
    extension = query("SELECT e.extversion,n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace WHERE e.extname='vector'")
    if not extension:
        available = query("SELECT default_version FROM pg_available_extensions WHERE name='vector'")
        assert available, 'CloudBase does not expose vector extension'
        query('CREATE EXTENSION vector WITH SCHEMA public')
        extension = query("SELECT e.extversion,n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace WHERE e.extname='vector'")
    assert extension, 'Extension installation did not take effect'
    version,schema = extension[0]
    print(f'CloudBase vector version={version} schema={schema}',flush=True)
    columns = query(f"SELECT column_name,udt_name FROM information_schema.columns WHERE table_schema='public' AND table_name='{TABLE}' ORDER BY ordinal_position")
    if columns:
        assert columns==[['run_id','text'],['label','text'],['embedding','vector']], 'Existing fixture schema mismatch'
    signature=f'public.skynet_pgvector_match_20261026({schema}.vector,text,text,integer)'
    function_exists=query(f"SELECT to_regprocedure('{signature}') IS NOT NULL")[0][0]
    function_exists = function_exists in (True,'true','t')
    for index,sql in enumerate(statements(schema)):
        if index==0 and columns:
            continue
        if sql.startswith('CREATE FUNCTION') and function_exists:
            continue
        query(sql)
    rows = query(f"SELECT c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='{TABLE}'")
    assert rows and rows[0][0] in (True,'true','t'), 'Cloud fixture RLS not enabled'
    print('CloudBase dedicated table, invoker RPC, RLS and service_role grants ready',flush=True)


def test(config, label, network=None):
    env = {**os.environ, **config, 'DB_TEST_RUN_ID':str(uuid.uuid4())}
    args=['docker','run','--rm','-v',f'{ROOT}:/workspace:ro','-w','/skynet']
    if network:
        args += ['--network',network]
    for key in (*config,'DB_TEST_RUN_ID'):
        args += ['-e',key]
    args += ['--entrypoint','sh',os.getenv('POSTGREST_SKYNET_IMAGE','skynet-demo:postgrest'),
             '-ec','timeout 120 ./skynet /workspace/components/skynet-postgrest/tests/config-pgvector']
    result=subprocess.run(args,env=env,capture_output=True,text=True,timeout=150)
    output=result.stdout+result.stderr
    if config['DB_REST_TOKEN']:
        output=output.replace(config['DB_REST_TOKEN'],'[redacted]')
    results=ROOT/'.local/pgvector-postgrest-results'
    results.mkdir(parents=True,exist_ok=True)
    (results/(label+'.log')).write_text(output)
    print(output,end='',flush=True)
    assert result.returncode==0 and 'PASS: 11 shared pgvector PostgREST groups' in output,f'{label} failed; see local log'
    print(f'PASS {label}: 11/11',flush=True)


def local_test():
    tag='skynet-vector-'+uuid.uuid4().hex[:12]
    try:
        run(['docker','network','create',tag])
        run(['docker','run','-d','--name',tag+'-db','--network',tag,'--network-alias','db',
             '-e','POSTGRES_PASSWORD=local-test-only',os.getenv('PGVECTOR_TEST_IMAGE','pgvector/pgvector:pg16')])
        for _ in range(60):
            p=subprocess.run(['docker','exec',tag+'-db','pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True,timeout=10)
            if p.returncode==0:break
            time.sleep(1)
        else:raise RuntimeError('Local database readiness timeout')
        def sql(text):
            return run(['docker','exec',tag+'-db','psql','-U','postgres','-v','ON_ERROR_STOP=1','-Atc',text]).stdout
        sql('CREATE EXTENSION vector WITH SCHEMA public')
        sql('CREATE ROLE service_role NOLOGIN BYPASSRLS')
        print('Local vector version='+sql("SELECT extversion FROM pg_extension WHERE extname='vector'").strip(),flush=True)
        for statement in statements():sql(statement)
        run(['docker','run','-d','--name',tag+'-rest','--network',tag,
             '-e','PGRST_DB_URI=postgres://postgres:local-test-only@db:5432/postgres',
             '-e','PGRST_DB_SCHEMAS=public','-e','PGRST_DB_ANON_ROLE=service_role',
             'postgrest/postgrest:v12.2.12'])
        for _ in range(30):
            logs=run(['docker','logs',tag+'-rest'])
            if 'Schema cache loaded' in logs.stdout+logs.stderr:break
            time.sleep(1)
        else:raise RuntimeError('Local PostgREST readiness timeout')
        host=run(['docker','inspect','-f','{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}',tag+'-rest']).stdout.strip()
        test({'DB_REST_URL':f'http://{host}:3000','DB_REST_TOKEN':'','DB_TIMEOUT_TICKS':'3000'},'local',tag)
        assert sql(f'SELECT count(*) FROM public.{TABLE}').strip()=='0', 'Local rows remain'
    finally:
        subprocess.run(['docker','rm','-f',tag+'-rest',tag+'-db'],capture_output=True,timeout=30)
        subprocess.run(['docker','network','rm',tag],capture_output=True,timeout=30)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target',choices=['both','local','cloudbase'],default='both')
    parser.add_argument('--cloud-config',type=Path,default=ROOT/'.local/postgrest-cloudbase.env')
    parser.add_argument('--prepare-cloud',action='store_true',help='Install vector if available; create only dedicated test fixtures')
    options=parser.parse_args()
    if options.target in ('both','local'):local_test()
    if options.target in ('both','cloudbase'):
        config=read_config(options.cloud_config)
        if options.prepare_cloud:prepare_cloud(config)
        test(config,'cloudbase')
        rows=cloud_sql(config,f'SELECT count(*) FROM public.{TABLE}')
        assert rows[0][0] in (0,'0'), 'Cloud rows remain'
        print('PASS CloudBase fixture has zero remaining records',flush=True)


if __name__=='__main__':main()
