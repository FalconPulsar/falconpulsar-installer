#!/usr/bin/env python3
"""Rehearse a Core upgrade using FalconPulsar's native data-backup archive.

Only new private directories and uniquely named, network-disabled containers
are used. The helper reuses the application's databackup.Restore implementation.
No installed stack commands, production paths, image pulls, or deployment.
"""
import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid


def run(argv, *, input=None, timeout=120):
    result = subprocess.run([str(a) for a in argv], input=input, capture_output=True, timeout=timeout)
    if result.returncode:
        # Subprocess output can contain source configuration; keep it out of errors.
        raise RuntimeError(f'{Path(str(argv[0])).name} failed with exit {result.returncode}')
    return result.stdout


def write_json(path, value):
    with open(path, 'x', encoding='utf-8') as out:
        json.dump(value, out, indent=2)
        out.write('\n')
    os.chmod(path, 0o600)


def digest(path, normalize_fpf=False):
    h = hashlib.sha256()
    with path.open('rb') as source:
        if normalize_fpf and path.suffix == '.fpf':
            header = source.read(256)
            if len(header) != 256:
                raise ValueError(f'Truncated FPF header: {path.name}')
            h.update(header[:240] + bytes(16))
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def tree_hashes(root, normalize_fpf=False):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Symbolic link in restored data')
        if path.is_file():
            result[str(path.relative_to(root))] = digest(path, normalize_fpf)
        elif not path.is_dir():
            raise ValueError('Special file in restored data')
    return result


def verify_restore(report):
    prefixes = dict(report['paths'])
    prefixes['config'] = prefixes.pop('captured_config')
    for item in report['files']:
        if item['path'] == 'manifest.json':
            continue
        prefix, rel = item['path'].split('/', 1)
        target = Path(prefixes[prefix]) / rel
        if not target.is_file() or target.stat().st_size != item['size_bytes'] or digest(target) != item['sha256']:
            raise ValueError(f'Restored content does not match archive: {item["path"]}')


def sqlite_checks(restored, work):
    checks = []
    for service in ('gateway', 'engine', 'copilot'):
        root = Path(restored['paths'][service])
        for db in sorted(root.rglob('*.db')):
            # SQLite may update SHM even for a read-only connection. Work only
            # on a disposable clone so the restored rollback baseline stays exact.
            with tempfile.TemporaryDirectory(prefix='sqlite-', dir=work) as tmp:
                copy = Path(tmp) / db.name
                shutil.copy2(db, copy)
                for suffix in ('-wal', '-shm'):
                    sidecar = Path(str(db) + suffix)
                    if sidecar.exists():
                        shutil.copy2(sidecar, Path(str(copy) + suffix))
                conn = sqlite3.connect(copy.as_uri() + '?mode=ro', uri=True)
                try:
                    result = conn.execute('PRAGMA integrity_check').fetchall()
                    if result != [('ok',)]:
                        raise ValueError(f'SQLite integrity check failed for {service}/{db.name}')
                    tables = {}
                    for (name,) in conn.execute("SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name"):
                        quoted = '"' + name.replace('"', '""') + '"'
                        tables[name] = conn.execute('SELECT count(*) FROM ' + quoted).fetchone()[0]
                    checks.append({'path': f'{service}/{db.relative_to(root)}', 'integrity': 'ok', 'table_rows': tables})
                finally:
                    conn.close()
    if not checks:
        raise ValueError('No SQLite stores found in full backup')
    return checks


def docker_http(name, method, path, body=None, token=None):
    payload = b'' if body is None else json.dumps(body).encode()
    headers = [f'{method} {path} HTTP/1.0', 'Host: localhost', 'Connection: close',
               'Content-Type: application/json', f'Content-Length: {len(payload)}']
    if token:
        headers.append('Authorization: Bearer ' + token)
    request = ('\r\n'.join(headers) + '\r\n\r\n').encode() + payload
    raw = run(['docker', 'exec', '-i', name, 'bash', '-c',
               'exec 3<>/dev/tcp/127.0.0.1/7433; cat >&3; cat <&3'], input=request, timeout=30)
    head, response = raw.split(b'\r\n\r\n', 1)
    status = int(head.splitlines()[0].split()[1])
    if status != 200:
        raise RuntimeError(f'Isolated Core {method} {path} returned HTTP {status}')
    return json.loads(response)


def remove_owned_container(name):
    subprocess.run(['docker', 'rm', '-f', '-v', name], capture_output=True, timeout=90)
    # A daemon failure is not proof of absence. Only a successful inventory
    # query with no exact matching name verifies cleanup (including --rm runs).
    remaining = run(['docker', 'container', 'ls', '-a', '--filter', 'name=^/' + name + '$',
                     '--format', '{{.Names}}'], timeout=30).decode().splitlines()
    if remaining:
        raise RuntimeError('Owned rehearsal container cleanup failed')


def probe_core(image, candidate, checks, credentials, work):
    results = []
    for boot in (1, 2):
        name = 'fp-rehearse-' + uuid.uuid4().hex[:12]
        try:
            run(['docker', 'run', '-d', '--pull', 'never', '--name', name,
                 '--network', 'none', '--read-only', '--cap-drop', 'ALL',
                 '--security-opt', 'no-new-privileges', '--pids-limit', '128',
                 '--memory', '2g', '--cpus', '2', '--user', f'{os.getuid()}:{os.getgid()}',
                 '--tmpfs', '/tmp:rw,nosuid,noexec,size=256m',
                 '--mount', f'type=bind,source={candidate},target=/data',
                 '--entrypoint', '/usr/local/bin/falconpulsar-server', image,
                 '-V', '-c', '/data/falconpulsar.toml', '-d', '/data', '--bind', '127.0.0.1',
                 '-p', '7433', '--ws-port', '7434', '--metrics-port', '7435'])
            deadline = time.monotonic() + 120
            while True:
                try:
                    docker_http(name, 'GET', '/health')
                    break
                except (RuntimeError, ValueError, subprocess.TimeoutExpired):
                    state = run(['docker', 'inspect', '-f', '{{.State.Running}}', name]).strip()
                    if state != b'true' or time.monotonic() > deadline:
                        raise RuntimeError('Candidate Core failed to become healthy')
                    time.sleep(0.5)
            session = docker_http(name, 'POST', '/api/v1/auth/login', credentials)
            token = session.get('token') or session.get('access_token')
            if not isinstance(token, str) or not token:
                raise ValueError('Candidate login returned no token')
            samples = []
            for index, expected in enumerate(checks):
                response = docker_http(name, 'POST', '/api/v1/query',
                                       {'query': expected['query'], 'limit': expected['limit']}, token)
                if response.get('error') or response.get('row_count') != expected['expected_row_count']:
                    raise ValueError(f'Query check {index + 1} row count mismatch on boot {boot}')
                if response.get('rows') != expected['expected_rows']:
                    raise ValueError(f'Query check {index + 1} values/timestamps mismatch on boot {boot}')
                samples.append({'check': index + 1, 'row_count': response['row_count'], 'exact_rows': True})
            run(['docker', 'stop', '-t', '60', name], timeout=90)
            code = int(run(['docker', 'inspect', '-f', '{{.State.ExitCode}}', name]).strip())
            if code != 0:
                raise RuntimeError(f'Candidate Core shutdown exited {code}')
            results.append({'boot': boot, 'health': 'passed', 'authentication': 'passed', 'queries': samples,
                            'shutdown_exit_code': code})
        finally:
            try:
                logs = subprocess.run(['docker', 'logs', name], capture_output=True, timeout=30)
                with open(work / f'core-boot-{boot}.log', 'xb') as out:
                    out.write(logs.stdout + logs.stderr)
            finally:
                remove_owned_container(name)
    return results


def load_checks(path):
    checks = json.loads(path.read_text())
    if not isinstance(checks, list) or not checks:
        raise ValueError('Expected at least one baseline query check')
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get('query'), str) or not check['query'].strip():
            raise ValueError('Every check requires a query')
        rows, count, limit = check.get('expected_rows'), check.get('expected_row_count'), check.get('limit')
        if not isinstance(rows, list) or type(count) is not int or count < 1 or len(rows) != count:
            raise ValueError('Every check requires nonempty exact baseline rows and matching count')
        if type(limit) is not int or not count < limit <= 10000:
            raise ValueError('Query limit must exceed expected count and be <= 10000')
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path, help='New private rehearsal directory')
    parser.add_argument('--helper', required=True, type=Path, help='Built app-native fp-rehearse helper')
    parser.add_argument('--core-image', required=True, help='Already built candidate Core image; never pulled')
    parser.add_argument('--checks', required=True, type=Path, help='JSON baseline query expectations, without credentials')
    parser.add_argument('--verified-clean-checkpoint', action='store_true',
                        help='Operator attests every retained WAL entry was durably applied by old Core before backup')
    args = parser.parse_args()
    if not args.verified_clean_checkpoint:
        parser.error('A verified clean checkpoint is required; a live backup or successful exit alone is insufficient')
    os.umask(0o077)
    archive, helper = args.archive.resolve(strict=True), args.helper.resolve(strict=True)
    requested = args.destination.absolute()
    if requested.exists() or requested.is_symlink() or not requested.parent.is_dir():
        raise ValueError('Destination must be new, with an existing parent')
    work = requested.parent.resolve(strict=True) / requested.name
    if ',' in str(work):
        raise ValueError('Destination cannot contain commas (Docker mount syntax)')
    checks = load_checks(args.checks)
    metadata = json.loads(run([helper, 'inspect', '--archive', archive], timeout=None))
    if set(metadata['manifest']['services']) != {'core', 'gateway', 'engine', 'copilot', 'config'}:
        raise ValueError('Rehearsal requires a full five-service data archive')
    required = 3 * metadata['total_bytes'] + metadata['archive_bytes'] + 1024**3
    if shutil.disk_usage(work.parent).free < required:
        raise ValueError(f'Insufficient free space; allow at least {required} bytes for independent copies')
    image = run(['docker', 'image', 'inspect', '-f', '{{.Id}}', args.core_image]).decode().strip()
    credentials = {'username': os.environ.get('FP_REHEARSAL_USERNAME') or input('Existing Core username: '),
                   'password': os.environ.get('FP_REHEARSAL_PASSWORD') or getpass.getpass('Existing Core password: ')}
    work.mkdir(mode=0o700)
    report = {'schema_version': 1, 'status': 'incomplete', 'archive_sha256': metadata['archive_sha256'],
              'candidate_image': image, 'operator_verified_clean_checkpoint': True,
              'production_modified': False, 'full_stack_rehearsal': False}
    try:
        restored = json.loads(run([helper, 'restore', '--archive', archive, '--destination', work / 'restored'], timeout=None))
        if restored['archive_sha256'] != metadata['archive_sha256']:
            raise ValueError('Archive changed between inspection and restoration')
        verify_restore(restored)
        write_json(work / 'restore-report.json', restored)
        report['sqlite'] = sqlite_checks(restored, work)
        source = Path(restored['paths']['core'])
        output = work / 'migration'
        output.mkdir(mode=0o700)
        candidate = output / 'core'
        name = 'fp-rehearse-migrate-' + uuid.uuid4().hex[:12]
        try:
            migration = run(['docker', 'run', '--rm', '--pull', 'never', '--name', name,
                '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                '--user', f'{os.getuid()}:{os.getgid()}', '--tmpfs', '/tmp:rw,nosuid,noexec,size=64m',
                '--mount', f'type=bind,source={source},target=/source,readonly',
                '--mount', f'type=bind,source={output},target=/output',
                '--entrypoint', '/usr/local/bin/falconpulsar-legacy-migrate', image,
                '--verified-clean-checkpoint', '/source', '/output/core'], timeout=None)
            (work / 'migration.log').write_bytes(migration)
        finally:
            # May already be removed by --rm. This exact random name belongs to this run only.
            remove_owned_container(name)
        if tree_hashes(source, True) != tree_hashes(candidate, True):
            raise ValueError('Migration changed files beyond the permitted FPF checkpoint markers')
        report['migration_exact_payloads'] = True
        report['core'] = probe_core(image, candidate, checks, credentials, work)
        rollback = json.loads(run([helper, 'restore', '--archive', archive, '--destination', work / 'rollback-copy'], timeout=None))
        if rollback['archive_sha256'] != metadata['archive_sha256']:
            raise ValueError('Archive changed before rollback verification')
        verify_restore(rollback)
        verify_restore(restored)
        write_json(work / 'rollback-report.json', rollback)
        report['rollback_restore_exact'] = True
        report['owned_containers_removed'] = True
        report['status'] = 'passed'
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = str(error)
        raise
    finally:
        write_json(work / 'rehearsal-result.json', report)
    print('PASS: archive, SQLite integrity, migration preservation, two Core opens and rollback restoration')
    print(work / 'rehearsal-result.json')
    print('This is a Core/storage rehearsal; full-stack deployment validation remains separate.')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print(f'Rehearsal failed: {error}', file=sys.stderr)
        sys.exit(1)
