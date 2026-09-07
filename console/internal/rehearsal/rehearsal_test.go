// SPDX-License-Identifier: AGPL-3.0-only
package rehearsal

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/databackup"
)

func nativeFixture(t *testing.T) (string, string) {
	t.Helper()
	home := t.TempDir()
	files := map[string]string{
		"compose.yml": "services: {}\n", ".env": "FP_DATA_DIR=/production/data\n",
		"gateway.yaml": "token: captured-secret\n", "engine-seccomp.json": "{}",
		"core/fp_database.hdr": "old-core-header", "core/fractal/1/1/2026.fpf": "old-core-points", "core/wal/wal_1.fpw": "old-core-wal",
		"gateway/conversations.db": "SQLite format 3\x00main", "gateway/conversations.db-wal": "cold-wal-pages", "gateway/conversations.db-shm": "cold-shared-index",
		"engine/db/fp-agentics.db": "engine-db", "engine/agentspecs/agent.json": "{}", "copilot/command-center.db": "copilot-db",
	}
	for name, content := range files {
		p := filepath.Join(home, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	env := databackup.Env{Home: home, CoreDir: filepath.Join(home, "core"), GatewayDir: filepath.Join(home, "gateway"), EngineDir: filepath.Join(home, "engine"), CopilotDir: filepath.Join(home, "copilot"), ContainerRunning: func(context.Context, string) bool { return false }, DockerExec: func(context.Context, string, []string) error { t.Fatal("Docker must never run"); return nil }}
	archive := filepath.Join(t.TempDir(), "native.tar.gz")
	if _, err := databackup.Backup(context.Background(), env, archive, databackup.BackupOptions{}); err != nil {
		t.Fatal(err)
	}
	return archive, home
}

func digest(t *testing.T, p string) string {
	t.Helper()
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

func TestNativeBackupInspectAndIsolatedRestore(t *testing.T) {
	archive, source := nativeFixture(t)
	before := digest(t, archive)
	r, err := Inspect(archive)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status != "validated" || r.ArchiveSHA256 != before || r.CoreCleanCheckpointVerified || r.FileCount != len(r.Files) {
		t.Fatalf("bad report: %+v", r)
	}
	dest := filepath.Join(t.TempDir(), "restored")
	restored, err := Restore(context.Background(), archive, dest)
	if err != nil {
		t.Fatal(err)
	}
	if restored.Status != "restored" || restored.ArchiveSHA256 != before || restored.Paths["captured_config"] != filepath.Join(dest, "captured-config") {
		t.Fatalf("bad restore report: %+v", restored)
	}
	if st, err := os.Stat(dest); err != nil || st.Mode().Perm() != 0o700 {
		t.Fatal("destination is not private")
	}
	var coldWAL, core bool
	for _, f := range r.Files {
		rel := f.Path
		if strings.HasPrefix(rel, "config/") {
			rel = "captured-config/" + strings.TrimPrefix(rel, "config/")
		}
		if digest(t, filepath.Join(dest, rel)) != f.SHA256 {
			t.Fatalf("restored bytes differ: %s", rel)
		}
		srcRel := f.Path
		if strings.HasPrefix(srcRel, "config/") {
			srcRel = strings.TrimPrefix(srcRel, "config/")
		}
		if digest(t, filepath.Join(source, srcRel)) != f.SHA256 {
			t.Fatalf("source changed: %s", srcRel)
		}
		coldWAL = coldWAL || f.Path == "gateway/conversations.db-wal"
		core = core || f.Path == "core/fractal/1/1/2026.fpf"
	}
	if !coldWAL || !core {
		t.Fatal("cold WAL or Core missing")
	}
	if _, err := os.Stat(filepath.Join(dest, ".env")); !os.IsNotExist(err) {
		t.Fatal("runnable configuration leaked into restore root")
	}
	if digest(t, archive) != before {
		t.Fatal("archive modified")
	}
}

func TestExistingDestinationUntouched(t *testing.T) {
	archive, _ := nativeFixture(t)
	dest := t.TempDir()
	marker := filepath.Join(dest, "marker")
	os.WriteFile(marker, []byte("keep"), 0o600)
	if r, err := Restore(context.Background(), archive, dest); err == nil || r.Status == "restored" {
		t.Fatal("existing destination accepted")
	}
	if b, _ := os.ReadFile(marker); string(b) != "keep" {
		t.Fatal("existing destination changed")
	}
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(dest, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(context.Background(), archive, link); err == nil {
		t.Fatal("symlink destination accepted")
	}
}

type entry struct {
	name string
	body []byte
	kind byte
}

func archiveEntries(t *testing.T, entries []entry) []byte {
	t.Helper()
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	tw := tar.NewWriter(gz)
	for _, e := range entries {
		if err := tw.WriteHeader(&tar.Header{Name: e.name, Mode: 0o600, Typeflag: e.kind, Size: int64(len(e.body)), Linkname: "/tmp/escape"}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(e.body); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}
func manifest() entry {
	b, _ := json.Marshal(databackup.Manifest{Kind: "falconpulsar-data-backup", Version: 1, Services: []string{"core", "config"}})
	return entry{"manifest.json", b, tar.TypeReg}
}

func TestRejectUnsafeAndDamagedArchivesBeforeRestore(t *testing.T) {
	m := manifest()
	good := archiveEntries(t, []entry{{"core/fp_database.hdr", []byte("header"), tar.TypeReg}, m})
	crc := append([]byte(nil), good...)
	crc[len(crc)-8] ^= 1
	wrongVersion := manifest()
	wrongVersion.body = bytes.Replace(wrongVersion.body, []byte(`"version":1`), []byte(`"version":2`), 1)
	cases := map[string][]byte{
		"truncated": good[:len(good)-5], "bad-crc": crc, "trailing": append(append([]byte(nil), good...), 1),
		"duplicate":          archiveEntries(t, []entry{{"core/a", nil, tar.TypeReg}, {"core/a", nil, tar.TypeReg}, m}),
		"traversal":          archiveEntries(t, []entry{{"core/../../escape", nil, tar.TypeReg}, m}),
		"absolute":           archiveEntries(t, []entry{{"/core/escape", nil, tar.TypeReg}, m}),
		"backslash":          archiveEntries(t, []entry{{"core/..\\escape", nil, tar.TypeReg}, m}),
		"link":               archiveEntries(t, []entry{{"core/link", nil, tar.TypeSymlink}, m}),
		"hardlink":           archiveEntries(t, []entry{{"core/link", nil, tar.TypeLink}, m}),
		"device":             archiveEntries(t, []entry{{"core/device", nil, tar.TypeChar}, m}),
		"unknown":            archiveEntries(t, []entry{{"unknown/file", nil, tar.TypeReg}, m}),
		"file-parent":        archiveEntries(t, []entry{{"core/a", nil, tar.TypeReg}, {"core/a/b", nil, tar.TypeReg}, m}),
		"directory-replaced": archiveEntries(t, []entry{{"core/a/b", nil, tar.TypeReg}, {"core/a", nil, tar.TypeReg}, m}),
		"manifest-cap":       archiveEntries(t, []entry{{"manifest.json", bytes.Repeat([]byte(" "), maxManifestBytes+1), tar.TypeReg}}),
		"version":            archiveEntries(t, []entry{wrongVersion}),
		"missing-manifest":   archiveEntries(t, []entry{{"core/a", nil, tar.TypeReg}}),
		"duplicate-manifest": archiveEntries(t, []entry{m, m}),
		"wrong-kind":         archiveEntries(t, []entry{{"manifest.json", []byte(`{"kind":"foreign","version":1,"services":["core"]}`), tar.TypeReg}}),
		"unlisted-service":   archiveEntries(t, []entry{{"engine/a", nil, tar.TypeReg}, m}),
		"second-gzip-stream": append(append([]byte(nil), good...), good...),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			archive := filepath.Join(t.TempDir(), "bad.tar.gz")
			if err := os.WriteFile(archive, data, 0o600); err != nil {
				t.Fatal(err)
			}
			before := digest(t, archive)
			if r, err := Inspect(archive); err == nil || r.Status == "validated" {
				t.Fatal("invalid archive accepted")
			}
			dest := filepath.Join(t.TempDir(), "restore")
			if r, err := Restore(context.Background(), archive, dest); err == nil || r.Status == "restored" {
				t.Fatal("invalid restore accepted")
			}
			if _, err := os.Lstat(dest); !os.IsNotExist(err) {
				t.Fatal("invalid archive left a destination")
			}
			if digest(t, archive) != before {
				t.Fatal("archive modified")
			}
		})
	}
}
