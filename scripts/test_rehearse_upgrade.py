#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('rehearse', Path(__file__).with_name('rehearse-upgrade.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

class RehearsalTests(unittest.TestCase):
    def test_only_checkpoint_marker_may_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'a.fpf'
            p.write_bytes(bytes(256) + b'payload')
            original = r.digest(p, True)
            p.write_bytes(bytes(240) + b'1' * 16 + b'payload')
            self.assertEqual(original, r.digest(p, True))
            p.write_bytes(bytes(240) + b'1' * 16 + b'payloae')
            self.assertNotEqual(original, r.digest(p, True))
            p.write_bytes(bytes(255))
            with self.assertRaises(ValueError): r.digest(p, True)

    def test_restore_content_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'a.db'; p.write_bytes(b'expected')
            report = {'paths': {'gateway': tmp, 'captured_config': tmp},
                      'files': [{'path': 'gateway/a.db', 'size_bytes': 8, 'sha256': r.digest(p)}]}
            r.verify_restore(report)
            p.write_bytes(b'changed!')
            with self.assertRaises(ValueError): r.verify_restore(report)

    def test_sqlite_wal_checked_on_copy_without_modifying_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); data = root / 'gateway'; data.mkdir()
            p = data / 'test.db'
            conn = sqlite3.connect(p)
            try:
                conn.execute('PRAGMA journal_mode=WAL')
                conn.execute('CREATE TABLE readings(value INTEGER)')
                conn.execute('INSERT INTO readings VALUES (42)'); conn.commit()
                before = r.tree_hashes(data)
                checks = r.sqlite_checks({'paths': {'gateway': str(data), 'engine': str(root/'absent1'),
                                         'copilot': str(root/'absent2')}}, root)
                self.assertEqual(checks[0]['table_rows']['readings'], 1)
                self.assertEqual(before, r.tree_hashes(data))
            finally: conn.close()

    def test_truncated_query_baseline_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'checks.json'
            check = {'query': 'a@b >> collect()', 'expected_row_count': 1, 'expected_rows': [[1, 42]], 'limit': 1}
            p.write_text(json.dumps([check]))
            with self.assertRaises(ValueError): r.load_checks(p)
            check['limit'] = 2; p.write_text(json.dumps([check]))
            self.assertEqual(len(r.load_checks(p)), 1)

    def test_cleanup_requires_successful_docker_inventory(self):
        failure = subprocess.CompletedProcess([], 1, b'', b'daemon unavailable')
        with patch.object(r.subprocess, 'run', return_value=failure):
            with self.assertRaises(RuntimeError): r.remove_owned_container('fp-rehearse-example')
        present = subprocess.CompletedProcess([], 0, b'fp-rehearse-example\n', b'')
        with patch.object(r.subprocess, 'run', return_value=present):
            with self.assertRaises(RuntimeError): r.remove_owned_container('fp-rehearse-example')
        absent = subprocess.CompletedProcess([], 0, b'', b'')
        with patch.object(r.subprocess, 'run', side_effect=[failure, absent]):
            r.remove_owned_container('fp-rehearse-example')

if __name__ == '__main__': unittest.main()
