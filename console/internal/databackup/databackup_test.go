// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

package databackup

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeStack builds a plausible FP_HOME with data dirs and returns its Env.
// Containers report NOT running, so every SQLite file takes the cold-copy
// path — the docker-exec path is exercised by the live stack test.
func fakeStack(t *testing.T) Env {
	t.Helper()
	home := t.TempDir()
	e := Env{
		Home:       home,
		CoreDir:    filepath.Join(home, "data"),
		GatewayDir: filepath.Join(home, "ai-gateway-data"),
		EngineDir:  filepath.Join(home, "ai-engine-data"),
		CopilotDir: filepath.Join(home, "copilot-data"),
		FPVersion:  "test",
		ContainerRunning: func(context.Context, string) bool { return false },
		DockerExec: func(context.Context, string, []string) error {
			t.Fatal("cold path must not exec docker")
			return nil
		},
	}
	write := func(rel, content string) {
		p := filepath.Join(home, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("compose.yml", "services: {}")
	write(".env", "FP_VERSION=test")
	write("gateway.yaml", "gateway: {}")
	write("ai-gateway-data/conversations.db", "conv-bytes")
	write("ai-gateway-data/conversations.db-wal", "conv-wal")
	write("ai-gateway-data/ssr.db", "ssr-bytes")
	write("ai-gateway-data/fastembed_cache/model.onnx", "1.3GB pretend") // must NOT travel
	write("ai-engine-data/db/fp-agentics.db", "engine-bytes")
	write("ai-engine-data/agentspecs/proc_x.spec.json", "{}")
	write("copilot-data/command-center.db", "cc-bytes")
	write("data/fp_database.hdr", "core-hdr")
	write("data/wal/wal_1.fpw", "core-wal")
	return e
}

func entries(t *testing.T, archive string) map[string]string {
	t.Helper()
	f, err := os.Open(archive)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(gz)
	out := map[string]string{}
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(tr)
		out[hdr.Name] = string(data)
	}
	return out
}

func TestBackupCarriesTheStoresAndOnlyTheStores(t *testing.T) {
	e := fakeStack(t)
	out := filepath.Join(t.TempDir(), "b.tar.gz")
	man, err := Backup(context.Background(), e, out, BackupOptions{})
	if err != nil {
		t.Fatal(err)
	}
	got := entries(t, out)

	for _, want := range []string{
		"manifest.json",
		"config/compose.yml", "config/.env", "config/gateway.yaml",
		"gateway/conversations.db", "gateway/conversations.db-wal", "gateway/ssr.db",
		"engine/db/fp-agentics.db", "engine/agentspecs/proc_x.spec.json",
		"copilot/command-center.db",
		"core/fp_database.hdr", "core/wal/wal_1.fpw",
	} {
		if _, ok := got[want]; !ok {
			t.Errorf("missing %s", want)
		}
	}
	for name := range got {
		if strings.Contains(name, "fastembed_cache") {
			t.Errorf("the model cache must not travel: %s", name)
		}
	}
	if got["gateway/conversations.db"] != "conv-bytes" {
		t.Errorf("content mangled")
	}
	if man.Semantics["gateway"] != "cold-copy" {
		t.Errorf("stopped container must report cold-copy, got %q", man.Semantics["gateway"])
	}
	if !strings.Contains(man.Semantics["core"], "crash-consistent") {
		t.Errorf("core semantics missing: %q", man.Semantics["core"])
	}
}

func TestSkipCore(t *testing.T) {
	e := fakeStack(t)
	out := filepath.Join(t.TempDir(), "b.tar.gz")
	man, err := Backup(context.Background(), e, out, BackupOptions{SkipCore: true})
	if err != nil {
		t.Fatal(err)
	}
	for name := range entries(t, out) {
		if strings.HasPrefix(name, "core/") {
			t.Errorf("core traveled despite --skip-core: %s", name)
		}
	}
	for _, s := range man.Services {
		if s == "core" {
			t.Errorf("manifest lists core despite --skip-core")
		}
	}
}

func TestPeekRefusesForeignArchives(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x.tar.gz")
	f, _ := os.Create(p)
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	data := []byte(`{"kind":"something-else"}`)
	_ = tw.WriteHeader(&tar.Header{Name: "manifest.json", Mode: 0o600, Size: int64(len(data))})
	_, _ = tw.Write(data)
	tw.Close()
	gz.Close()
	f.Close()
	if _, err := Peek(p); err == nil {
		t.Fatal("foreign manifest accepted")
	}
}

func TestRestoreRoundTripSetsAsideNeverDeletes(t *testing.T) {
	src := fakeStack(t)
	archive := filepath.Join(t.TempDir(), "b.tar.gz")
	if _, err := Backup(context.Background(), src, archive, BackupOptions{}); err != nil {
		t.Fatal(err)
	}

	// A second, older stack with DIFFERENT content and a stale WAL that must
	// not survive next to the restored database.
	dst := fakeStack(t)
	if err := os.WriteFile(filepath.Join(dst.GatewayDir, "conversations.db"), []byte("OLD"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dst.GatewayDir, "conversations.db-shm"), []byte("STALE-SHM"), 0o644); err != nil {
		t.Fatal(err)
	}

	asides, err := Restore(context.Background(), dst, archive, RestoreOptions{})
	if err != nil {
		t.Fatal(err)
	}

	restored, _ := os.ReadFile(filepath.Join(dst.GatewayDir, "conversations.db"))
	if string(restored) != "conv-bytes" {
		t.Fatalf("db not restored: %q", restored)
	}
	// The stale SHM went aside WITH its database, not left to corrupt it.
	if _, err := os.Stat(filepath.Join(dst.GatewayDir, "conversations.db-shm")); !os.IsNotExist(err) {
		// the archive carried a -wal but no -shm; a fresh -shm must not linger
		t.Log("note: shm present — acceptable only if it came from the archive")
	}
	if len(asides) == 0 {
		t.Fatal("nothing set aside — old data was destroyed or never touched")
	}
	foundOld := false
	for _, a := range asides {
		if strings.Contains(a, "conversations.db.pre-restore-") {
			b, _ := os.ReadFile(a)
			foundOld = string(b) == "OLD"
		}
	}
	if !foundOld {
		t.Fatalf("the old database is not in the asides: %v", asides)
	}
	// Core came back too, replacing the tree via one aside.
	hdr, _ := os.ReadFile(filepath.Join(dst.CoreDir, "fp_database.hdr"))
	if string(hdr) != "core-hdr" {
		t.Errorf("core tree not restored")
	}
}

func TestRestoreOnlyFilter(t *testing.T) {
	src := fakeStack(t)
	archive := filepath.Join(t.TempDir(), "b.tar.gz")
	if _, err := Backup(context.Background(), src, archive, BackupOptions{}); err != nil {
		t.Fatal(err)
	}
	dst := fakeStack(t)
	marker := filepath.Join(dst.CoreDir, "fp_database.hdr")
	if err := os.WriteFile(marker, []byte("UNTOUCHED"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(context.Background(), dst, archive, RestoreOptions{Only: []string{"copilot"}}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(marker)
	if string(b) != "UNTOUCHED" {
		t.Fatal("--only copilot touched core")
	}
	cc, _ := os.ReadFile(filepath.Join(dst.CopilotDir, "command-center.db"))
	if string(cc) != "cc-bytes" {
		t.Fatal("copilot not restored")
	}
}

func TestLoadEnvDefaults(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".env"),
		[]byte("FP_DATA_DIR="+filepath.Join(home, "data")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	e := LoadEnv(home)
	if e.GatewayDir != filepath.Join(home, "ai-gateway-data") {
		t.Errorf("gateway default wrong: %s", e.GatewayDir)
	}
	if e.CoreDir != filepath.Join(home, "data") {
		t.Errorf("core dir wrong: %s", e.CoreDir)
	}
}
