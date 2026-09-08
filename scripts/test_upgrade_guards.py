#!/usr/bin/env python3
"""Exercise upgrade checks without changing an installation or invoking Docker."""
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / 'shared/core-upgrade-preflight.sh'
EXISTING = ROOT / 'shared/lib/existing.sh'

class UpgradeGuards(unittest.TestCase):
    def check_headers(self, headers, expected):
        with tempfile.TemporaryDirectory(prefix='fp upgrade ') as tmp:
            root = Path(tmp)
            for name, content in headers.items():
                file = root / 'fractal' / '218' / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(content)
            before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*.fpf')}
            result = subprocess.run(['sh', str(CHECK), str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, expected, result.stderr)
            self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*.fpf')})

    @staticmethod
    def header(points=1, marker=True):
        data = bytearray(256)
        data[:8] = b'FPFILE01'
        struct.pack_into('<Q', data, 48, points)
        if marker: data[248:252] = b'WLS1'
        return data

    def test_current_headers_pass_without_modification(self):
        self.check_headers({'a.fpf': self.header() + b'payload'}, True)

    def test_empty_database_and_empty_legacy_partition_pass(self):
        self.check_headers({}, True)
        self.check_headers({'empty.fpf': self.header(points=0, marker=False)}, True)

    def test_legacy_history_fails_before_replacement(self):
        self.check_headers({'a.fpf': self.header(), 'legacy with spaces.fpf': self.header(marker=False)}, False)

    def test_truncated_and_unknown_headers_fail_closed(self):
        self.check_headers({'truncated.fpf': b'FPFILE01'}, False)
        self.check_headers({'unknown.fpf': b'x' * 256}, False)

    def shell(self, script):
        return subprocess.run(['bash', '-c', f'. "{EXISTING}"\nlog_error() {{ echo "$*" >&2; }}\n' + script], capture_output=True, text=True)

    def test_healthy_container_passes(self):
        result = self.shell('docker() { echo "running healthy"; }; fp_wait_upgrade_container example 1')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_or_missing_application_health_fails(self):
        for state in ['restarting unhealthy', 'running unhealthy', 'exited unhealthy', 'running missing', 'missing']:
            with self.subTest(state=state):
                result = self.shell(f'docker() {{ echo "{state}"; }}; fp_wait_upgrade_container example 1')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Previous images are retained', result.stderr)

    def test_health_timeout_fails(self):
        result = self.shell('fp_wait_upgrade_container example 0')
        self.assertNotEqual(result.returncode, 0)

    def test_not_applicable_and_failed_upgrade_are_distinct(self):
        self.assertEqual(self.shell('FP_INSTALL_ACTION=install; fp_try_upgrade_fastpath /missing').returncode, 1)
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'compose.yml').write_text('services: {}')
            result = self.shell(f'FP_INSTALL_ACTION=upgrade; fp_registry_ensure_access() {{ return 1; }}; fp_try_upgrade_fastpath "{tmp}"')
            self.assertEqual(result.returncode, 2)

    def test_published_bundles_include_the_complete_checker(self):
        guard = CHECK.read_text()
        for platform in ['linux', 'macos']:
            result = subprocess.run(['bash', str(ROOT / '.github/scripts/bundle.sh'), platform], capture_output=True, text=True, check=True)
            self.assertIn('shared/core-upgrade-preflight.sh', result.stdout)
            self.assertIn(guard, result.stdout)
            syntax = subprocess.run(['bash', '-n'], input=result.stdout, text=True, capture_output=True)
            self.assertEqual(syntax.returncode, 0, syntax.stderr)

    def test_entrypoints_do_not_fall_through_to_reinstall_after_upgrade_failure(self):
        for platform in ['linux', 'macos']:
            text = (ROOT / platform / 'install.sh').read_text()
            start = text.index('    if fp_try_upgrade_fastpath "$FP_HOME"; then')
            end = text.index('\n    # The fast-path fell through', start)
            block = text[start:end]
            script = 'fp_try_upgrade_fastpath() { return 2; }; die() { exit 42; };\n' + block + '\nexit 0'
            result = self.shell(script)
            self.assertEqual(result.returncode, 42, platform)

if __name__ == '__main__': unittest.main()
