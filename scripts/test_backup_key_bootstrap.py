#!/usr/bin/env python3
"""fp_bootstrap_backup_key (shared/lib/bootstrap.sh) against a stubbed curl.

The backup key must be minted only by a Core that offers the backup lease, and
only when Core's answer lists exactly ["SYSTEM_BACKUP"]: an older Core ignores
the unknown permission name and mints a key with ALL of its owner's
permissions. No Docker, no network: `curl` is a shell function here.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / 'shared/lib/bootstrap.sh'

# A fake Core. FAKE_MODE: lease (default) | older | wide | down.
STUB = r'''
curl() {
    local method=GET url="" w="" auth="" input="" from_stdin=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -X) method="$2"; shift 2 ;;
            -H) if [ "$2" = "@-" ]; then from_stdin=1; else case "$2" in Authorization:*) auth="$2" ;; esac; fi; shift 2 ;;
            -w) w="$2"; shift 2 ;;
            -o|--max-time) shift 2 ;;
            --data-binary) from_stdin=1; shift 2 ;;
            http*) url="$1"; shift ;;
            *) shift ;;
        esac
    done
    if [ "$from_stdin" = 1 ]; then input="$(cat)"; fi
    case "$input" in Authorization:*) auth="$input" ;; esac
    printf '%s %s %s\n' "$method" "${url#http://127.0.0.1:7433}" "${auth#Authorization: Bearer }" >> "$CALLS"
    if [ "${FAKE_MODE:-lease}" = down ]; then
        [ -n "$w" ] && printf '\n000'
        return 7
    fi
    local body code
    case "$method ${url#http://127.0.0.1:7433}" in
        "POST /api/v1/auth/login")
            body='{"token":"jwt-admin","user":{"username":"admin"}}'; code=200 ;;
        "GET /api/v1/_system/backup/capability")
            case "$auth" in
                *"Bearer fp_good"*) body='{"lease":1,"max_ttl_s":86400}'; code=200 ;;
                *"Bearer jwt-admin"*)
                    if [ "${FAKE_MODE:-lease}" = older ]; then
                        body='{"server":{"version":"v0.1.4-alpha.140"}}'; code=200   # GET /api/v1/_system
                    else
                        body='{"lease":1,"max_ttl_s":86400,"catalog_wait_cap_ms":10000}'; code=200
                    fi ;;
                *) body='{"error":"Authentication required"}'; code=401 ;;
            esac ;;
        "POST /api/v1/tokens")
            if [ "${FAKE_MODE:-lease}" = wide ] || [ "${FAKE_MODE:-lease}" = older ]; then
                body='{"token":"fp_wide","id":"tok-9","name":"fp-backup","expires_at":null,"permissions":["DATA_READ","SYSTEM_ADMIN","SYSTEM_BACKUP"]}'
            else
                body='{"token":"fp_new","id":"tok-1","name":"fp-backup","expires_at":null,"permissions":["SYSTEM_BACKUP"]}'
            fi
            code=201 ;;
        "DELETE /api/v1/tokens/"*) body='{}'; code=200 ;;
        *) body='{"error":"Not found"}'; code=404 ;;
    esac
    if [ -n "$w" ]; then printf '%s\n%s' "$body" "$code"; else printf '%s' "$body"; fi
}
'''


class BackupKeyBootstrap(unittest.TestCase):
    def run_bootstrap(self, env_text, mode='lease', admin=True, env_mode=0o640):
        with tempfile.TemporaryDirectory(prefix='fp bk ') as tmp:
            env_file = Path(tmp) / '.env'
            env_file.write_text(env_text)
            env_file.chmod(env_mode)
            calls = Path(tmp) / 'calls'
            calls.write_text('')
            environ = {'PATH': os.environ['PATH'], 'CALLS': str(calls), 'FAKE_MODE': mode, 'NO_COLOR': '1'}
            if admin:
                environ.update(FP_ADMIN_USER='admin', FP_ADMIN_PASS='synthetic-pass-1')
            script = f'. "{BOOTSTRAP}"\n{STUB}\nfp_bootstrap_backup_key "{env_file}" 7433\necho "rc=$?"\n'
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, env=environ)
            self.assertIn('rc=0', result.stdout, result.stderr)
            return env_file.read_text(), calls.read_text().splitlines(), oct(env_file.stat().st_mode & 0o777), result.stderr

    def test_a_lease_core_gets_a_key_and_env_keeps_its_mode(self):
        text, calls, mode, _ = self.run_bootstrap('FP_VERSION=test\nFP_API_KEY=fp_gw\n')
        self.assertEqual(text.count('FP_BACKUP_KEY='), 1)
        self.assertIn('FP_BACKUP_KEY=fp_new\n', text)
        self.assertIn('FP_API_KEY=fp_gw\n', text)
        self.assertEqual(mode, '0o640')
        # Probed BEFORE the mint, with the admin token.
        probe = calls.index('GET /api/v1/_system/backup/capability jwt-admin')
        mint = calls.index('POST /api/v1/tokens jwt-admin')
        self.assertLess(probe, mint)

    def test_an_older_core_is_never_asked_to_mint(self):
        text, calls, _, _ = self.run_bootstrap('FP_VERSION=test\n', mode='older')
        self.assertNotIn('FP_BACKUP_KEY', text)
        self.assertFalse([c for c in calls if c.startswith('POST /api/v1/tokens')],
                         'a key minted on an older Core would be a full admin key')

    def test_a_wider_key_is_revoked_and_never_stored(self):
        text, calls, _, err = self.run_bootstrap('FP_VERSION=test\n', mode='wide')
        self.assertNotIn('FP_BACKUP_KEY', text)
        self.assertIn('DELETE /api/v1/tokens/tok-9 ', [c[:len('DELETE /api/v1/tokens/tok-9 ')] for c in calls])
        self.assertIn('revoked', err)

    def test_a_working_key_is_kept_without_a_login(self):
        text, calls, _, _ = self.run_bootstrap('FP_BACKUP_KEY=fp_good\n')
        self.assertIn('FP_BACKUP_KEY=fp_good\n', text)
        self.assertEqual(calls, ['GET /api/v1/_system/backup/capability fp_good'])

    def test_a_refused_key_is_replaced(self):
        text, _, _, _ = self.run_bootstrap('FP_BACKUP_KEY=fp_revoked\nFP_VERSION=test\n')
        self.assertEqual(text.count('FP_BACKUP_KEY='), 1)
        self.assertIn('FP_BACKUP_KEY=fp_new\n', text)
        self.assertIn('FP_VERSION=test\n', text)

    def test_no_login_no_key_is_not_an_error(self):
        text, calls, _, err = self.run_bootstrap('FP_VERSION=test\n', admin=False)
        self.assertNotIn('FP_BACKUP_KEY', text)
        self.assertEqual(calls, [])
        self.assertIn('fp backup', err)

    def test_an_unreachable_core_keeps_the_key(self):
        text, _, _, _ = self.run_bootstrap('FP_BACKUP_KEY=fp_good\n', mode='down')
        self.assertIn('FP_BACKUP_KEY=fp_good\n', text)


if __name__ == '__main__':
    unittest.main()
