// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

package configbackup

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
)

func TestImportStoresStayAtTargetPaths(t *testing.T) {
	for _, relocated := range []bool{false, true} {
		t.Run(map[bool]string{false: "default-target", true: "relocated-target"}[relocated], func(t *testing.T) {
			home, source := t.TempDir(), t.TempDir()
			t.Setenv("FP_HOME", home)
			entries := map[string]string{"manifest.json": `{}`}
			var sourceEnv, targetEnv strings.Builder
			for _, store := range []struct{ key, dir, rel, entry string }{
				{"FP_GATEWAY_DATA_DIR", "ai-gateway-data", "ai_config.db", "ai_config.db"},
				{"FP_ENGINE_DATA_DIR", "ai-engine-data", "db/fp-agentics.db", "db_fp-agentics.db"},
				{"FP_COPILOT_DATA_DIR", "copilot-data", "command-center.db", "command-center.db"},
			} {
				src := filepath.Join(source, store.dir, store.rel)
				if err := os.MkdirAll(filepath.Dir(src), 0700); err != nil {
					t.Fatal(err)
				}
				for _, suffix := range []string{"", "-wal", "-shm"} {
					if err := os.WriteFile(src+suffix, []byte("source-untouched"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				sourceEnv.WriteString(store.key + "=" + filepath.Join(source, store.dir) + "\n")
				dir := filepath.Join(home, store.dir)
				if relocated {
					dir = filepath.Join(home, "relocated", store.dir)
					targetEnv.WriteString(store.key + "=" + dir + "\n")
				}
				dst := filepath.Join(dir, store.rel)
				if err := os.MkdirAll(filepath.Dir(dst), 0700); err != nil {
					t.Fatal(err)
				}
				for _, suffix := range []string{"", "-wal", "-shm"} {
					if err := os.WriteFile(dst+suffix, []byte("old-target"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				entries["files/"+store.entry] = "restored-config"
				defer func() {
					for _, suffix := range []string{"", "-wal", "-shm"} {
						if got := mustRead(t, src+suffix); got != "source-untouched" {
							t.Errorf("source changed: %s", src+suffix)
						}
					}
					if got := mustRead(t, dst); got != "restored-config" {
						t.Errorf("target not restored: %s", dst)
					}
					for _, suffix := range []string{"-wal", "-shm"} {
						if _, err := os.Stat(dst + suffix); !os.IsNotExist(err) {
							t.Errorf("target sidecar remains: %s", dst+suffix)
						}
					}
				}()
			}
			entries["files/.env"] = sourceEnv.String()
			if err := os.WriteFile(filepath.Join(home, ".env"), []byte(targetEnv.String()), 0600); err != nil {
				t.Fatal(err)
			}
			archive := writeInspectFixture(t, entries, "", FormatVersion)
			if _, err := Import(context.Background(), archive, api.New(), "fixture-admin", "fixture-password"); err != nil {
				t.Fatal(err)
			}
			if strings.Contains(mustRead(t, filepath.Join(home, ".env")), source) {
				t.Error("source data paths survived into the target configuration")
			}
		})
	}
}

// envMap parses a KEY=VALUE .env body into a map (skips comments/blanks).
func envMap(body string) map[string]string {
	m := map[string]string{}
	for _, line := range strings.Split(body, "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		if eq := strings.IndexByte(t, '='); eq > 0 {
			m[t[:eq]] = t[eq+1:]
		}
	}
	return m
}

func TestReadEnvValues(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, ".env")
	body := "# comment\n" +
		"FP_ADMIN_USER=admin\n" +
		"FP_DATA_DIR=/home/fpuser/falconpulsar/data\n" +
		"FP_UID=1000\n" +
		"FP_GID=1000\n" +
		"\n" +
		"FP_REST_PORT=7433\n"
	if err := os.WriteFile(p, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	got := readEnvValues(p, machineSpecificEnvKeys)
	if got["FP_DATA_DIR"] != "/home/fpuser/falconpulsar/data" {
		t.Errorf("FP_DATA_DIR = %q", got["FP_DATA_DIR"])
	}
	if got["FP_UID"] != "1000" || got["FP_GID"] != "1000" {
		t.Errorf("uid/gid = %q/%q", got["FP_UID"], got["FP_GID"])
	}
	// Portable / absent keys must not be captured.
	if _, ok := got["FP_ADMIN_USER"]; ok {
		t.Error("FP_ADMIN_USER should not be captured (not machine-specific)")
	}
	if _, ok := got["FP_GATEWAY_DATA_DIR"]; ok {
		t.Error("absent key should be omitted")
	}
	// Missing file → empty map, no panic.
	if len(readEnvValues(filepath.Join(dir, "nope.env"), machineSpecificEnvKeys)) != 0 {
		t.Error("missing file should yield empty map")
	}
}

// TestSanitizePreservesHostPaths reproduces the exact reported incident: a
// backup exported on macOS (FP_DATA_DIR=/Users/... , FP_UID=501) restored onto
// a WSL host (FP_DATA_DIR=/home/fpuser/... , FP_UID=1000). After restore the
// host-specific keys must be the TARGET's, while secrets/ports/flags carry from
// the backup. If they weren't preserved, core would bind-mount a non-existent
// path and crash-loop on first-run init.
func TestSanitizePreservesHostPaths(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, ".env")

	// The TARGET (WSL) .env that exists before the restore overwrites it.
	targetBefore := "FP_DATA_DIR=/home/fpuser/falconpulsar/data\n" +
		"FP_GATEWAY_DATA_DIR=/home/fpuser/falconpulsar/ai-gateway-data\n" +
		"FP_ENGINE_DATA_DIR=/home/fpuser/falconpulsar/ai-engine-data\n" +
		"FP_GATEWAY_CONFIG=/home/fpuser/falconpulsar/gateway.yaml\n" +
		"FP_UID=1000\n" +
		"FP_GID=1000\n" +
		"FP_API_KEY=old-target-token\n"
	if err := os.WriteFile(p, []byte(targetBefore), 0600); err != nil {
		t.Fatal(err)
	}
	// Capture as the restore does, BEFORE the backup overwrites .env.
	preserved := readEnvValues(p, machineSpecificEnvKeys)

	// The backup's .env (from the Mac) now overwrites the file verbatim.
	macBackup := "FP_ADMIN_USER=admin\n" +
		"FP_DATA_DIR=/Users/exampleuser/falconpulsar/data\n" +
		"FP_GATEWAY_DATA_DIR=/Users/exampleuser/falconpulsar/ai-gateway-data\n" +
		"FP_ENGINE_DATA_DIR=/Users/exampleuser/falconpulsar/ai-engine-data\n" +
		"FP_GATEWAY_CONFIG=/Users/exampleuser/falconpulsar/gateway.yaml\n" +
		"FP_UID=501\n" +
		"FP_GID=20\n" +
		"FP_REST_PORT=7433\n" +
		"FP_AI_GATEWAY_ENABLED=false\n" +
		"FP_BRIDGE_TOKEN=shared-secret\n" +
		"FP_API_KEY=restored-token\n"
	if err := os.WriteFile(p, []byte(macBackup), 0600); err != nil {
		t.Fatal(err)
	}

	sanitizeRestoredEnv(p, preserved)

	out, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	m := envMap(string(out))

	// Host-specific keys MUST be the target's (WSL), not the backup's (Mac).
	wantTarget := map[string]string{
		"FP_DATA_DIR":         "/home/fpuser/falconpulsar/data",
		"FP_GATEWAY_DATA_DIR": "/home/fpuser/falconpulsar/ai-gateway-data",
		"FP_ENGINE_DATA_DIR":  "/home/fpuser/falconpulsar/ai-engine-data",
		"FP_GATEWAY_CONFIG":   "/home/fpuser/falconpulsar/gateway.yaml",
		"FP_UID":              "1000",
		"FP_GID":              "1000",
	}
	for k, want := range wantTarget {
		if m[k] != want {
			t.Errorf("%s = %q, want target value %q (must not transplant the backup's)", k, m[k], want)
		}
	}
	if strings.Contains(string(out), "/Users/exampleuser") {
		t.Error("no macOS host path may survive into the restored .env")
	}

	// Portable keys MUST carry from the backup.
	if m["FP_BRIDGE_TOKEN"] != "shared-secret" {
		t.Errorf("FP_BRIDGE_TOKEN = %q, want carried from backup", m["FP_BRIDGE_TOKEN"])
	}
	if m["FP_API_KEY"] != "restored-token" {
		t.Errorf("FP_API_KEY = %q, want the backup's (pairs with restored DB)", m["FP_API_KEY"])
	}
	if m["FP_REST_PORT"] != "7433" {
		t.Errorf("FP_REST_PORT = %q, want carried from backup", m["FP_REST_PORT"])
	}
	// The legacy AI flag must still be forced true.
	if m["FP_AI_GATEWAY_ENABLED"] != "true" {
		t.Errorf("FP_AI_GATEWAY_ENABLED = %q, want true", m["FP_AI_GATEWAY_ENABLED"])
	}
}

// TestSanitizeAppendsMissingPreservedKey covers a backup whose .env lacks a key
// the target had (e.g. older backup without FP_GATEWAY_CONFIG): the target's
// value must be appended, not dropped.
func TestSanitizeAppendsMissingPreservedKey(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, ".env")

	if err := os.WriteFile(p, []byte("FP_GATEWAY_CONFIG=/home/fpuser/falconpulsar/gateway.yaml\nFP_UID=1000\n"), 0600); err != nil {
		t.Fatal(err)
	}
	preserved := readEnvValues(p, machineSpecificEnvKeys)

	// Backup lacks FP_GATEWAY_CONFIG entirely.
	if err := os.WriteFile(p, []byte("FP_UID=501\nFP_REST_PORT=7433\n"), 0600); err != nil {
		t.Fatal(err)
	}
	sanitizeRestoredEnv(p, preserved)

	out, _ := os.ReadFile(p)
	m := envMap(string(out))
	if m["FP_GATEWAY_CONFIG"] != "/home/fpuser/falconpulsar/gateway.yaml" {
		t.Errorf("FP_GATEWAY_CONFIG = %q, want appended target value", m["FP_GATEWAY_CONFIG"])
	}
	if m["FP_UID"] != "1000" {
		t.Errorf("FP_UID = %q, want target 1000", m["FP_UID"])
	}
}

// TestSanitizeNoPreservedIsNoop confirms a same-host restore (no target keys to
// preserve, e.g. bare-machine DR) leaves the backup's values intact and only
// fixes the legacy AI flag.
func TestSanitizeNoPreservedIsNoop(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, ".env")
	body := "FP_DATA_DIR=/data/x\nFP_UID=1000\nFP_AI_GATEWAY_ENABLED=false\n"
	if err := os.WriteFile(p, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	sanitizeRestoredEnv(p, map[string]string{})
	m := envMap(mustRead(t, p))
	if m["FP_DATA_DIR"] != "/data/x" {
		t.Errorf("FP_DATA_DIR = %q, want backup value preserved when nothing to override", m["FP_DATA_DIR"])
	}
	if m["FP_AI_GATEWAY_ENABLED"] != "true" {
		t.Errorf("FP_AI_GATEWAY_ENABLED = %q, want true", m["FP_AI_GATEWAY_ENABLED"])
	}
}

func mustRead(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
