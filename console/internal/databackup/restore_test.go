// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

package databackup

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
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

// ── Finding: the restored Core reads the restored directory ─────────────────

// restoredCore restores a Core archive over fakeStack's Core and writes the
// marker, as fp restore does before it starts the stack. It returns the
// directory set aside.
func restoredCore(t *testing.T, e Env) (aside, marker string) {
	t.Helper()
	archive := writeArchive(t, leaseManifest(), map[string]string{"core/fp_database.hdr": "RESTORED", "core/wal/wal_00000009.fpw": "w9"},
		[]string{"core/fp_database.hdr", "core/wal/wal_00000009.fpw"})
	asides, err := Restore(context.Background(), e, archive, RestoreOptions{})
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range asides {
		if strings.HasPrefix(a, e.CoreDir+".pre-restore-") {
			aside = a
		}
	}
	if aside == "" {
		t.Fatalf("Core's directory was not set aside: %v", asides)
	}
	if marker, err = MarkRestoredCore(e); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(e.CoreDir, marker)); err != nil {
		t.Fatalf("the marker must be in the restored directory: %v", err)
	}
	if _, err := os.Stat(filepath.Join(aside, marker)); !os.IsNotExist(err) {
		t.Fatalf("the marker must not be in the directory set aside")
	}
	return aside, marker
}

// coreView is Core's container as Docker Desktop can leave it: `ls -a /data`
// lists whichever host directory the container sees, and stop/start are
// recorded. After freshAfter starts, the container sees the restored one.
type coreView struct {
	e          *Env
	aside      string
	freshAfter int // -1 = never
	starts     int
	events     []string
	stopErr    error
}

func (v *coreView) install(e *Env) {
	v.e = e
	e.DockerOutput = func(_ context.Context, container string, argv []string) (string, error) {
		if container != coreContainer || strings.Join(argv, " ") != "ls -a /data" {
			return "", fmt.Errorf("unexpected docker exec %s %v", container, argv)
		}
		dir := v.aside
		if v.freshAfter >= 0 && v.starts >= v.freshAfter {
			dir = v.e.CoreDir
		}
		ents, err := os.ReadDir(dir)
		if err != nil {
			return "", err
		}
		names := []string{".", ".."}
		for _, en := range ents {
			names = append(names, en.Name())
		}
		return strings.Join(names, "\n") + "\n", nil
	}
	e.StopCore = func(context.Context) error { v.events = append(v.events, "stop"); return v.stopErr }
	e.StartCore = func(context.Context) error { v.starts++; v.events = append(v.events, "start"); return nil }
}

func fastViewRetries(t *testing.T) {
	t.Helper()
	old := coreViewRetries
	coreViewRetries = []time.Duration{time.Millisecond, time.Millisecond}
	t.Cleanup(func() { coreViewRetries = old })
}

func TestRestoreChecksThatCoreReadsTheRestoredDirectory(t *testing.T) {
	fastViewRetries(t)
	t.Run("Core reads it", func(t *testing.T) {
		e := fakeStack(t)
		aside, marker := restoredCore(t, e)
		v := &coreView{aside: aside, freshAfter: 0}
		v.install(&e)
		if err := VerifyCoreReadsRestore(context.Background(), e, marker, nil); err != nil {
			t.Fatal(err)
		}
		if len(v.events) != 0 {
			t.Errorf("a Core that reads the restored data must be left alone: %v", v.events)
		}
		UnmarkRestoredCore(e, marker)
		if _, err := os.Stat(filepath.Join(e.CoreDir, marker)); !os.IsNotExist(err) {
			t.Errorf("the marker must be removed")
		}
	})
	t.Run("Core reads the directory set aside, then the restored one after a restart", func(t *testing.T) {
		e := fakeStack(t)
		aside, marker := restoredCore(t, e)
		v := &coreView{aside: aside, freshAfter: 1}
		v.install(&e)
		if err := VerifyCoreReadsRestore(context.Background(), e, marker, nil); err != nil {
			t.Fatal(err)
		}
		if strings.Join(v.events, ",") != "stop,start" {
			t.Errorf("events %v", v.events)
		}
	})
	t.Run("Core keeps reading the directory set aside", func(t *testing.T) {
		e := fakeStack(t)
		aside, marker := restoredCore(t, e)
		v := &coreView{aside: aside, freshAfter: -1}
		v.install(&e)
		err := VerifyCoreReadsRestore(context.Background(), e, marker, nil)
		var stale *StaleCoreViewError
		if !errors.As(err, &stale) || !strings.Contains(err.Error(), "Docker Desktop") || !strings.Contains(err.Error(), e.CoreDir) {
			t.Fatalf("want the stale view named, got %v", err)
		}
		// Core is left STOPPED: it must write nothing more into the data set aside.
		if got := strings.Join(v.events, ","); got != "stop,start,stop,start,stop" {
			t.Errorf("events %s: Core must end stopped", got)
		}
		if b, _ := os.ReadFile(filepath.Join(e.CoreDir, "fp_database.hdr")); string(b) != "RESTORED" {
			t.Errorf("the restored data must stay in place: %q", b)
		}
	})
	t.Run("Core cannot be stopped", func(t *testing.T) {
		e := fakeStack(t)
		aside, marker := restoredCore(t, e)
		v := &coreView{aside: aside, freshAfter: -1, stopErr: errors.New("daemon busy")}
		v.install(&e)
		err := VerifyCoreReadsRestore(context.Background(), e, marker, nil)
		var stale *StaleCoreViewError
		if !errors.As(err, &stale) || !strings.Contains(err.Error(), "stop it NOW") {
			t.Fatalf("want the operator told to stop Core, got %v", err)
		}
	})
	t.Run("the check cannot be made", func(t *testing.T) {
		e := fakeStack(t)
		_, marker := restoredCore(t, e)
		e.DockerOutput = func(context.Context, string, []string) (string, error) {
			return "", errors.New("container is restarting")
		}
		e.StopCore = func(context.Context) error {
			t.Fatal("Core must not be stopped on a check that was not made")
			return nil
		}
		err := VerifyCoreReadsRestore(context.Background(), e, marker, nil)
		var stale *StaleCoreViewError
		if err == nil || errors.As(err, &stale) {
			t.Fatalf("want a failed check, not a verdict: %v", err)
		}
	})
}
