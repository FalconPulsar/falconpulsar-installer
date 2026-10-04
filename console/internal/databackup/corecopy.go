// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

package databackup

// How Core's data directory gets into the archive. Exactly one of:
//
//   - LIVE, under a Core backup lease (corelease.go): Core keeps running and
//     ingest is never refused. Every listed file is copied to exactly the
//     length Core gave, in list order, then the catalog snapshot, then the
//     lease is released on every exit path.
//   - COLD: Core is stopped (it was not running, or the operator consented
//     with --stop-core or at the prompt), the directory is copied while
//     nothing writes it, and Core is started again before the copy is
//     archived.
//   - NOT CAPTURED: neither was possible. The archive holds every other
//     service, the manifest says why Core is missing, and fp backup exits
//     non-zero.
//
// There is no fourth way. A live copy without a lease is torn in ways no power
// cut produces (WAL reclaimed between the partitions and the WAL; a catalog
// read while commits land), so fp backup never makes one.

import (
	"archive/tar"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const coreContainer = "falconpulsar-core"

// coreStopTimeout is how long Core gets to close before Docker kills it.
// Compose sets no stop_grace_period for core, and Docker's default of 10 s
// SIGKILLs a final checkpoint that takes longer (about 17 s at 100k series).
const coreStopTimeout = 180 * time.Second

// leaseCheckEvery is how often a long copy asks Core whether the lease is
// still active, so a TTL or WAL-cap abort ends the copy early with Core's
// reason instead of at the catalog call. A var for tests.
var leaseCheckEvery = 10 * time.Second

// Why Core was not captured (CoreCapture.Cause).
const (
	CauseNoKey         = "no-key"         // no FP_BACKUP_KEY, or Core refused it
	CauseNoLease       = "no-lease"       // an older Core
	CauseLeaseRefused  = "lease-refused"  // Core refused a lease (507, 501, …)
	CauseAnotherBackup = "another-backup" // 409: a lease is already active
	CauseUnreachable   = "unreachable"    // Core did not answer
	CauseCannotCopy    = "cannot-copy"    // no copy of the directory can hold it (a symbolic link, no directory)
)

// Core capture modes (CoreCapture.Mode).
const (
	CoreLease       = "lease"
	CoreCold        = "cold"
	CoreNotCaptured = "not-captured"
	CoreSkipped     = "skipped"
)

// CoreCapture records how Core's data directory got into the archive. An
// archive whose manifest lists core but has no CoreCapture was made by an
// fp backup older than the lease, which copied Core live without a fence.
type CoreCapture struct {
	Mode            string `json:"mode"`
	LeaseID         string `json:"lease_id,omitempty"`
	CatalogSequence uint64 `json:"catalog_sequence,omitempty"`
	// StoppedSeconds: how long Core was down for a cold copy (stop to healthy).
	StoppedSeconds int `json:"stopped_seconds,omitempty"`
	// WasStopped: a cold copy of a Core that was not running to begin with.
	WasStopped bool   `json:"was_stopped,omitempty"`
	Reason     string `json:"reason,omitempty"`
	// Cause classifies Reason for the operator's next step (Cause* below).
	Cause       string `json:"cause,omitempty"`
	CoreVersion string `json:"core_version,omitempty"`
	Files       int    `json:"files,omitempty"`
	Bytes       int64  `json:"bytes,omitempty"`

	restartErr error // a cold copy whose Core did not start again
}

// Captured reports whether the archive holds Core's data directory.
func (c CoreCapture) Captured() bool { return c.Mode == CoreLease || c.Mode == CoreCold }

// Semantics is the manifest's one-line description. Never "crash-consistent".
func (c CoreCapture) Semantics() string {
	switch c.Mode {
	case CoreLease:
		return fmt.Sprintf("live, consistent (Core backup lease %s, catalog sequence %d)", c.LeaseID, c.CatalogSequence)
	case CoreCold:
		if c.WasStopped {
			return "cold-copy (Core was not running)"
		}
		return fmt.Sprintf("cold-copy (Core stopped %d s)", c.StoppedSeconds)
	case CoreSkipped:
		return "not captured — excluded with --skip-core"
	default:
		return "not captured — " + c.Reason
	}
}

// CoreNotCapturedError is Backup's answer when the archive was written
// without Core: every other service is in it, Core is not.
type CoreNotCapturedError struct{ Reason string }

func (e *CoreNotCapturedError) Error() string { return "core: not captured — " + e.Reason }

// CoreRestartError is Backup's answer when the archive is complete but Core,
// stopped for a cold copy, did not start again.
type CoreRestartError struct{ Err error }

func (e *CoreRestartError) Error() string {
	return fmt.Sprintf("the archive is complete, but Core did not start again after its cold copy: %v — start it now with fp start", e.Err)
}

func (e *CoreRestartError) Unwrap() error { return e.Err }

func logf(opts BackupOptions, format string, args ...any) {
	if opts.Log != nil {
		fmt.Fprintf(opts.Log, format+"\n", args...)
	}
}

// backupCore puts Core's data directory into tw, or says why it could not.
// An error is fatal for the whole backup; a capture with Mode
// CoreNotCaptured is not.
func backupCore(ctx context.Context, e Env, tw *tar.Writer, opts BackupOptions) (CoreCapture, error) {
	if opts.SkipCore {
		return CoreCapture{Mode: CoreSkipped}, nil
	}
	if !dirExists(e.CoreDir) {
		return CoreCapture{Mode: CoreNotCaptured, Cause: CauseCannotCopy,
			Reason: fmt.Sprintf("Core's data directory %s does not exist", e.CoreDir)}, nil
	}
	if !e.ContainerRunning(ctx, coreContainer) {
		return coldCopyAtRest(ctx, e, tw, opts)
	}

	why, cause, mayStop := "", CauseNoKey, true
	if e.BackupKey == "" {
		why = "there is no backup key (" + BackupKeyEnv + ") in the stack's .env: run fp backup once in a terminal to create it, or re-run the installer"
	} else {
		cl := newCoreClient(e.CoreURL, e.BackupKey)
		pctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		_, err := cl.Capability(pctx)
		cancel()
		var ae *APIError
		switch {
		case ctx.Err() != nil:
			return CoreCapture{}, ctx.Err()
		case err == nil:
			began := time.Now()
			lease, err := cl.Begin(ctx, opts.LeaseTTL)
			if err == nil {
				capture, err := leaseCopy(ctx, e, tw, cl, lease, opts)
				capture.CoreVersion = coreVersion(ctx, e)
				return capture, err
			}
			if ctx.Err() != nil {
				releaseOrphan(cl, began, opts)
				return CoreCapture{}, ctx.Err()
			}
			if errors.As(err, &ae) {
				why, cause = "Core refused a backup lease: "+ae.Message, CauseLeaseRefused
				if ae.Status == http.StatusConflict {
					// Another backup holds a lease. Stopping Core would end it.
					cause, mayStop = CauseAnotherBackup, false
				}
			} else {
				releaseOrphan(cl, began, opts)
				why, cause = "Core did not answer the request for a backup lease: "+err.Error(), CauseUnreachable
			}
		case errors.Is(err, ErrNoLease):
			why, cause = "this Core cannot make a consistent live copy: it has no backup lease (it is older than the release that adds one)", CauseNoLease
		case errors.As(err, &ae) && (ae.Status == http.StatusUnauthorized || ae.Status == http.StatusForbidden):
			why = fmt.Sprintf("Core refused the backup key in .env (HTTP %d): it was revoked, or minted on another Core; run fp backup in a terminal to make a new one", ae.Status)
		default:
			why, cause = "Core did not answer the backup lease probe: "+err.Error(), CauseUnreachable
		}
	}
	if mayStop && (opts.StopCore || (opts.ConfirmStop != nil && opts.ConfirmStop(why))) {
		capture, err := coldCopyStopping(ctx, e, tw, opts, why)
		if capture.Mode == CoreNotCaptured && capture.Cause == "" {
			capture.Cause = cause
		}
		return capture, err
	}
	return CoreCapture{Mode: CoreNotCaptured, Reason: why, Cause: cause}, nil
}

// releaseOrphan releases a lease whose begin answer never arrived: the
// connection dropped, or the operator interrupted, after Core began it. Core
// would otherwise hold WAL for it until its TTL. Only a lease that began after
// our request was sent is ours to release.
func releaseOrphan(cl *coreClient, began time.Time, opts BackupOptions) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var cur struct {
		Backup *LeaseStatus `json:"backup"`
	}
	if err := cl.do(ctx, http.MethodGet, "/api/v1/_system/backup", nil, http.StatusOK, &cur); err != nil || cur.Backup == nil {
		return
	}
	since, err := time.Parse(time.RFC3339, cur.Backup.Since)
	if err != nil || since.Before(began.Add(-2*time.Second)) {
		return // not ours: it began before we asked
	}
	if err := cl.Release(ctx, cur.Backup.ID); err == nil {
		logf(opts, "core: released backup lease %s, whose answer never arrived", cur.Backup.ID)
	}
}

func coreVersion(ctx context.Context, e Env) string {
	if e.CoreURL == "" {
		return ""
	}
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	pc, _, _ := LeaseAdvertised(cctx, e.CoreURL)
	return pc.Version
}

// leaseCopy copies Core's data directory under lease l and releases it on
// every way out.
func leaseCopy(ctx context.Context, e Env, tw *tar.Writer, cl *coreClient, l Lease, opts BackupOptions) (capture CoreCapture, err error) {
	defer func() {
		// A fresh context: the operator's Ctrl-C cancelled ctx, and the lease
		// must still be released (Core would otherwise hold its WAL until the TTL).
		rctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if rerr := cl.Release(rctx, l.ID); rerr != nil {
			logf(opts, "warning: releasing backup lease %s failed (%v); Core ends it itself at %s", l.ID, rerr, l.ExpiresAt)
		}
	}()
	if err := l.check(); err != nil {
		return capture, err
	}
	logf(opts, "core: live copy under backup lease %s (%d files, %s); ingest goes on",
		l.ID, len(l.Files), humanBytes(l.TotalBytes))

	listed := make(map[string]bool, len(l.Files))
	var copied int64
	lastCheck := time.Now()
	for i, f := range l.Files {
		if err := ctx.Err(); err != nil {
			return capture, err
		}
		if time.Since(lastCheck) >= leaseCheckEvery {
			lastCheck = time.Now()
			if st, err := cl.Status(ctx, l.ID); err == nil && st.State != "active" {
				return capture, leaseEnded(st.State, st.Reason)
			}
		}
		// The list order is what makes the copy consistent (every file but the
		// WAL and the blobs, then the WAL, then the blobs): copy in that order.
		n, err := addPrefix(ctx, tw, filepath.Join(e.CoreDir, filepath.FromSlash(f.Path)), "core/"+f.Path, f.Length)
		if err != nil {
			return capture, err
		}
		copied += n
		listed[f.Path] = true
		if opts.afterCoreFile != nil {
			opts.afterCoreFile(i, len(l.Files), f.Path)
		}
	}

	// Catalog last: every series with data in the copy has a record, and
	// wal_next_lsn is above every LSN copied.
	snap, err := cl.CatalogSnapshot(ctx, l.ID)
	if err != nil {
		return capture, catalogRefusal(ctx, cl, l.ID, err)
	}
	if err := snap.check(l.ID, listed); err != nil {
		return capture, err
	}
	for _, f := range snap.Files {
		n, err := addWhole(ctx, tw, filepath.Join(e.CoreDir, filepath.FromSlash(f.Path)), "core/"+f.RestoreAs)
		if err != nil {
			return capture, err
		}
		copied += n
	}
	logf(opts, "core: catalog snapshot at sequence %d (catalog changes waited %d ms)", snap.CatalogSequence, snap.CatalogWaitMS)
	return CoreCapture{
		Mode: CoreLease, LeaseID: l.ID, CatalogSequence: snap.CatalogSequence,
		Files: len(l.Files) + len(snap.Files), Bytes: copied,
	}, nil
}

func leaseEnded(state, reason string) error {
	if reason == "" {
		reason = "no reason given"
	}
	return fmt.Errorf("Core ended the backup lease before the copy finished (%s: %s); the plant carried on — run fp backup again", state, reason)
}

// catalogRefusal turns a failed catalog call into the sentence an operator
// needs.
func catalogRefusal(ctx context.Context, cl *coreClient, id string, err error) error {
	var ae *APIError
	if !errors.As(err, &ae) {
		return fmt.Errorf("asking Core for its catalog snapshot: %w", err)
	}
	switch ae.Status {
	case http.StatusGatewayTimeout:
		return fmt.Errorf("Core aborted the backup: copying its catalog would have made catalog changes wait past the cap (%s); the plant carried on — run fp backup again", ae.Message)
	case http.StatusConflict:
		sctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		if st, serr := cl.Status(sctx, id); serr == nil {
			return leaseEnded(st.State, st.Reason)
		}
		return leaseEnded(ae.State, ae.Message)
	}
	return fmt.Errorf("Core refused the catalog snapshot: %w", err)
}

// ShortFileError: a listed file holds fewer bytes than Core listed.
type ShortFileError struct {
	Path        string
	Have, Wants int64
}

func (e *ShortFileError) Error() string {
	return fmt.Sprintf("%s holds %d bytes, fewer than the %d Core listed: a partition tail left by a failed flush or an earlier crash was cut during the backup — run fp backup again", e.Path, e.Have, e.Wants)
}

// ctxReader stops a long copy when the operator interrupts.
type ctxReader struct {
	ctx context.Context
	r   io.Reader
}

func (c ctxReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(p)
}

// addPrefix archives exactly length bytes of hostPath as arcPath: Core's
// COPIER RULE. Never the file's current size, which may already be past
// what Core listed; a file that holds fewer bytes fails the backup.
func addPrefix(ctx context.Context, tw *tar.Writer, hostPath, arcPath string, length int64) (int64, error) {
	st, err := os.Lstat(hostPath)
	if err != nil {
		return 0, err
	}
	if !st.Mode().IsRegular() {
		return 0, fmt.Errorf("%s is not a regular file", hostPath)
	}
	f, err := os.Open(hostPath)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	if err := tw.WriteHeader(&tar.Header{
		Typeflag: tar.TypeReg, Name: arcPath, Mode: int64(st.Mode().Perm()),
		Size: length, ModTime: st.ModTime(),
	}); err != nil {
		return 0, err
	}
	n, err := io.CopyN(tw, ctxReader{ctx, f}, length)
	if err == io.EOF {
		return n, &ShortFileError{Path: hostPath, Have: n, Wants: length}
	}
	return n, err
}

// addWhole archives a file that nothing writes any more (Core's catalog
// snapshot, a stopped Core's files) at the size it has.
func addWhole(ctx context.Context, tw *tar.Writer, hostPath, arcPath string) (int64, error) {
	st, err := os.Lstat(hostPath)
	if err != nil {
		return 0, err
	}
	return addPrefix(ctx, tw, hostPath, arcPath, st.Size())
}

// ── Cold copies ─────────────────────────────────────────────────────────

// coldSkip reports whether rel (slash-separated, relative to Core's data
// directory) stays out of a cold copy: what Core's own lease leaves out and
// does not bring back in its snapshot. The logs, Core's backup area, a
// volume's lost+found, and half-written temporary files.
func coldSkip(rel string) bool {
	name := rel[strings.LastIndex(rel, "/")+1:]
	if strings.HasSuffix(name, ".tmp") || name == ".DS_Store" {
		return true
	}
	if !strings.Contains(rel, "/") {
		switch name {
		case "logs", "lost+found", coreBackupDir:
			return true
		}
		if strings.HasPrefix(name, "fp_database.hdr.") {
			return true
		}
	}
	return false
}

// symlinkRefusal says why a data directory holding a symbolic link cannot be
// copied: Core reads data through it, and a copy of the directory would hold
// the link and not what is behind it (Core's lease refuses the same way).
func symlinkRefusal(rel string) string {
	return fmt.Sprintf("%s in Core's data directory is a symbolic link: Core reads data through it, and a copy of the directory cannot hold what is behind it", rel)
}

// scanCore sizes Core's data directory and finds the first symbolic link in
// it, before anything is stopped.
func scanCore(root string) (size int64, link string, err error) {
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if p == root {
			return nil
		}
		rel := filepath.ToSlash(mustRel(root, p))
		if coldSkip(rel) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			link = rel
			return filepath.SkipAll
		}
		if d.Type().IsRegular() {
			if info, err := d.Info(); err == nil {
				size += info.Size()
			}
		}
		return nil
	})
	return size, link, err
}

func mustRel(root, p string) string {
	rel, err := filepath.Rel(root, p)
	if err != nil {
		return p
	}
	return rel
}

// tarCoreTree archives a directory nothing writes (a stopped Core's, or the
// staging copy of one) under prefix.
func tarCoreTree(ctx context.Context, tw *tar.Writer, root, prefix string) (files int, bytes int64, err error) {
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if p == root {
			return nil
		}
		rel := filepath.ToSlash(mustRel(root, p))
		if coldSkip(rel) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return errors.New(symlinkRefusal(rel))
		}
		if !d.Type().IsRegular() {
			return nil // directories are implied; sockets and devices hold no data
		}
		n, err := addWhole(ctx, tw, p, prefix+"/"+rel)
		if err != nil {
			return err
		}
		files++
		bytes += n
		return nil
	})
	return files, bytes, err
}

// copyTree copies a stopped Core's data directory to dst, as fast as the
// filesystem allows (Go copies with copy_file_range on Linux, which reflinks
// where the filesystem can).
func copyTree(ctx context.Context, src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if p == src {
			return nil
		}
		rel := mustRel(src, p)
		if coldSkip(filepath.ToSlash(rel)) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		target := filepath.Join(dst, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.Type()&fs.ModeSymlink != 0:
			return errors.New(symlinkRefusal(filepath.ToSlash(rel)))
		case d.IsDir():
			return os.MkdirAll(target, info.Mode().Perm()|0o700)
		case !d.Type().IsRegular():
			return nil
		}
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, info.Mode().Perm()|0o600)
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, ctxReader{ctx, in}); err != nil {
			out.Close()
			return err
		}
		if err := out.Close(); err != nil {
			return err
		}
		return os.Chtimes(target, info.ModTime(), info.ModTime())
	})
}

// coldCopyAtRest archives the data directory of a Core that is not running.
// Nothing writes it, so the copy is exact. If Core starts while it is being
// read, the copy is no longer cold and the backup fails.
func coldCopyAtRest(ctx context.Context, e Env, tw *tar.Writer, opts BackupOptions) (CoreCapture, error) {
	_, link, err := scanCore(e.CoreDir)
	if err != nil {
		return CoreCapture{}, err
	}
	if link != "" {
		return CoreCapture{Mode: CoreNotCaptured, Cause: CauseCannotCopy, Reason: symlinkRefusal(link)}, nil
	}
	logf(opts, "core: Core is not running; copying its data directory as it is")
	files, n, err := tarCoreTree(ctx, tw, e.CoreDir, "core")
	if err != nil {
		return CoreCapture{}, err
	}
	if e.ContainerRunning(ctx, coreContainer) {
		return CoreCapture{}, errors.New("Core started while its stopped data directory was being copied, so the copy is not cold — run fp backup again")
	}
	return CoreCapture{Mode: CoreCold, WasStopped: true, Files: files, Bytes: n}, nil
}

// coldCopyStopping is the operator-consented fallback (C2): stop Core, copy
// its data directory locally, start Core, then archive the copy. Core is
// down only for the local copy, not for the compression.
func coldCopyStopping(ctx context.Context, e Env, tw *tar.Writer, opts BackupOptions, why string) (capture CoreCapture, err error) {
	notCaptured := func(more string) (CoreCapture, error) {
		return CoreCapture{Mode: CoreNotCaptured, Reason: why + "; and no cold copy either: " + more}, nil
	}
	size, link, err := scanCore(e.CoreDir)
	if err != nil {
		return capture, err
	}
	if link != "" {
		capture, err := notCaptured(symlinkRefusal(link))
		capture.Cause = CauseCannotCopy
		return capture, err
	}
	parent := filepath.Dir(filepath.Clean(e.CoreDir))
	need := size + size/20 + 64<<20
	if free, ferr := freeBytes(parent); ferr == nil && free < need {
		return notCaptured(fmt.Sprintf("it needs %s free in %s and there is %s", humanBytes(need), parent, humanBytes(free)))
	}
	stage, err := os.MkdirTemp(parent, ".fp-core-cold-")
	if err != nil {
		return notCaptured("its staging directory could not be made: " + err.Error())
	}
	defer os.RemoveAll(stage)

	logf(opts, "core: %s", why)
	logf(opts, "core: stopping Core for a cold copy of %s (it is down until the local copy is made)", humanBytes(size))
	t0 := time.Now()
	restarted := false
	var startErr error
	restart := func() {
		if restarted {
			return
		}
		restarted = true
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		startErr = e.StartCore(sctx)
	}
	// Core is started again on every way out, signals included.
	defer func() {
		restart()
		if startErr != nil && err == nil {
			capture.restartErr = startErr
		} else if startErr != nil {
			err = fmt.Errorf("%w; and Core did not start again: %v — start it now with fp start", err, startErr)
		}
	}()
	if err := e.StopCore(ctx); err != nil {
		return capture, fmt.Errorf("stopping Core for a cold copy: %w", err)
	}
	if e.ContainerRunning(context.WithoutCancel(ctx), coreContainer) {
		return capture, errors.New("Core is still running after it was stopped; the copy was not made")
	}
	if err := copyTree(ctx, e.CoreDir, stage); err != nil {
		return capture, fmt.Errorf("cold copy: %w", err)
	}
	restart()
	if startErr == nil {
		waitCoreHealthy(ctx, e.CoreURL, 3*time.Minute)
	}
	down := int(time.Since(t0).Round(time.Second) / time.Second)
	if down < 1 {
		down = 1
	}
	if startErr == nil {
		logf(opts, "core: Core is running again after %d s; archiving the copy", down)
	}
	files, n, err := tarCoreTree(ctx, tw, stage, "core")
	if err != nil {
		return capture, err
	}
	return CoreCapture{Mode: CoreCold, StoppedSeconds: down, Reason: why, Files: files, Bytes: n}, nil
}

// WaitCoreHealthy waits until Core's public health route answers 200, or the
// time is up. It reports whether Core answered.
func WaitCoreHealthy(ctx context.Context, baseURL string, within time.Duration) bool {
	return waitCoreHealthy(ctx, baseURL, within)
}

func waitCoreHealthy(ctx context.Context, baseURL string, within time.Duration) bool {
	if baseURL == "" {
		return false
	}
	deadline := time.Now().Add(within)
	client := &http.Client{Timeout: 3 * time.Second}
	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(baseURL, "/")+"/api/v1/health", nil)
		if err != nil {
			return false
		}
		if resp, err := client.Do(req); err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return true
			}
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(time.Second):
		}
	}
}

func realStopCore(ctx context.Context) error {
	return runDocker(ctx, "stop", "-t", strconv.Itoa(int(coreStopTimeout/time.Second)), coreContainer)
}

func realStartCore(ctx context.Context) error {
	return runDocker(ctx, "start", coreContainer)
}

func runDocker(ctx context.Context, args ...string) error {
	out, err := exec.CommandContext(ctx, "docker", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker %s: %v — %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}
