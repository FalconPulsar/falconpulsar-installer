package configbackup

// The same feature is implemented three times — Go here, Swift in
// macos/menu-bar-app/FalconPulsar/ConfigBackup.swift, C# in
// windows/tray-app/ConfigBackup.cs — and nothing checked they agreed.
//
// They drifted, and the drift was invisible: an archive written on macOS and an
// archive written by the console were supposed to be interchangeable, and the
// only way to discover they were not was to try a restore on a rebuilt plant.
//
// These tests read the other two implementations as TEXT and assert that the
// facts which must match actually do. They are deliberately shallow — they
// cannot compile Swift or C# — but they fail the moment one implementation
// learns something the others do not, which is the failure mode that mattered.
//
// Windows note: ConfigBackup.cs cannot be compiled on macOS or Linux (WinForms
// has no runtime pack for those), so a textual check is the ONLY automated
// signal available for it. Treat a failure here as real.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	// .../console/internal/configbackup -> repo root
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	root := filepath.Clean(filepath.Join(wd, "..", "..", ".."))
	if _, err := os.Stat(filepath.Join(root, "console")); err != nil {
		t.Skipf("repo layout not as expected from %s; skipping conformance", wd)
	}
	return root
}

func readImpl(t *testing.T, rel string) string {
	t.Helper()
	p := filepath.Join(repoRoot(t), rel)
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("cannot read %s: %v", rel, err)
	}
	return string(data)
}

func implementations(t *testing.T) map[string]string {
	t.Helper()
	return map[string]string{
		"swift":  readImpl(t, "macos/menu-bar-app/FalconPulsar/ConfigBackup.swift"),
		"csharp": readImpl(t, "windows/tray-app/ConfigBackup.cs"),
	}
}

// Every zip entry the Go implementation writes must be known to the others, or
// an archive from one silently loses sections when read by another.
func TestAllImplementationsKnowTheSameArchiveEntries(t *testing.T) {
	entries := []string{
		"manifest.json",
		"files/compose.yml",
		"files/.env",
		"files/gateway.yaml",
		"files/ai_config.db",
		"files/ssr.db",
		"files/knowledge.db",
		"files/watches.db",
		"files/db_fp-agentics.db",
		"files/command-center.db",
		"api/roles.json",
		"api/users.json",
		"api/asset-types.json",
		"api/assets.json",
		"api/datasources.json",
		"api/series.json",
		"api/mappings.json",
		"api/relationships.json",
		"api/annotations.json",
		"api/config-bundle.json",
	}
	for name, src := range implementations(t) {
		for _, e := range entries {
			// The entry may be built by concatenation ("files/" + rel), so look
			// for the distinctive tail rather than the whole literal.
			needle := e
			if i := strings.LastIndex(e, "/"); i >= 0 {
				needle = e[i+1:]
			}
			if !strings.Contains(src, needle) {
				t.Errorf("%s does not mention archive entry %q — an archive containing it would lose that section", name, e)
			}
		}
	}
}

// The secret mask must be known to every implementation, or one of them will
// happily write "********" back as a real credential.
func TestAllImplementationsKnowTheSecretMask(t *testing.T) {
	for name, src := range implementations(t) {
		if !strings.Contains(src, secretMask) {
			t.Errorf("%s does not know the secret mask %q — it would store the mask as a credential", name, secretMask)
		}
		for _, key := range secretConfigKeys {
			if !strings.Contains(src, key) {
				t.Errorf("%s does not handle the secret config key %q", name, key)
			}
		}
		if !strings.Contains(src, "datasource_secrets") {
			t.Errorf("%s does not read the bundle's datasource_secrets — restored datasources would have no credentials", name)
		}
	}
}

// Machine-specific .env keys must be preserved from the target host by all
// three, or a cross-host restore breaks the stack in a different way per
// platform.
func TestAllImplementationsPreserveTheSameEnvKeys(t *testing.T) {
	for name, src := range implementations(t) {
		for _, key := range machineSpecificEnvKeys {
			if !strings.Contains(src, key) {
				t.Errorf("%s does not preserve %s from the target host on import", name, key)
			}
		}
	}
}

// The archive is a single format. If one implementation writes a version the
// others reject, backups stop being portable between platforms.
func TestAllImplementationsAgreeOnFormatAndCrypto(t *testing.T) {
	for name, src := range implementations(t) {
		if !strings.Contains(src, "FPCF") {
			t.Errorf("%s does not carry the archive magic — archives would not be portable", name)
		}

		// Swift and C# both write large literals with digit separators
		// (100_000). Comparing against the bare digits both misses those and
		// matches unrelated numbers elsewhere in the file — the first version of
		// this check "passed" for Swift only because a comment mentioned
		// limit=100000. Strip separators, and require the constant to appear as
		// a whole token so a substring of some other number cannot satisfy it.
		normalized := strings.ReplaceAll(src, "_", "")
		for _, fact := range []struct {
			value int
			what  string
		}{
			{Iterations, "PBKDF2 iteration count"},
			{FormatVersion, "format version"},
		} {
			if !containsNumberToken(normalized, fact.value) {
				t.Errorf("%s does not carry the %s (%d) — archives would not be portable",
					name, fact.what, fact.value)
			}
		}
	}
}

// containsNumberToken reports whether n appears in src as a complete number,
// not as a run of digits inside a longer one (so 3 does not match 300000).
func containsNumberToken(src string, n int) bool {
	lit := fmt.Sprintf("%d", n)
	isDigit := func(b byte) bool { return b >= '0' && b <= '9' }
	for i := 0; ; {
		j := strings.Index(src[i:], lit)
		if j < 0 {
			return false
		}
		start := i + j
		end := start + len(lit)
		beforeOK := start == 0 || !isDigit(src[start-1])
		afterOK := end == len(src) || !isDigit(src[end])
		if beforeOK && afterOK {
			return true
		}
		i = start + 1
	}
}

// A WAL-mode database read straight off the host is missing whatever is still
// in its -wal sidecar. Every implementation must go through VACUUM INTO.
func TestAllImplementationsSnapshotSQLiteSafely(t *testing.T) {
	for name, src := range implementations(t) {
		if !strings.Contains(src, "VACUUM INTO") {
			t.Errorf("%s does not use VACUUM INTO — it would capture a WAL database missing its most recent writes", name)
		}
		for _, sidecar := range []string{"-wal", "-shm"} {
			if !strings.Contains(src, sidecar) {
				t.Errorf("%s never mentions %s — a stale sidecar would revert or corrupt a restored database", name, sidecar)
			}
		}
	}
}

// The data directories are relocatable. An implementation that hardcodes one
// silently captures nothing on a relocated stack.
func TestNoImplementationHardcodesADataDir(t *testing.T) {
	for name, src := range implementations(t) {
		for _, key := range []string{
			"FP_GATEWAY_DATA_DIR", "FP_ENGINE_DATA_DIR", "FP_COPILOT_DATA_DIR",
		} {
			if !strings.Contains(src, key) {
				t.Errorf("%s does not honour %s — a relocated stack would export no AI state at all", name, key)
			}
		}
	}
}

// An export that could not capture everything must never present itself as a
// clean success.
func TestAllImplementationsReportAnIncompleteExport(t *testing.T) {
	for name, src := range implementations(t) {
		lower := strings.ToLower(src)
		if !strings.Contains(lower, "incomplete") {
			t.Errorf("%s has no notion of an incomplete export — a backup missing whole sections would report success", name)
		}
	}
}
