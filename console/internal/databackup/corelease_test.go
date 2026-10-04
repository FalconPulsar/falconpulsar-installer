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
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeCore is Core's backup lease contract (docs/backup-lease.md on the Core
// branch), small enough to steer from a test.
type fakeCore struct {
	t       *testing.T
	dataDir string // the host side of Core's data directory
	key     string // the only bearer token it accepts on the lease routes

	mode       string // "lease" | "older404" | "older200" | "refuse-key"
	beginCode  int    // 0 = 201; else refuse with this status
	beginMsg   string
	catalogErr int    // 0 = 200; else refuse with this status
	stateAfter string // GET {id} answers this state once set ("aborted")
	files      []LeaseFile
	snapshot   map[string]string // restore_as -> content written at catalog time
	mintPerms  []string          // what POST /tokens answers with

	mu       sync.Mutex
	id       string
	released []string
	revoked  []string
	calls    []string
}

func newFakeCore(t *testing.T, dataDir string) (*fakeCore, *httptest.Server) {
	fc := &fakeCore{t: t, dataDir: dataDir, key: "fp_backupkey", mode: "lease",
		snapshot:  map[string]string{"meta/catalog.fpm": "CATALOG@SEQ42", "meta/catalog.fpm-journal": "JOURNAL"},
		mintPerms: []string{"SYSTEM_BACKUP"}}
	srv := httptest.NewServer(http.HandlerFunc(fc.serve))
	t.Cleanup(srv.Close)
	return fc, srv
}

func (fc *fakeCore) json(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (fc *fakeCore) serve(w http.ResponseWriter, r *http.Request) {
	fc.mu.Lock()
	fc.calls = append(fc.calls, r.Method+" "+r.URL.Path)
	fc.mu.Unlock()
	p := r.URL.Path
	switch {
	case p == "/api/v1/health":
		w.WriteHeader(200)
		return
	case p == "/api/v1/capabilities":
		if fc.mode == "older404" || fc.mode == "older200" {
			fc.json(w, 200, map[string]any{"version": "v0.1.4-alpha.140"})
			return
		}
		fc.json(w, 200, map[string]any{"version": "v0.1.4-backup", "backup_lease": map[string]any{"lease": 1}})
		return
	case p == "/api/v1/tokens" && r.Method == http.MethodPost:
		if r.Header.Get("Authorization") != "Bearer admin-jwt" {
			fc.json(w, 401, map[string]any{"error": "Authentication required"})
			return
		}
		fc.json(w, 201, map[string]any{"token": "fp_minted", "id": "tok-1", "name": "fp-backup", "permissions": fc.mintPerms})
		return
	case strings.HasPrefix(p, "/api/v1/tokens/") && r.Method == http.MethodDelete:
		fc.mu.Lock()
		fc.revoked = append(fc.revoked, strings.TrimPrefix(p, "/api/v1/tokens/"))
		fc.mu.Unlock()
		fc.json(w, 200, map[string]any{"revoked": true})
		return
	}
	if !strings.HasPrefix(p, "/api/v1/_system/backup") {
		fc.json(w, 404, map[string]any{"error": "Not found"})
		return
	}
	auth := r.Header.Get("Authorization")
	if fc.mode == "refuse-key" || (auth != "Bearer "+fc.key && auth != "Bearer admin-jwt") {
		fc.json(w, 401, map[string]any{"error": "Authentication required"})
		return
	}
	switch fc.mode {
	case "older404":
		fc.json(w, 404, map[string]any{"error": "Not found"})
		return
	case "older200": // an older Core routes this path to GET /api/v1/_system
		fc.json(w, 200, map[string]any{"server": map[string]any{"version": "old"}})
		return
	}
	rest := strings.TrimPrefix(strings.TrimPrefix(p, "/api/v1/_system/backup"), "/")
	switch {
	case rest == "capability":
		fc.json(w, 200, map[string]any{"lease": 1, "max_ttl_s": 86400, "catalog_wait_cap_ms": 10000, "default_ttl_s": 7200, "default_wal_cap_pct": 25})
	case rest == "" && r.Method == http.MethodPost:
		if fc.beginCode != 0 {
			fc.json(w, fc.beginCode, map[string]any{"error": fc.beginMsg})
			return
		}
		fc.mu.Lock()
		fc.id = "0123456789abcdef0123456789abcdef"
		fc.mu.Unlock()
		var total int64
		for _, f := range fc.files {
			total += f.Length
		}
		fc.json(w, 201, map[string]any{"id": fc.id, "state": "active", "data_dir": "/data",
			"started_at": time.Now().UTC().Format(time.RFC3339), "expires_at": "2026-10-04T12:00:00Z",
			"ttl_s": 7200, "wal_cap_bytes": 1 << 30, "free_bytes": 4 << 30, "file_count": len(fc.files),
			"total_bytes": total, "files": fc.files,
			"exclude": []string{".fp-backup/", "logs/", "meta/catalog.fpm", "meta/catalog.fpm-journal", "meta/wal-held/"}})
	case rest == "" && r.Method == http.MethodGet:
		fc.json(w, 200, map[string]any{"backup": nil})
	case strings.HasSuffix(rest, "/catalog"):
		id := strings.TrimSuffix(rest, "/catalog")
		if fc.catalogErr != 0 {
			fc.json(w, fc.catalogErr, map[string]any{"error": "catalog changes would have waited past 10000 ms", "state": "aborted"})
			return
		}
		files := []map[string]string{}
		for as, content := range fc.snapshot {
			rel := ".fp-backup/" + id + "/" + as
			hp := filepath.Join(fc.dataDir, filepath.FromSlash(rel))
			if err := os.MkdirAll(filepath.Dir(hp), 0o755); err != nil {
				fc.t.Error(err)
			}
			if err := os.WriteFile(hp, []byte(content), 0o600); err != nil {
				fc.t.Error(err)
			}
			files = append(files, map[string]string{"path": rel, "restore_as": as})
		}
		fc.json(w, 200, map[string]any{"id": id, "files": files, "catalog_sequence": 42, "catalog_wait_ms": 3})
	case r.Method == http.MethodGet:
		state := "active"
		if fc.stateAfter != "" {
			state = fc.stateAfter
		}
		fc.json(w, 200, map[string]any{"id": rest, "state": state, "held_wal_bytes": 1, "reason": "the WAL held for the backup passed its cap"})
	case r.Method == http.MethodDelete:
		fc.mu.Lock()
		fc.released = append(fc.released, rest)
		fc.mu.Unlock()
		_ = os.RemoveAll(filepath.Join(fc.dataDir, ".fp-backup", rest))
		fc.json(w, 200, map[string]any{"id": rest, "released": true})
	default:
		fc.json(w, 404, map[string]any{"error": "No such backup route"})
	}
}

func (fc *fakeCore) releasedIDs() []string {
	fc.mu.Lock()
	defer fc.mu.Unlock()
	return append([]string(nil), fc.released...)
}

// liveStack is fakeStack with Core RUNNING behind a fake lease-capable Core.
func liveStack(t *testing.T) (Env, *fakeCore) {
	t.Helper()
	e := fakeStack(t)
	write := func(rel, content string) {
		p := filepath.Join(e.CoreDir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("fractal/1/7/2026-10-04.fpf", "PARTITION-COMMITTED|tail-written-after-begin")
	write("wal/wal_00000001.fpw", "WAL-RECORDS|half-a-record")
	write("blobs/7/2026-10-04.fpb", "BLOBS|newer")
	write("meta/catalog.fpm", "LIVE-CATALOG-must-not-travel")
	write("logs/server-20261004.log", "log line")
	fc, srv := newFakeCore(t, e.CoreDir)
	fc.files = []LeaseFile{
		{Path: "fp_database.hdr", Length: int64(len("core-hdr"))},
		{Path: "fractal/1/7/2026-10-04.fpf", Length: int64(len("PARTITION-COMMITTED"))},
		{Path: "wal/wal_1.fpw", Length: int64(len("core-wal"))},
		{Path: "wal/wal_00000001.fpw", Length: int64(len("WAL-RECORDS"))},
		{Path: "blobs/7/2026-10-04.fpb", Length: int64(len("BLOBS"))},
	}
	e.CoreURL = srv.URL
	e.BackupKey = fc.key
	e.ContainerRunning = func(_ context.Context, name string) bool { return name == coreContainer }
	e.StopCore = func(context.Context) error { t.Fatal("a live copy must not stop Core"); return nil }
	e.StartCore = func(context.Context) error { t.Fatal("a live copy must not start Core"); return nil }
	return e, fc
}

// archiveEntries returns the archive's entries in order, with contents.
func archiveEntries(t *testing.T, archive string) ([]string, map[string]string) {
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
	var order []string
	content := map[string]string{}
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(tr)
		order = append(order, hdr.Name)
		content[hdr.Name] = string(data)
	}
	return order, content
}

// noArchiveLeft asserts that a failed backup left neither the archive nor a
// partial file behind.
func noArchiveLeft(t *testing.T, out string) {
	t.Helper()
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Errorf("a failed backup left %s", out)
	}
	entries, _ := os.ReadDir(filepath.Dir(out))
	for _, en := range entries {
		if strings.Contains(en.Name(), ".partial-") {
			t.Errorf("a failed backup left a partial file %s", en.Name())
		}
	}
}

func TestLeaseCopyTakesExactlyTheListedBytesInListOrder(t *testing.T) {
	e, fc := liveStack(t)
	out := filepath.Join(t.TempDir(), "b.tar.gz")
	man, err := Backup(context.Background(), e, out, BackupOptions{})
	if err != nil {
		t.Fatal(err)
	}
	order, got := archiveEntries(t, out)

	// The COPIER RULE: exactly `length` bytes, never the current size.
	for path, want := range map[string]string{
		"core/fractal/1/7/2026-10-04.fpf": "PARTITION-COMMITTED",
		"core/wal/wal_00000001.fpw":       "WAL-RECORDS",
		"core/blobs/7/2026-10-04.fpb":     "BLOBS",
		"core/fp_database.hdr":            "core-hdr",
		// The snapshot, archived under its restore_as names.
		"core/meta/catalog.fpm":         "CATALOG@SEQ42",
		"core/meta/catalog.fpm-journal": "JOURNAL",
	} {
		if got[path] != want {
			t.Errorf("%s = %q, want %q", path, got[path], want)
		}
	}
	// Nothing Core did not list: not the logs, not the live catalog under its
	// own name (that is the snapshot's), not the backup area.
	for name := range got {
		if strings.HasPrefix(name, "core/logs/") || strings.Contains(name, ".fp-backup") {
			t.Errorf("%s travelled; Core did not list it", name)
		}
	}
	// List order, then the snapshot: Core's guarantee depends on it.
	var coreOrder []string
	for _, n := range order {
		if strings.HasPrefix(n, "core/") {
			coreOrder = append(coreOrder, strings.TrimPrefix(n, "core/"))
		}
	}
	for i, f := range fc.files {
		if coreOrder[i] != f.Path {
			t.Fatalf("copy order %v differs from the list at %d (%s)", coreOrder, i, f.Path)
		}
	}
	if len(coreOrder) != len(fc.files)+2 {
		t.Fatalf("core entries %v", coreOrder)
	}
	if man.Core == nil || man.Core.Mode != CoreLease || man.Core.LeaseID != fc.id || man.Core.CatalogSequence != 42 {
		t.Fatalf("capture %+v", man.Core)
	}
	if want := "live, consistent (Core backup lease " + fc.id + ", catalog sequence 42)"; man.Semantics["core"] != want {
		t.Errorf("semantics %q", man.Semantics["core"])
	}
	if got := fc.releasedIDs(); len(got) != 1 || got[0] != fc.id {
		t.Errorf("lease not released exactly once: %v", got)
	}
	// The manifest is in the archive and says the same.
	var arc Manifest
	if err := json.Unmarshal([]byte(got["manifest.json"]), &arc); err != nil || arc.Core == nil || arc.Core.Mode != CoreLease {
		t.Fatalf("archived manifest %+v (%v)", arc.Core, err)
	}
	if order[len(order)-1] != "manifest.json" {
		t.Errorf("the manifest must be the last entry")
	}
	if st, err := os.Stat(out); err != nil || st.Mode().Perm() != 0o600 {
		t.Errorf("the archive holds .env secrets and must be private: %v", st.Mode())
	}
	noPartials(t, filepath.Dir(out))
}

func noPartials(t *testing.T, dir string) {
	t.Helper()
	entries, _ := os.ReadDir(dir)
	for _, en := range entries {
		if strings.Contains(en.Name(), ".partial-") {
			t.Errorf("partial file left: %s", en.Name())
		}
	}
}

func TestLeaseCopyFailsWhenAFileHoldsFewerBytesThanListed(t *testing.T) {
	e, fc := liveStack(t)
	fc.files[1].Length = 10_000 // more than the partition holds
	out := filepath.Join(t.TempDir(), "b.tar.gz")
	_, err := Backup(context.Background(), e, out, BackupOptions{})
	var short *ShortFileError
	if !errors.As(err, &short) || short.Wants != 10_000 {
		t.Fatalf("want a ShortFileError, got %v", err)
	}
	noArchiveLeft(t, out)
	if len(fc.releasedIDs()) != 1 {
		t.Errorf("lease not released after a failed copy")
	}
}

func TestLeaseIsReleasedWhenTheOperatorInterrupts(t *testing.T) {
	e, fc := liveStack(t)
	ctx, cancel := context.WithCancel(context.Background())
	out := filepath.Join(t.TempDir(), "b.tar.gz")
	_, err := Backup(ctx, e, out, BackupOptions{afterCoreFile: func(i, _ int, _ string) {
		if i == 1 {
			cancel() // Ctrl-C mid-copy
		}
	}})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want the interrupt, got %v", err)
	}
	if len(fc.releasedIDs()) != 1 {
		t.Errorf("an interrupted backup must release its lease: %v", fc.releasedIDs())
	}
	noArchiveLeft(t, out)
}

func TestCatalogWaitCapAbortsTheBackup(t *testing.T) {
	e, fc := liveStack(t)
	fc.catalogErr = http.StatusGatewayTimeout
	out := filepath.Join(t.TempDir(), "b.tar.gz")
	_, err := Backup(context.Background(), e, out, BackupOptions{})
	if err == nil || !strings.Contains(err.Error(), "aborted the backup") || !strings.Contains(err.Error(), "plant carried on") {
		t.Fatalf("want the cap abort, got %v", err)
	}
	if len(fc.releasedIDs()) != 1 {
		t.Errorf("lease not released after the abort")
	}
	noArchiveLeft(t, out)
}

func TestALeaseCoreEndedStopsTheCopyWithCoresReason(t *testing.T) {
	e, fc := liveStack(t)
	fc.stateAfter = "aborted"
	old := leaseCheckEvery
	leaseCheckEvery = 0
	t.Cleanup(func() { leaseCheckEvery = old })
	out := filepath.Join(t.TempDir(), "b.tar.gz")
	_, err := Backup(context.Background(), e, out, BackupOptions{})
	if err == nil || !strings.Contains(err.Error(), "passed its cap") {
		t.Fatalf("want Core's reason, got %v", err)
	}
	noArchiveLeft(t, out)
}

func TestOlderCoreIsLeftOutAndNamed(t *testing.T) {
	for _, mode := range []string{"older404", "older200"} {
		t.Run(mode, func(t *testing.T) {
			e, fc := liveStack(t)
			fc.mode = mode
			out := filepath.Join(t.TempDir(), "b.tar.gz")
			man, err := Backup(context.Background(), e, out, BackupOptions{})
			var nc *CoreNotCapturedError
			if !errors.As(err, &nc) || !strings.Contains(nc.Reason, "no backup lease") {
				t.Fatalf("want core not captured, got %v", err)
			}
			_, got := archiveEntries(t, out)
			for name := range got {
				if strings.HasPrefix(name, "core/") {
					t.Fatalf("an older Core was copied live: %s", name)
				}
			}
			if _, ok := got["gateway/conversations.db"]; !ok {
				t.Errorf("the other services must still be archived")
			}
			for _, s := range man.Services {
				if s == "core" {
					t.Errorf("manifest lists core")
				}
			}
			if !strings.HasPrefix(man.Semantics["core"], "not captured — ") || man.Core.Mode != CoreNotCaptured || man.Core.Cause != CauseNoLease {
				t.Errorf("manifest must say core is not captured: %q", man.Semantics["core"])
			}
			for _, s := range man.Semantics {
				if strings.Contains(s, "crash-consistent") {
					t.Errorf("crash-consistent claimed: %q", s)
				}
			}
		})
	}
}

func TestNoBackupKeyIsNamed(t *testing.T) {
	e, _ := liveStack(t)
	e.BackupKey = ""
	man, err := Backup(context.Background(), e, filepath.Join(t.TempDir(), "b.tar.gz"), BackupOptions{})
	var nc *CoreNotCapturedError
	if !errors.As(err, &nc) || !strings.Contains(nc.Reason, BackupKeyEnv) || man.Core.Cause != CauseNoKey {
		t.Fatalf("want the missing key named, got %v", err)
	}
}

func TestARefusedKeyIsNamed(t *testing.T) {
	e, fc := liveStack(t)
	fc.mode = "refuse-key"
	_, err := Backup(context.Background(), e, filepath.Join(t.TempDir(), "b.tar.gz"), BackupOptions{})
	var nc *CoreNotCapturedError
	if !errors.As(err, &nc) || !strings.Contains(nc.Reason, "refused the backup key") {
		t.Fatalf("want the refused key named, got %v", err)
	}
}

// coldHooks records Core stops and starts; after the stop, Core is down.
type coldHooks struct {
	mu      sync.Mutex
	running bool
	events  []string
}

func (h *coldHooks) install(e *Env) {
	h.running = true
	e.ContainerRunning = func(_ context.Context, name string) bool {
		h.mu.Lock()
		defer h.mu.Unlock()
		return name == coreContainer && h.running
	}
	e.StopCore = func(context.Context) error {
		h.mu.Lock()
		defer h.mu.Unlock()
		h.running = false
		h.events = append(h.events, "stop")
		return nil
	}
	e.StartCore = func(context.Context) error {
		h.mu.Lock()
		defer h.mu.Unlock()
		h.running = true
		h.events = append(h.events, "start")
		return nil
	}
}

func TestStopCoreMakesAColdCopyAndStartsCoreAgain(t *testing.T) {
	e, fc := liveStack(t)
	fc.mode = "older404"
	var h coldHooks
	h.install(&e)
	out := filepath.Join(t.TempDir(), "b.tar.gz")
	man, err := Backup(context.Background(), e, out, BackupOptions{StopCore: true})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(h.events, ",") != "stop,start" {
		t.Fatalf("events %v", h.events)
	}
	_, got := archiveEntries(t, out)
	// Cold: whole files, the live catalog included; never the logs.
	if got["core/fractal/1/7/2026-10-04.fpf"] != "PARTITION-COMMITTED|tail-written-after-begin" ||
		got["core/meta/catalog.fpm"] != "LIVE-CATALOG-must-not-travel" {
		t.Errorf("cold copy content wrong: %q", got["core/fractal/1/7/2026-10-04.fpf"])
	}
	if _, ok := got["core/logs/server-20261004.log"]; ok {
		t.Errorf("logs travelled")
	}
	if man.Core.Mode != CoreCold || man.Core.StoppedSeconds < 1 ||
		!strings.HasPrefix(man.Semantics["core"], "cold-copy (Core stopped ") {
		t.Errorf("capture %+v / %q", man.Core, man.Semantics["core"])
	}
	if len(fc.releasedIDs()) != 0 {
		t.Errorf("no lease was taken, none to release")
	}
	// The staging copy is gone.
	entries, _ := os.ReadDir(filepath.Dir(e.CoreDir))
	for _, en := range entries {
		if strings.HasPrefix(en.Name(), ".fp-core-cold-") {
			t.Errorf("staging copy left: %s", en.Name())
		}
	}
}

func TestColdCopyStartsCoreAgainWhenInterrupted(t *testing.T) {
	e, fc := liveStack(t)
	fc.mode = "older404"
	var h coldHooks
	h.install(&e)
	ctx, cancel := context.WithCancel(context.Background())
	stop := e.StopCore
	e.StopCore = func(c context.Context) error {
		err := stop(c)
		cancel() // Ctrl-C while Core is down
		return err
	}
	out := filepath.Join(t.TempDir(), "b.tar.gz")
	if _, err := Backup(ctx, e, out, BackupOptions{StopCore: true}); err == nil {
		t.Fatal("an interrupted cold copy must fail")
	}
	if strings.Join(h.events, ",") != "stop,start" || !h.running {
		t.Fatalf("Core must be started again on every way out: %v", h.events)
	}
	noArchiveLeft(t, out)
}

func TestTheOperatorIsAskedBeforeCoreIsStopped(t *testing.T) {
	for _, yes := range []bool{false, true} {
		t.Run(fmt.Sprint(yes), func(t *testing.T) {
			e, fc := liveStack(t)
			fc.mode = "older404"
			var h coldHooks
			h.install(&e)
			var asked string
			man, err := Backup(context.Background(), e, filepath.Join(t.TempDir(), "b.tar.gz"),
				BackupOptions{ConfirmStop: func(why string) bool { asked = why; return yes }})
			if !strings.Contains(asked, "no backup lease") {
				t.Errorf("the question must say why: %q", asked)
			}
			if yes {
				if err != nil || man.Core.Mode != CoreCold || len(h.events) != 2 {
					t.Fatalf("yes must make a cold copy: %v %+v %v", err, man.Core, h.events)
				}
			} else {
				var nc *CoreNotCapturedError
				if !errors.As(err, &nc) || len(h.events) != 0 {
					t.Fatalf("no must leave Core out and running: %v %v", err, h.events)
				}
			}
		})
	}
}

func TestAnotherBackupsLeaseIsNotEndedByAStop(t *testing.T) {
	e, fc := liveStack(t)
	fc.beginCode, fc.beginMsg = http.StatusConflict, "A backup lease is already active"
	var h coldHooks
	h.install(&e)
	man, err := Backup(context.Background(), e, filepath.Join(t.TempDir(), "b.tar.gz"), BackupOptions{StopCore: true})
	var nc *CoreNotCapturedError
	if !errors.As(err, &nc) || !strings.Contains(nc.Reason, "already active") || man.Core.Cause != CauseAnotherBackup {
		t.Fatalf("want Core's sentence, got %v", err)
	}
	if len(h.events) != 0 {
		t.Errorf("stopping Core would end the other backup: %v", h.events)
	}
}

func TestABeginRefusalOffersTheColdCopy(t *testing.T) {
	e, fc := liveStack(t)
	fc.beginCode, fc.beginMsg = http.StatusNotImplemented, "fractal in the data directory is a symbolic link"
	_, err := Backup(context.Background(), e, filepath.Join(t.TempDir(), "b.tar.gz"), BackupOptions{})
	var nc *CoreNotCapturedError
	if !errors.As(err, &nc) || !strings.Contains(nc.Reason, "symbolic link") {
		t.Fatalf("want Core's 501 sentence, got %v", err)
	}
}

func TestASymlinkedDataDirectoryIsNeverCopiedCold(t *testing.T) {
	e, fc := liveStack(t)
	fc.mode = "older404"
	var h coldHooks
	h.install(&e)
	elsewhere := t.TempDir()
	if err := os.Symlink(elsewhere, filepath.Join(e.CoreDir, "attachments")); err != nil {
		t.Fatal(err)
	}
	man, err := Backup(context.Background(), e, filepath.Join(t.TempDir(), "b.tar.gz"), BackupOptions{StopCore: true})
	var nc *CoreNotCapturedError
	if !errors.As(err, &nc) || !strings.Contains(nc.Reason, "attachments") || man.Core.Cause != CauseCannotCopy {
		t.Fatalf("want the link named, got %v", err)
	}
	if len(h.events) != 0 {
		t.Errorf("Core was stopped for a copy that cannot be made: %v", h.events)
	}
}

func TestAFailedBackupLeavesNoArchive(t *testing.T) {
	e := fakeStack(t)
	e.ContainerRunning = func(_ context.Context, name string) bool { return name == "falconpulsar-ai-gateway" }
	e.DockerExec = func(context.Context, string, []string) error { return errors.New("exec failed") }
	out := filepath.Join(t.TempDir(), "b.tar.gz")
	if _, err := Backup(context.Background(), e, out, BackupOptions{}); err == nil {
		t.Fatal("want the snapshot failure")
	}
	noArchiveLeft(t, out)
}

func TestMintBackupKey(t *testing.T) {
	t.Run("exact", func(t *testing.T) {
		_, srv := newFakeCore(t, t.TempDir())
		key, err := MintBackupKey(context.Background(), srv.URL, "admin-jwt")
		if err != nil || key != "fp_minted" {
			t.Fatalf("%q %v", key, err)
		}
	})
	t.Run("wider key is revoked", func(t *testing.T) {
		fc, srv := newFakeCore(t, t.TempDir())
		fc.mintPerms = []string{"DATA_READ", "SYSTEM_ADMIN", "SYSTEM_BACKUP"}
		key, err := MintBackupKey(context.Background(), srv.URL, "admin-jwt")
		if err == nil || key != "" {
			t.Fatalf("a wider key must never be returned: %q %v", key, err)
		}
		if len(fc.revoked) != 1 || fc.revoked[0] != "tok-1" {
			t.Errorf("the wider key must be revoked: %v", fc.revoked)
		}
	})
	t.Run("older Core is never asked to mint", func(t *testing.T) {
		fc, srv := newFakeCore(t, t.TempDir())
		fc.mode = "older200"
		if _, err := MintBackupKey(context.Background(), srv.URL, "admin-jwt"); !errors.Is(err, ErrNoLease) {
			t.Fatalf("want ErrNoLease, got %v", err)
		}
		for _, c := range fc.calls {
			if strings.HasPrefix(c, "POST /api/v1/tokens") {
				t.Fatalf("minted on a Core without the lease: it would be a full admin key")
			}
		}
	})
}

func TestCheckBackupKeyAndTheHint(t *testing.T) {
	fc, srv := newFakeCore(t, t.TempDir())
	ctx := context.Background()
	if st, _ := CheckBackupKey(ctx, srv.URL, ""); st != KeyAbsent {
		t.Errorf("absent: %v", st)
	}
	if st, _ := CheckBackupKey(ctx, srv.URL, fc.key); st != KeyOK {
		t.Errorf("ok: %v", st)
	}
	if st, _ := CheckBackupKey(ctx, srv.URL, "fp_other"); st != KeyRefused {
		t.Errorf("refused: %v", st)
	}
	if _, adv, err := LeaseAdvertised(ctx, srv.URL); !adv || err != nil {
		t.Errorf("hint: %v %v", adv, err)
	}
	fc.mode = "older404"
	if st, _ := CheckBackupKey(ctx, srv.URL, fc.key); st != KeyNoLease {
		t.Errorf("no lease: %v", st)
	}
	if _, adv, _ := LeaseAdvertised(ctx, srv.URL); adv {
		t.Errorf("an older Core does not advertise the lease")
	}
	if st, _ := CheckBackupKey(ctx, "http://127.0.0.1:1", fc.key); st != KeyUnreachable {
		t.Errorf("unreachable: %v", st)
	}
}

func TestLeaseAnswersAreCheckedBeforeCopying(t *testing.T) {
	for _, bad := range []string{"../etc/passwd", "/abs", "a/../b", ".fp-backup/x", "a//b", ""} {
		l := Lease{ID: "0123456789abcdef0123456789abcdef", Files: []LeaseFile{{Path: bad, Length: 1}}}
		if l.check() == nil {
			t.Errorf("accepted %q", bad)
		}
	}
	if (Lease{ID: "NOT-HEX"}).check() == nil {
		t.Errorf("accepted a bad id")
	}
	s := Snapshot{Files: []SnapshotFile{{Path: ".fp-backup/other/meta/catalog.fpm", RestoreAs: "meta/catalog.fpm"}}}
	if s.check("0123456789abcdef0123456789abcdef", nil) == nil {
		t.Errorf("accepted another lease's snapshot")
	}
	s = Snapshot{Files: []SnapshotFile{{Path: ".fp-backup/0123456789abcdef0123456789abcdef/meta/catalog.fpm", RestoreAs: ".fp-backup/x"}}}
	if s.check("0123456789abcdef0123456789abcdef", nil) == nil {
		t.Errorf("accepted a restore into the backup area")
	}
}
