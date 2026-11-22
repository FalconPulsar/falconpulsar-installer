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

    # The outside assistant service is on by default. The upgrade migration
    # (fp_migrate_mcp_setting, run by fp_try_upgrade_fastpath) adds
    # FP_MCP_ENABLED=true when absent, keeps "mcp" in COMPOSE_PROFILES in
    # step with it, and leaves FP_MCP_ENABLED=false off.
    COMMON = ROOT / 'shared/lib/common.sh'

    def shell_with_common(self, script, env=None):
        prelude = f'. "{self.COMMON}"\n. "{EXISTING}"\n'
        return subprocess.run(['bash', '-c', prelude + script], capture_output=True, text=True, env=env)

    def migrate(self, content):
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / '.env'
            env_file.write_bytes(content.encode())
            first = self.shell_with_common(f'fp_migrate_mcp_setting "{env_file}"')
            self.assertEqual(first.returncode, 0, first.stderr)
            after = env_file.read_bytes().decode()
            second = self.shell_with_common(f'fp_migrate_mcp_setting "{env_file}"')
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(env_file.read_bytes().decode(), after, 'a second run must change nothing')
            self.assertEqual(second.stderr, '', 'a second run must log nothing')
            return after, first.stderr

    @staticmethod
    def last(content, key):
        values = [l.rstrip('\r')[len(key) + 1:] for l in content.split('\n') if l.startswith(key + '=')]
        return values[-1] if values else None

    def test_mcp_absent_is_switched_on(self):
        after, log = self.migrate('FP_UID=1000\nCOMPOSE_PROFILES=copilot\nFP_MCP_TOKEN=abc\n')
        self.assertEqual(self.last(after, 'FP_MCP_ENABLED'), 'true')
        self.assertEqual(self.last(after, 'COMPOSE_PROFILES'), 'copilot,mcp')
        self.assertIn('added FP_MCP_ENABLED=true', log)
        self.assertIn('added mcp to COMPOSE_PROFILES', log)
        # No COMPOSE_PROFILES key and no final newline: both keys are added
        # on lines of their own.
        after, _ = self.migrate('FP_UID=1000')
        self.assertTrue(after.startswith('FP_UID=1000\n'), after)
        self.assertEqual(self.last(after, 'FP_MCP_ENABLED'), 'true')
        self.assertEqual(self.last(after, 'COMPOSE_PROFILES'), 'mcp')

    def test_mcp_false_stays_off_and_profile_is_removed(self):
        after, log = self.migrate('FP_MCP_ENABLED=false\nCOMPOSE_PROFILES="copilot, mcp,copilot"\nFP_UID=1000\n')
        self.assertEqual(self.last(after, 'FP_MCP_ENABLED'), 'false')
        self.assertEqual(self.last(after, 'COMPOSE_PROFILES'), 'copilot')
        self.assertEqual(after.count('FP_MCP_ENABLED='), 1)
        self.assertIn('removed mcp from COMPOSE_PROFILES', log)
        # Already off: nothing to do, nothing logged.
        after, log = self.migrate('FP_MCP_ENABLED=False\r\nCOMPOSE_PROFILES=copilot\r\n')
        self.assertEqual(after, 'FP_MCP_ENABLED=False\r\nCOMPOSE_PROFILES=copilot\r\n')
        self.assertEqual(log, '')

    def test_mcp_true_with_copilot_gets_both_profiles(self):
        after, _ = self.migrate('FP_MCP_ENABLED=true\r\nCOMPOSE_PROFILES=copilot\r\nCOMPOSE_PROFILES=copilot\r\n')
        self.assertEqual(self.last(after, 'COMPOSE_PROFILES'), 'copilot,mcp')
        self.assertEqual(after.count('COMPOSE_PROFILES=copilot,mcp'), 2, 'every COMPOSE_PROFILES line agrees')
        # Already in step: left exactly as it was.
        after, log = self.migrate('FP_MCP_ENABLED=true\nCOMPOSE_PROFILES=copilot, mcp\n')
        self.assertEqual(after, 'FP_MCP_ENABLED=true\nCOMPOSE_PROFILES=copilot, mcp\n')
        self.assertEqual(log, '')

    def run_fastpath(self, env_content, mcp_container_exists):
        """Runs the upgrade fast path with docker stubbed; returns (.env, docker calls)."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / 'stack'
            home.mkdir()
            (home / 'compose.yml').write_text('services: {}\n')
            (home / '.env').write_text(env_content)
            calls = Path(tmp) / 'docker-calls'
            ps_out = 'abc123' if mcp_container_exists else ''
            script = (
                f'REPO_ROOT="{ROOT}"; FP_INSTALL_ACTION=upgrade\n'
                f'docker() {{ echo "$*" >> "{calls}"; case "$1" in ps) echo "{ps_out}" ;; esac; return 0; }}\n'
                'fp_compose_pull_with_retry() { return 0; }\n'
                'fp_core_upgrade_preflight() { return 0; }\n'
                # Stops the fast path right after its `up -d`.
                'fp_wait_upgrade_container() { return 1; }\n'
                f'fp_try_upgrade_fastpath "{home}"; echo "rc=$?"\n')
            result = self.shell_with_common('set +e\n' + script)
            self.assertIn('rc=2', result.stdout, result.stderr)
            return (home / '.env').read_text(), calls.read_text() if calls.exists() else ''

    def test_upgrade_fastpath_starts_mcp_by_default(self):
        env, calls = self.run_fastpath('FP_COPILOT_ENABLED=true\nCOMPOSE_PROFILES=copilot\nFP_MCP_TOKEN=abc\n', False)
        self.assertEqual(self.last(env, 'FP_MCP_ENABLED'), 'true')
        self.assertEqual(self.last(env, 'COMPOSE_PROFILES'), 'copilot,mcp')
        self.assertIn('compose --profile ai --profile copilot --profile mcp up -d', calls)
        self.assertNotIn('rm -sf mcp', calls)

    def test_upgrade_fastpath_leaves_mcp_off_and_removes_it(self):
        env, calls = self.run_fastpath('FP_MCP_ENABLED=false\nCOMPOSE_PROFILES=mcp\nFP_MCP_TOKEN=abc\n', True)
        self.assertEqual(self.last(env, 'FP_MCP_ENABLED'), 'false')
        self.assertEqual(self.last(env, 'COMPOSE_PROFILES'), '')
        self.assertIn('compose --profile mcp rm -sf mcp', calls)
        self.assertIn('compose --profile ai up -d', calls)
        self.assertNotIn('--profile mcp up', calls)

    def test_install_writes_mcp_on_unless_turned_off(self):
        # The full install and a reinstall build COMPOSE_PROFILES here; a
        # reinstall seeds FP_MCP_ENABLED from the old .env first.
        prompts = ROOT / 'shared/lib/prompts.sh'
        for flag, copilot, want_flag, want_profiles in [
                ('', 'true', 'true', 'copilot,mcp'),
                ('true', 'false', 'true', 'mcp'),
                ('FALSE', 'true', 'false', 'copilot')]:
            with self.subTest(flag=flag, copilot=copilot):
                set_flag = f'FP_MCP_ENABLED={flag}; ' if flag else 'unset FP_MCP_ENABLED; '
                result = self.shell_with_common(
                    f'. "{prompts}"\n{set_flag}FP_COPILOT_ENABLED={copilot}; fp_refresh_compose_profiles; '
                    'echo "$FP_MCP_ENABLED $COMPOSE_PROFILES"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f'{want_flag} {want_profiles}')
        for platform in ['linux', 'macos']:
            text = (ROOT / platform / 'install.sh').read_text()
            self.assertIn('FP_COPILOT_ENABLED FP_COPILOT_PORT FP_MCP_ENABLED', text,
                          f'{platform}: a reinstall must carry FP_MCP_ENABLED forward')
            self.assertIn('FP_MCP_ENABLED=${FP_MCP_ENABLED}', text, f'{platform}: .env must record the setting')

if __name__ == '__main__': unittest.main()
