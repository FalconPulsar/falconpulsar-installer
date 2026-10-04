// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

package databackup

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// writeArchive builds an archive by hand: entries in order, manifest last.
func writeArchive(t *testing.T, man Manifest, entries map[string]string, order []string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "a.tar.gz")
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for _, name := range order {
		body := entries[name]
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o600, Size: int64(len(body))}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	mb, _ := json.Marshal(man)
	_ = tw.WriteHeader(&tar.Header{Name: "manifest.json", Mode: 0o600, Size: int64(len(mb))})
	_, _ = tw.Write(mb)
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return p
}

func leaseManifest() Manifest {
	return Manifest{Kind: manifestKind, Version: manifestVersion, Services: []string{"core", "config"},
		Core: &CoreCapture{Mode: CoreLease, LeaseID: "0123456789abcdef0123456789abcdef", CatalogSequence: 9}}
}

func TestRestoreNeverRestoresCoresBackupArea(t *testing.T) {
	e := fakeStack(t)
	archive := writeArchive(t, leaseManifest(), map[string]string{
		"core/fp_database.hdr":                   "hdr",
		"core/.fp-backup/x/meta/catalog.fpm":     "stale snapshot",
		"core/.fp-backup":                        "odd",
		"core/meta/catalog.fpm":                  "catalog",
		"core/fractal/1/7/2026-10-04.fpf":        "points",
		"core/wal/wal_00000001.fpw":              "wal",
		"core/meta/wal-held/series-1.lsn-1.fpw":  "held",
		"core/alarm_event_history.bin":           "ring",
		"core/device_layouts/kiosk-layout.json":  "{}",
		"core/attachments/annotation/attachment": "a",
	}, []string{"core/fp_database.hdr", "core/.fp-backup/x/meta/catalog.fpm", "core/.fp-backup", "core/fractal/1/7/2026-10-04.fpf",
		"core/wal/wal_00000001.fpw", "core/meta/catalog.fpm", "core/meta/wal-held/series-1.lsn-1.fpw",
		"core/alarm_event_history.bin", "core/device_layouts/kiosk-layout.json", "core/attachments/annotation/attachment"})
	if _, err := Restore(context.Background(), e, archive, RestoreOptions{}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(e.CoreDir, ".fp-backup")); !os.IsNotExist(err) {
		t.Fatalf(".fp-backup was restored")
	}
	for rel, want := range map[string]string{"meta/catalog.fpm": "catalog", "fractal/1/7/2026-10-04.fpf": "points",
		"meta/wal-held/series-1.lsn-1.fpw": "held", "device_layouts/kiosk-layout.json": "{}"} {
		b, err := os.ReadFile(filepath.Join(e.CoreDir, rel))
		if err != nil || string(b) != want {
			t.Errorf("%s = %q (%v)", rel, b, err)
		}
	}
}

func TestRestoreIntoAMountPointSetsItsContentsAside(t *testing.T) {
	e := fakeStack(t)
	if err := os.MkdirAll(filepath.Join(e.CoreDir, "lost+found"), 0o700); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(e.CoreDir)
	if err != nil {
		t.Fatal(err)
	}
	old := isMountPoint
	isMountPoint = func(p string) bool { return p == e.CoreDir }
	t.Cleanup(func() { isMountPoint = old })

	archive := writeArchive(t, leaseManifest(), map[string]string{"core/fp_database.hdr": "NEW", "core/wal/wal_00000002.fpw": "w2"},
		[]string{"core/fp_database.hdr", "core/wal/wal_00000002.fpw"})
	asides, err := Restore(context.Background(), e, archive, RestoreOptions{})
	if err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(e.CoreDir)
	if err != nil || !os.SameFile(before, after) {
		t.Fatalf("the mount point itself must stay where it is")
	}
	if len(asides) != 1 || filepath.Dir(asides[0]) != e.CoreDir || !strings.Contains(asides[0], ".pre-restore-") {
		t.Fatalf("asides %v", asides)
	}
	// The old contents are in the aside, on the same volume.
	if b, _ := os.ReadFile(filepath.Join(asides[0], "fp_database.hdr")); string(b) != "core-hdr" {
		t.Errorf("old header not set aside: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(asides[0], "wal", "wal_1.fpw")); string(b) != "core-wal" {
		t.Errorf("old WAL not set aside: %q", b)
	}
	if _, err := os.Stat(filepath.Join(e.CoreDir, "wal", "wal_1.fpw")); !os.IsNotExist(err) {
		t.Errorf("the old WAL must not sit beside the restored one")
	}
	if b, _ := os.ReadFile(filepath.Join(e.CoreDir, "fp_database.hdr")); string(b) != "NEW" {
		t.Errorf("not restored: %q", b)
	}
	if _, err := os.Stat(filepath.Join(e.CoreDir, "lost+found")); err != nil {
		t.Errorf("the volume's lost+found must stay")
	}
}

func TestRestoreKeepsTheReplacedDirectorysModeAndConfigsMode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("modes")
	}
	e := fakeStack(t)
	if err := os.Chmod(e.CoreDir, 0o750); err != nil {
		t.Fatal(err)
	}
	envPath := filepath.Join(e.Home, ".env")
	if err := os.Chmod(envPath, 0o640); err != nil {
		t.Fatal(err)
	}
	man := leaseManifest()
	archive := writeArchive(t, man, map[string]string{"core/fp_database.hdr": "NEW", "config/.env": "FP_VERSION=restored"},
		[]string{"core/fp_database.hdr", "config/.env"})
	if _, err := Restore(context.Background(), e, archive, RestoreOptions{}); err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Stat(e.CoreDir); st.Mode().Perm() != 0o750 {
		t.Errorf("recreated data directory mode %v, want 0750", st.Mode().Perm())
	}
	if st, _ := os.Stat(envPath); st.Mode().Perm() != 0o640 {
		t.Errorf(".env mode %v, want the replaced file's 0640", st.Mode().Perm())
	}
	if b, _ := os.ReadFile(envPath); string(b) != "FP_VERSION=restored" {
		t.Errorf(".env not restored: %q", b)
	}
	// Core's files are readable and writable by their owner even when the
	// archive said otherwise.
	if st, _ := os.Stat(filepath.Join(e.CoreDir, "fp_database.hdr")); st.Mode().Perm()&0o600 != 0o600 {
		t.Errorf("restored Core file mode %v", st.Mode().Perm())
	}
}

func TestRestoreSaysWhenItCannotGiveFilesToTheServiceUser(t *testing.T) {
	if os.Geteuid() <= 0 {
		t.Skip("needs a non-root, non-Windows run")
	}
	e := fakeStack(t)
	e.Owner = &FileOwner{UID: os.Geteuid() + 1, GID: os.Getegid()}
	archive := writeArchive(t, leaseManifest(), map[string]string{"core/fp_database.hdr": "NEW"}, []string{"core/fp_database.hdr"})
	var warnings []string
	if _, err := Restore(context.Background(), e, archive, RestoreOptions{Warn: func(s string) { warnings = append(warnings, s) }}); err != nil {
		t.Fatal(err)
	}
	if len(warnings) != 1 || !strings.Contains(warnings[0], "chown -R") || !strings.Contains(warnings[0], e.CoreDir) {
		t.Fatalf("want one warning naming the fix, got %v", warnings)
	}
}

func TestAnArchiveFromAnOlderBackupIsRecognised(t *testing.T) {
	old := Manifest{Kind: manifestKind, Version: 1, Services: []string{"gateway", "core", "config"},
		Semantics: map[string]string{"core": "crash-consistent (Core replays its own WAL on restore)"}}
	if !old.CoreFromOlderBackup() {
		t.Error("an archive with core and no capture record is from an older fp backup")
	}
	if leaseManifest().CoreFromOlderBackup() {
		t.Error("a lease archive is not")
	}
	noCore := Manifest{Services: []string{"gateway", "config"}}
	if noCore.CoreFromOlderBackup() {
		t.Error("an archive without core is not")
	}
}

func TestLoadEnvReadsTheBackupSettings(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".env"),
		[]byte("FP_REST_PORT=17433\nFP_UID=1001\nFP_GID=999\nFP_BACKUP_KEY=fp_abc\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	e := LoadEnv(home)
	if e.CoreURL != "http://localhost:17433" || e.BackupKey != "fp_abc" || e.Owner == nil || *e.Owner != (FileOwner{1001, 999}) {
		t.Fatalf("%+v", e)
	}
	if err := os.WriteFile(filepath.Join(home, ".env"), []byte("FP_REST_PORT=bogus\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if e := LoadEnv(home); e.CoreURL != "http://localhost:7433" || e.Owner != nil {
		t.Fatalf("defaults: %+v", e)
	}
}

// Under sudo, restored files and the directories made for them go to the
// user the services run as, not to root.
func TestRestoreAsRootGivesFilesToTheServiceUser(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("needs root (run the Linux leg of the suite as root)")
	}
	e := fakeStack(t)
	e.Owner = &FileOwner{UID: 4321, GID: 4322}
	archive := writeArchive(t, leaseManifest(), map[string]string{
		"core/fp_database.hdr": "NEW", "core/fractal/9/9/2026-10-04.fpf": "p", "config/.env": "FP_VERSION=r",
	}, []string{"core/fp_database.hdr", "core/fractal/9/9/2026-10-04.fpf", "config/.env"})
	envOwner, _ := ownerOf(filepath.Join(e.Home, ".env"))
	if _, err := Restore(context.Background(), e, archive, RestoreOptions{}); err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"", "fp_database.hdr", "fractal", "fractal/9", "fractal/9/9", "fractal/9/9/2026-10-04.fpf"} {
		if uid, gid := ownerOf(filepath.Join(e.CoreDir, rel)); uid != 4321 || gid != 4322 {
			t.Errorf("%q owned by %d:%d, want 4321:4322", rel, uid, gid)
		}
	}
	if uid, _ := ownerOf(filepath.Join(e.Home, ".env")); uid != envOwner {
		t.Errorf(".env must keep the owner of the file it replaced (%d), got %d", envOwner, uid)
	}
}

func TestMountPointDetection(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("no mount points on the Windows build")
	}
	if !mountPoint("/") {
		t.Error("/ is a mount point")
	}
	if mountPoint(t.TempDir()) {
		t.Error("a plain directory is not a mount point")
	}
	if p := os.Getenv("FP_TEST_MOUNT_POINT"); p != "" && !mountPoint(p) {
		t.Errorf("%s is a mount point", p)
	}
}
