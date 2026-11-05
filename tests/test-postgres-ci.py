#!/usr/bin/env python3
"""Offline contract checks for PostgreSQL CI wiring (not a Docker/Windows run)."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding='utf-8')


def job(source, name):
    match = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [\w-]+:|\Z)', source, re.M | re.S)
    if not match:
        raise AssertionError('Missing job: ' + name)
    return match.group(1)


def step(source, name):
    marker = '      - name: ' + name + '\n'
    if marker not in source:
        raise AssertionError('Missing step: ' + name)
    return source.split(marker, 1)[1].split('\n      - ', 1)[0]


class PostgresCI(unittest.TestCase):
    def test_linux_service_loads_transaction_facade(self):
        text = read('tests/runtime-load.lua')
        self.assertIn('"pgmoon.db"', text)
        self.assertRegex(text, r'require\("pgmoon.db"\)\.new')

    def test_docker_matrix_tests_the_image_it_just_built(self):
        build = job(read('.github/workflows/docker.yml'), 'build')
        pg = step(build, 'Test PostgreSQL and transactions')
        self.assertIn('PG_SKIP_BUILD: "1"', pg)
        self.assertIn('PG_TEST_IMAGE: ${{ env.TEST_IMAGE }}', pg)
        self.assertIn('run: sh scripts/test-postgres.sh', pg)
        self.assertNotIn('continue-on-error', pg)
        self.assertLess(build.index('Test installed image'), build.index('Test PostgreSQL and transactions'))
        self.assertLess(build.index('Test PostgreSQL and transactions'), build.index('Export tested image'))
        self.assertIn('runner: ubuntu-24.04-arm', build)
        self.assertIn('SKYNET_ARCH: ${{ matrix.arch }}', build)

    def test_windows_live_pg_test_precedes_sealing_and_upload(self):
        build = job(read('.github/workflows/windows.yml'), 'build')
        wine = step(build, 'Build pinned Wine test environment')
        self.assertIn('-f Dockerfile.wine', wine)
        self.assertIn('--platform linux/amd64', wine)
        pg = step(build, 'Test packaged PostgreSQL with Wine')
        self.assertIn('PG_WINDOWS_RUNTIME: ${{ github.workspace }}/dist/skynet-windows-x64', pg)
        self.assertIn('PG_WINE_IMAGE: skynet-wine-test:ci', pg)
        self.assertIn('run: sh scripts/test-postgres.sh', pg)
        self.assertNotIn('continue-on-error', pg)
        self.assertLess(build.index('Build existing MinGW portable package'), build.index('Test packaged PostgreSQL with Wine'))
        self.assertLess(build.index('Test packaged PostgreSQL with Wine'), build.index('Audit and seal release archive'))
        self.assertLess(build.index('Audit and seal release archive'), build.index('actions/upload-artifact'))

    def test_ci_contract_and_windows_package_regressions_run_before_build(self):
        for path in ('.github/workflows/docker.yml', '.github/workflows/windows.yml'):
            checks = step(job(read(path), 'build'), 'Check PostgreSQL CI contracts')
            self.assertIn('python3 tests/test-postgres-ci.py', checks)
            self.assertIn('python3 tests/test-windows-postgres-package.py', checks)

    def test_standard_runner_still_covers_all_pg_layers_and_cleans_up(self):
        text = read('scripts/test-postgres.sh')
        for file in ('protocol-regressions.lua', 'transactions.lua', 'unit.lua'):
            self.assertIn('/workspace/components/skynet-postgres/tests/' + file, text)
            self.assertIn('/postgres-tests/' + file, text)
        self.assertIn('timeout 90 ./skynet', text)
        self.assertIn('timeout 150 /usr/lib/wine/wine64 /portable/skynet.exe', text)
        self.assertIn('trap cleanup EXIT HUP INT TERM', text)
        self.assertIn('docker network rm', text)

    def test_fresh_database_enables_vector_before_any_vector_query(self):
        text = read('components/skynet-postgres/tests/integration.lua')
        self.assertLess(text.index('CREATE EXTENSION IF NOT EXISTS vector'),
                        text.index('::vector'))

    def test_wine_prefix_is_private_to_disposable_container(self):
        text = read('scripts/test-postgres.sh')
        wine = text.split('if [ -n "${PG_WINDOWS_RUNTIME:-}" ]; then', 1)[1]
        self.assertIn('docker run --rm', wine)
        self.assertIn('-e WINEPREFIX=/wineprefix', wine)
        self.assertNotIn(':/wineprefix', wine)
        self.assertNotIn('postgres-wineprefix', wine)

    def test_publication_remains_explicitly_gated(self):
        docker = read('.github/workflows/docker.yml')
        windows = read('.github/workflows/windows.yml')
        self.assertIn('push: false', job(docker, 'build'))
        self.assertIn("if: needs.prepare.outputs.publish == 'true'", job(docker, 'publish'))
        self.assertIn("if: needs.prepare.outputs.publish == 'true'", job(windows, 'release'))
        for text in (docker, windows):
            self.assertIn('default: false', text)
            self.assertIn('branches: [master]', text)
            self.assertNotIn('pull_request_target:', text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
