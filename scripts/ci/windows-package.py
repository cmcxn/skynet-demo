#!/usr/bin/env python3
"""Audit the portable Windows package; optionally seal a release ZIP."""
import argparse, hashlib, json, os, pathlib, re, struct, subprocess, zipfile

SYSTEM_DLLS = {'iphlpapi.dll', 'kernel32.dll', 'msvcrt.dll', 'user32.dll', 'gdi32.dll',
              'ws2_32.dll', 'advapi32.dll', 'crypt32.dll', 'bcrypt.dll', 'ntdll.dll',
              'secur32.dll', 'shell32.dll', 'ole32.dll', 'ucrtbase.dll'}

def audit(root):
    available = {p.name.lower() for p in root.glob('*.dll')}
    count = 0
    for p in root.rglob('*'):
        if not p.is_file():
            continue
        assert not p.is_symlink(), 'Symlinks are not allowed'
        assert not any(x in {'.git', '.local', '__pycache__'} for x in p.parts)
        assert p.name not in {'llm-settings.bat', 'id_rsa', 'id_ed25519'}
        assert p.suffix.lower() not in {'.env', '.key', '.o', '.a', '.pyc'}
        if p.suffix.lower() not in {'.exe', '.dll', '.so'}:
            continue
        b = p.read_bytes()
        assert b[:2] == b'MZ', f'Not PE: {p.name}'
        pe = struct.unpack_from('<I', b, 0x3c)[0]
        assert b[pe:pe+4] == b'PE\0\0'
        machine, sections = struct.unpack_from('<HH', b, pe+4)
        optional_size = struct.unpack_from('<H', b, pe+20)[0]
        optional = pe+24
        assert machine == 0x8664 and struct.unpack_from('<H', b, optional)[0] == 0x20b, f'Not Windows x64: {p.name}'
        def offset(rva):
            for i in range(sections):
                base = optional+optional_size+i*40
                virtual_size, virtual_address, raw_size, raw = struct.unpack_from('<IIII', b, base+8)
                if virtual_address <= rva < virtual_address+max(virtual_size, raw_size):
                    return raw+rva-virtual_address
            raise ValueError(f'Unmapped RVA in {p.name}')
        imports = struct.unpack_from('<I', b, optional+120)[0]
        if imports:
            pos = offset(imports)
            while any(struct.unpack_from('<IIIII', b, pos)):
                name_rva = struct.unpack_from('<I', b, pos+12)[0]
                start = offset(name_rva)
                name = b[start:b.index(b'\0', start)].decode('ascii').lower()
                assert name in SYSTEM_DLLS or name.startswith('api-ms-win-') or name in available, f'Missing DLL {name} required by {p.name}'
                pos += 20
        count += 1
    assert count > 10
    for name in ['skynet.exe', 'lua.exe', 'lua54.dll', 'skynet.dll', 'start.bat',
                 'certs/ca-bundle.crt', 'licenses/skynet.txt', 'licenses/lua.txt',
                 'licenses/lua-cjson.txt', 'licenses/openssl.txt', 'licenses/pluto-aoi/LICENSE',
                 'licenses/skynet-llm/LICENSE', 'licenses/skynet-postgres/LICENSE']:
        assert (root/name).is_file(), f'Missing required package file {name}'
    print(f'PASS: {count} Windows x64 PE files, DLL closure, notices and package hygiene')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=pathlib.Path)
    parser.add_argument('--seal', action='store_true')
    args = parser.parse_args()
    audit(args.root)
    if args.seal:
        sha = os.environ['GITHUB_SHA']
        assert re.fullmatch('[0-9a-f]{40}', sha)
        info = {'source_commit': sha, 'repository': os.environ['GITHUB_REPOSITORY'],
                'run_id': os.environ['GITHUB_RUN_ID'], 'platform': 'windows/x64',
                'build': 'Docker MinGW cross compilation; native Windows CI required before Release',
                'submodules': subprocess.check_output(['git', 'submodule', 'status'], text=True).splitlines()}
        (args.root/'BUILD-INFO.json').write_text(json.dumps(info, indent=2)+'\n', encoding='utf-8')
        notes = ('Skynet portable Windows x64 prerelease\n\nSource: '+sha+'\n'
                 'Extract the entire ZIP. Run start.bat, then client.bat. TCP demo: 8888.\n'
                 'No Docker, MinGW, Lua or OpenSSL installation needed on the destination PC.\n'
                 'Includes cjson, verified TLS/CA, LLM, AOI and PostgreSQL modules and licenses.\n'
                 'Native Windows CI checks PE/DLL closure, modules, offline LLM/AOI and TCP start/stop.\n'
                 'No ARM64/32-bit support claim. No real model, external HTTPS or database integration claim.\n'
                 'Unsigned binaries; do not disable Windows security protections.\n'
                 'The example is an in-memory demonstration, not a production deployment.\n'
                 'Keep any personal llm-settings.bat private. Read README.txt for ports and test options.\n')
        (args.root/'RELEASE-NOTES.txt').write_text(notes, encoding='utf-8')
        dist = args.root.parent
        (dist/'RELEASE-NOTES.txt').write_text(notes, encoding='utf-8')
        archive = dist/'skynet-windows-x64.zip'
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
            for p in sorted(args.root.rglob('*')):
                if p.is_file():
                    z.write(p, p.relative_to(dist))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (dist/'skynet-windows-x64.zip.sha256').write_text(digest+'  '+archive.name+'\n')
        print('PASS: release ZIP sealed', digest)
