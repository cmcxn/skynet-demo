#!/usr/bin/env python3
"""Offline package audit regressions; synthetic PE headers are not executable."""
import contextlib
import runpy
import io
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
package = runpy.run_path(str(ROOT / 'scripts/ci/windows-package.py'))

BASE_FILES = '''skynet.exe lua.exe lua54.dll skynet.dll start.bat
certs/ca-bundle.crt licenses/skynet.txt licenses/lua.txt licenses/lua-cjson.txt
licenses/openssl.txt licenses/pluto-aoi/LICENSE licenses/skynet-llm/LICENSE
licenses/skynet-postgres/LICENSE licenses/postgrest-lua/LICENSE
lualib/postgrest/database.lua lualib/skynet_postgrest_client.lua
tests/postgrest/config tests/postgrest/integration.lua test-postgrest.bat
postgrest-local.example.bat postgrest-cloudbase.example.bat'''.split()
POSTGRES_FILES = '''lualib/pgmoon/init.lua lualib/pgmoon/db.lua
lualib/pgmoon/socket.lua lualib/pgmoon/arrays.lua lualib/pgmoon/hstore.lua
lualib/pgmoon/crypto.lua lualib/pgmoon/json.lua lualib/pgmoon/util.lua
lualib/skynet/queue.lua lualib/pgmoon/bit.lua lualib/pgvector.lua lualib/sha2.lua
luaclib/skynet_postgres_native.so tests/postgres/unit.lua
tests/postgres/protocol-regressions.lua tests/postgres/transactions.lua'''.split()


def fake_pe():
    data = bytearray(256)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 64)
    data[64:68] = b'PE\0\0'
    struct.pack_into('<H', data, 68, 0x8664)
    struct.pack_into('<H', data, 88, 0x20b)
    return data


class PostgresPackageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in BASE_FILES + POSTGRES_FILES + [f'dependency-{i}.dll' for i in range(7)]:
            self.add_file(name)

    def add_file(self, name):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(fake_pe() if path.suffix in {'.exe', '.dll', '.so'} else b'fixture\n')
        return path

    def audit(self):
        with contextlib.redirect_stdout(io.StringIO()):
            package['audit'](self.root)

    def test_complete_offline_package_passes(self):
        self.audit()

    def test_each_postgres_runtime_and_offline_test_file_is_required(self):
        for name in POSTGRES_FILES:
            with self.subTest(missing=name):
                path = self.root / name
                data = path.read_bytes()
                path.unlink()
                try:
                    with self.assertRaisesRegex(AssertionError, 'Missing required package file'):
                        self.audit()
                finally:
                    path.write_bytes(data)

    def test_database_fixtures_and_credentials_are_rejected(self):
        for name in ['tests/postgres/integration.lua', 'tests/postgres/config',
                     'tests/postgres/certs/ca.crt', 'tests/postgres/password.txt',
                     'tests/postgres/fixtures/init.sql', 'postgres-settings.bat']:
            with self.subTest(forbidden=name):
                path = self.add_file(name)
                try:
                    with self.assertRaises(AssertionError):
                        self.audit()
                finally:
                    path.unlink()


if __name__ == '__main__':
    unittest.main()
