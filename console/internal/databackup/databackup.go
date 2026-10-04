// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

// Package databackup implements `fp backup` / `fp restore` — the DATA
// counterpart to configbackup's .fpconfig (which carries configuration and
// Core API exports, encrypted). This one carries the stack's actual stores:
//
//	manifest.json                    what, when, from which versions
//	config/{compose.yml,.env,gateway.yaml}
//	gateway/*.db                     the AI Gateway's seven SQLite stores
//	engine/db/fp-agentics.db         the Engine's one database
//	engine/{agentspecs,workorders,outbox,replay,models}/… and engine/fleet-vitals.jsonl
//	copilot/command-center.db
//	core/…                           TimeSeries Core's whole data directory
//
// CONSISTENCY. Every SQLite file is snapshotted with VACUUM INTO executed
// INSIDE its owning container (phase-4 discipline: one writer per file, and
// that writer makes the copy), which yields a point-in-time, WAL-free,
// defragmented database regardless of live traffic. A stopped container's
// files are copied cold (db + -wal + -shm), which is equally consistent.
// Core's data directory is copied under a Core BACKUP LEASE while Core runs
// (corelease.go, corecopy.go): Core holds every deletion and rewrite that
// could tear the copy, lists each file with the bytes to copy, and snapshots
// its catalog under its own lock at the end. A Core without the lease is
// copied cold only with the operator's consent (--stop-core or the prompt),
// and is otherwise left out and named as missing. A file-by-file live copy
// of Core is NOT crash-consistent (WAL reclaimed mid-copy, a catalog read
// while commits land), so fp backup never makes one. The manifest records
// which semantics each entry got.
//
// RESTORE never destroys: everything it replaces is set aside as
// <name>.pre-restore-<stamp> beside the original, and the operator is told
// what to delete once satisfied.
package databackup

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Manifest is the archive's first entry.
type Manifest struct {
	Kind       string            `json:"kind"` // "falconpulsar-data-backup"
	Version    int               `json:"version"`
	CreatedAt  string            `json:"created_at"`
	FPVersion  string            `json:"fp_version,omitempty"`
	Host       string            `json:"host,omitempty"`
	Services   []string          `json:"services"`
	Semantics  map[string]string `json:"semantics"` // service -> point-in-time | live, consistent | cold-copy | not captured
	SkipedCore bool              `json:"skipped_core,omitempty"`
	// Core says how Core's data directory was captured, or why it was not.
	// Absent in archives made before the backup lease: those copied Core
	// live with no fence, and their "crash-consistent" label was not true.
	Core *CoreCapture `json:"core,omitempty"`
}

const (
	manifestKind    = "falconpulsar-data-backup"
	manifestVersion = 1
	stagingDirName  = ".fp-backup-staging"
)

// target describes one service's data on the host.
type target struct {
	name      string   // archive prefix + --only name
	container string   // docker container that owns the writes
	hostDir   string   // host path of the mounted data dir
	dbs       []string // SQLite files, relative to hostDir
	extras    []string // directories copied as-is, relative to hostDir
	// Single files copied cold, relative to hostDir. For append-only or
	// atomically-renamed logs (the engine writes <file>.tmp then renames),
	// a reader always sees a complete file, so no in-container snapshot is
	// needed even while the service runs.
	files []string
	// runner produces an in-container command that snapshots relSrc into
	// relDst (both container-absolute); empty runner = cold copy only.
	runner func(containerData, relSrc, relDst string) []string
}

// Env is the small slice of stack configuration Backup/Restore need.
// Kept injectable so unit tests run against a fake stack directory.
type Env struct {
	Home       string // FP_HOME (…/falconpulsar)
	CoreDir    string // FP_DATA_DIR
	GatewayDir string
	EngineDir  string
	CopilotDir string
	FPVersion  string
	// CoreURL is Core's REST API on this host (FP_REST_PORT honoured).
	CoreURL string
	// BackupKey is the API key scoped to SYSTEM_BACKUP alone (FP_BACKUP_KEY),
	// the one credential a backup needs. Empty = none minted yet.
	BackupKey string
	// Owner is FP_UID:FP_GID, the user every service container runs as; nil
	// when .env does not say. A restore run as root gives restored files to it.
	Owner *FileOwner
	// DockerExec runs `docker exec <container> <argv…>`; nil = real docker.
	DockerExec func(ctx context.Context, container string, argv []string) error
	// DockerOutput runs `docker exec <container> <argv…>` and returns its
	// standard output; nil = real docker.
	DockerOutput func(ctx context.Context, container string, argv []string) (string, error)
	// ContainerRunning reports whether the named container is up; nil = real docker.
	ContainerRunning func(ctx context.Context, container string) bool
	// StopCore stops Core's container for a cold copy, giving it time to
	// close (docker stop -t 180); StartCore starts it again. nil = real docker.
	StopCore  func(ctx context.Context) error
	StartCore func(ctx context.Context) error
}

// FileOwner is a numeric uid:gid.
type FileOwner struct{ UID, GID int }

func pyVacuum(containerData, src, dst string) []string {
	return []string{"python", "-c", fmt.Sprintf(
		`import sqlite3; sqlite3.connect(%q).execute("VACUUM INTO %s")`,
		containerData+"/"+src, quoteSQL(containerData+"/"+dst))}
}

func nodeVacuum(containerData, src, dst string) []string {
	return []string{"node", "-e", fmt.Sprintf(
		`const {DatabaseSync}=require('node:sqlite'); new DatabaseSync(%q).exec("VACUUM INTO %s")`,
		containerData+"/"+src, quoteSQL(containerData+"/"+dst))}
}

// quoteSQL renders a path as a single-quoted SQL string literal.
func quoteSQL(p string) string { return "'" + strings.ReplaceAll(p, "'", "''") + "'" }

func targets(e Env) []target {
	return []target{
		{
			name: "gateway", container: "falconpulsar-ai-gateway", hostDir: e.GatewayDir,
			dbs: []string{
				"conversations.db", "ssr.db", "user_memory.db", "ai_config.db",
				"confirm_ids.db", "watches.db", "knowledge.db", "proposals.db",
			},
			runner: func(cd, s, d string) []string { return pyVacuum("/app/data", s, d) },
		},
		{
			name: "engine", container: "falconpulsar-ai-engine", hostDir: e.EngineDir,
			dbs:    []string{"db/fp-agentics.db"},
			extras: []string{"agentspecs", "workorders", "outbox", "replay", "models", "config"},
			// The seven-day fleet vitals history (fleetVitals.ts). Named
			// exactly so the transient fleet-vitals.jsonl.tmp never travels.
			files:  []string{"fleet-vitals.jsonl"},
			runner: func(cd, s, d string) []string { return nodeVacuum("/data", s, d) },
		},
		{
			name: "copilot", container: "falconpulsar-copilot", hostDir: e.CopilotDir,
			dbs:    []string{"command-center.db"},
			runner: func(cd, s, d string) []string { return nodeVacuum("/data", s, d) },
		},
	}
}

// ConfigStore names a SQLite file that holds CONFIGURATION rather than history
// — the things an operator expects to survive a rebuild.
type ConfigStore struct {
	Container string // docker container that owns the file
	HostDir   string // host directory the container's data volume maps to
	Rel       string // path of the db relative to that directory
	Runner    func(containerDir, src, dst string) []string
}

// ConfigStores lists the stores a CONFIGURATION backup should carry. It is
// deliberately narrower than targets(): conversations, user memory, replay and
// outbox are history, and belong to the data backup instead.
func ConfigStores(e Env) []ConfigStore {
	py := func(cd, s, d string) []string { return pyVacuum("/app/data", s, d) }
	node := func(cd, s, d string) []string { return nodeVacuum("/data", s, d) }
	return []ConfigStore{
		// providers, models, API keys, gateway settings
		{"falconpulsar-ai-gateway", e.GatewayDir, "ai_config.db", py},
		// semantic registry + terminology packs — declared by hand, expensive to lose
		{"falconpulsar-ai-gateway", e.GatewayDir, "ssr.db", py},
		// user-authored knowledge documents
		{"falconpulsar-ai-gateway", e.GatewayDir, "knowledge.db", py},
		// Watches are authored by a person and say what the plant should keep an
		// eye on — configuration, not history, even though the same file also
		// holds each watch's last stored snapshot. Rebuilding a server without
		// them means someone has to remember what was being watched.
		{"falconpulsar-ai-gateway", e.GatewayDir, "watches.db", py},
		// agents, specs, reports, notification channels, schedules
		{"falconpulsar-ai-engine", e.EngineDir, "db/fp-agentics.db", node},
		{"falconpulsar-copilot", e.CopilotDir, "command-center.db", node},
	}
}

// SnapshotConfigStore writes a consistent copy of one store to hostDst.
//
// It must go through VACUUM INTO inside the container, never a host-side file
// copy: every one of these databases is opened WAL (the gateway sets
// PRAGMA journal_mode=WAL for all of them), so recent commits can live entirely
// in the -wal sidecar. Reading the main file alone yields a database that is
// missing them — or, mid-checkpoint, one that is internally inconsistent.
//
// Returns false when the container is not running or the file does not exist;
// that is not an error, it just means there is nothing to capture.
func SnapshotConfigStore(ctx context.Context, e Env, s ConfigStore, hostDst string) (bool, error) {
	if e.DockerExec == nil {
		e.DockerExec = realDockerExec
	}
	if e.ContainerRunning == nil {
		e.ContainerRunning = realContainerRunning
	}
	if s.HostDir == "" {
		return false, nil
	}
	if _, err := os.Stat(filepath.Join(s.HostDir, s.Rel)); err != nil {
		return false, nil // store not present on this install
	}
	if !e.ContainerRunning(ctx, s.Container) {
		return false, fmt.Errorf("%s is not running, so %s cannot be snapshotted consistently",
			s.Container, s.Rel)
	}

	// VACUUM INTO refuses to overwrite, so the destination must not exist. Write
	// beside the source (inside the volume) and move it out afterwards.
	tmpRel := s.Rel + ".fpconfig-snapshot"
	tmpHost := filepath.Join(s.HostDir, tmpRel)
	_ = os.Remove(tmpHost)

	if err := e.DockerExec(ctx, s.Container, s.Runner("", s.Rel, tmpRel)); err != nil {
		return false, fmt.Errorf("snapshot %s: %w", s.Rel, err)
	}
	defer os.Remove(tmpHost)

	data, err := os.ReadFile(tmpHost)
	if err != nil {
		return false, fmt.Errorf("read snapshot of %s: %w", s.Rel, err)
	}
	if err := os.MkdirAll(filepath.Dir(hostDst), 0o755); err != nil {
		return false, err
	}
	if err := os.WriteFile(hostDst, data, 0o600); err != nil {
		return false, err
	}
	return true, nil
}

// LoadEnv resolves the stack layout from ${FP_HOME}/.env with the same
// defaults compose.yml uses.
func LoadEnv(home string) Env {
	vals := parseDotEnv(filepath.Join(home, ".env"))
	coreDir := vals["FP_DATA_DIR"]
	if coreDir == "" {
		coreDir = filepath.Join(home, "data")
	}
	orDefault := func(key, def string) string {
		if v := vals[key]; v != "" {
			return v
		}
		return def
	}
	base := filepath.Dir(coreDir)
	restPort := "7433"
	if n, err := strconv.Atoi(vals["FP_REST_PORT"]); err == nil && n > 0 && n < 65536 {
		restPort = vals["FP_REST_PORT"]
	}
	var owner *FileOwner
	uid, uerr := strconv.Atoi(vals["FP_UID"])
	gid, gerr := strconv.Atoi(vals["FP_GID"])
	if uerr == nil && gerr == nil && uid >= 0 && gid >= 0 {
		owner = &FileOwner{UID: uid, GID: gid}
	}
	return Env{
		Home:       home,
		CoreDir:    coreDir,
		GatewayDir: orDefault("FP_GATEWAY_DATA_DIR", filepath.Join(base, "ai-gateway-data")),
		EngineDir:  orDefault("FP_ENGINE_DATA_DIR", filepath.Join(base, "ai-engine-data")),
		CopilotDir: orDefault("FP_COPILOT_DATA_DIR", filepath.Join(base, "copilot-data")),
		FPVersion:  vals["FP_VERSION"],
		CoreURL:    "http://localhost:" + restPort,
		BackupKey:  vals[BackupKeyEnv],
		Owner:      owner,
	}
}

func parseDotEnv(path string) map[string]string {
	out := map[string]string{}
	data, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok {
			out[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), `"'`)
		}
	}
	return out
}

// BackupOptions for Backup.
type BackupOptions struct {
	// SkipCore leaves Core's data directory out (--skip-core).
	SkipCore bool
	// StopCore is the operator's consent (--stop-core) to stop Core for a
	// cold copy when it cannot make a consistent live one.
	StopCore bool
	// ConfirmStop asks the operator whether to stop Core for a cold copy;
	// why says what stands in the way of a live copy. nil = never ask
	// (unattended runs), and Core is left out.
	ConfirmStop func(why string) bool
	// LeaseTTL is the backup lease's time to live; 0 = Core's default (2 h).
	LeaseTTL time.Duration
	// Log receives progress lines; nil = silent.
	Log io.Writer

	// afterCoreFile runs after each listed Core file is copied (tests).
	afterCoreFile func(i, n int, path string)
}

// Backup writes a .tar.gz at outPath and returns its manifest.
//
// The archive is written to a temporary file beside outPath and renamed into
// place only when it is complete; on any failure, or an interrupt, the
// partial file is deleted, so outPath never holds a half-written archive.
//
// When Core could not be captured the archive is still written (every other
// service is in it) and the error is a *CoreNotCapturedError naming why.
func Backup(ctx context.Context, e Env, outPath string, opts BackupOptions) (man Manifest, err error) {
	if e.DockerExec == nil {
		e.DockerExec = realDockerExec
	}
	if e.ContainerRunning == nil {
		e.ContainerRunning = realContainerRunning
	}
	if e.StopCore == nil {
		e.StopCore = realStopCore
	}
	if e.StartCore == nil {
		e.StartCore = realStartCore
	}

	man = Manifest{
		Kind: manifestKind, Version: manifestVersion,
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
		FPVersion: e.FPVersion, Semantics: map[string]string{},
		SkipedCore: opts.SkipCore,
	}
	if h, err := os.Hostname(); err == nil {
		man.Host = h
	}

	out, err := os.CreateTemp(filepath.Dir(outPath), "."+filepath.Base(outPath)+".partial-*")
	if err != nil {
		return man, err
	}
	tmpPath := out.Name()
	committed := false
	defer func() {
		if !committed {
			out.Close()
			os.Remove(tmpPath)
		}
	}()
	gz := gzip.NewWriter(out)
	tw := tar.NewWriter(gz)

	// Core first: its lease is held for the shortest time, and an operator
	// asked whether to stop Core is asked before anything else is copied.
	core, err := backupCore(ctx, e, tw, opts)
	if err != nil {
		var down *CoreDownError
		switch {
		case ctx.Err() != nil && errors.As(err, &down):
			return man, fmt.Errorf("interrupted: %w", err) // the operator must hear that Core is down
		case ctx.Err() != nil:
			return man, fmt.Errorf("interrupted: %w", ctx.Err())
		}
		return man, fmt.Errorf("core: %w", err)
	}
	man.Core = &core

	for _, t := range targets(e) {
		if err := ctx.Err(); err != nil {
			return man, fmt.Errorf("interrupted: %w", err)
		}
		if !dirExists(t.hostDir) {
			continue
		}
		sem, err := backupTarget(ctx, e, tw, t)
		if err != nil {
			return man, fmt.Errorf("%s: %w", t.name, err)
		}
		man.Services = append(man.Services, t.name)
		man.Semantics[t.name] = sem
	}
	switch {
	case core.Captured():
		man.Services = append(man.Services, "core")
		man.Semantics["core"] = core.Semantics()
	case core.Mode == CoreNotCaptured:
		man.Semantics["core"] = core.Semantics()
	}

	for _, f := range []string{"compose.yml", ".env", "gateway.yaml", "engine-seccomp.json"} {
		p := filepath.Join(e.Home, f)
		if fileExists(p) {
			if err := addFile(tw, p, "config/"+f); err != nil {
				return man, fmt.Errorf("config/%s: %w", f, err)
			}
		}
	}
	man.Services = append(man.Services, "config")

	// The manifest is the LAST entry: Peek, and so restore, refuses an
	// archive that does not reach it.
	mb, _ := json.MarshalIndent(man, "", "  ")
	if err := tw.WriteHeader(&tar.Header{
		Name: "manifest.json", Mode: 0o600, Size: int64(len(mb)),
		ModTime: time.Now(),
	}); err != nil {
		return man, err
	}
	if _, err := tw.Write(mb); err != nil {
		return man, err
	}
	if err := tw.Close(); err != nil {
		return man, err
	}
	if err := gz.Close(); err != nil {
		return man, err
	}
	if err := out.Sync(); err != nil {
		return man, err
	}
	if err := out.Close(); err != nil {
		return man, err
	}
	if err := os.Rename(tmpPath, outPath); err != nil {
		return man, err
	}
	committed = true
	_ = syncDir(filepath.Dir(outPath))

	if core.restartErr != nil {
		return man, &CoreRestartError{Err: core.restartErr}
	}
	if core.Mode == CoreNotCaptured {
		return man, &CoreNotCapturedError{Reason: core.Reason}
	}
	return man, nil
}

func backupTarget(ctx context.Context, e Env, tw *tar.Writer, t target) (string, error) {
	semantics := "cold-copy"
	running := e.ContainerRunning(ctx, t.container)

	staging := filepath.Join(t.hostDir, stagingDirName)
	if running {
		semantics = "point-in-time (VACUUM INTO in the owning container)"
		if err := os.MkdirAll(staging, 0o755); err != nil {
			return semantics, err
		}
		defer os.RemoveAll(staging)
	}

	for _, db := range t.dbs {
		src := filepath.Join(t.hostDir, db)
		if !fileExists(src) {
			continue // a store that never got created is not an error
		}
		arc := t.name + "/" + db
		if running {
			relDst := stagingDirName + "/" + strings.ReplaceAll(db, "/", "__")
			hostStaged := filepath.Join(t.hostDir, relDst)
			_ = os.Remove(hostStaged) // VACUUM INTO refuses to overwrite
			if err := e.DockerExec(ctx, t.container, t.runner("", db, relDst)); err != nil {
				return semantics, fmt.Errorf("snapshot %s: %w", db, err)
			}
			if err := addFile(tw, hostStaged, arc); err != nil {
				return semantics, err
			}
			continue
		}
		// Cold: the db plus its WAL/SHM siblings are consistent together.
		if err := addFile(tw, src, arc); err != nil {
			return semantics, err
		}
		for _, ext := range []string{"-wal", "-shm"} {
			if fileExists(src + ext) {
				if err := addFile(tw, src+ext, arc+ext); err != nil {
					return semantics, err
				}
			}
		}
	}

	for _, extra := range t.extras {
		dir := filepath.Join(t.hostDir, extra)
		if !dirExists(dir) {
			continue
		}
		if err := addTree(tw, dir, t.name+"/"+extra, func(p string) bool {
			base := filepath.Base(p)
			return base == ".DS_Store" || base == stagingDirName
		}); err != nil {
			return semantics, err
		}
	}

	for _, f := range t.files {
		src := filepath.Join(t.hostDir, f)
		if !fileExists(src) {
			continue // never written on this install
		}
		if err := addFile(tw, src, t.name+"/"+f); err != nil {
			return semantics, err
		}
	}
	return semantics, nil
}

// Options for Restore.
type RestoreOptions struct {
	// Only restricts restoration to these service names (empty = all in archive).
	Only []string
	// Warn receives what the operator must know but that does not stop the
	// restore (ownership it could not give); nil = discard.
	Warn func(string)
}

// Peek reads just the manifest from an archive.
func Peek(archive string) (Manifest, error) {
	var man Manifest
	f, err := os.Open(archive)
	if err != nil {
		return man, err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return man, err
	}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return man, err
		}
		if hdr.Name == "manifest.json" {
			data, err := io.ReadAll(tr)
			if err != nil {
				return man, err
			}
			if err := json.Unmarshal(data, &man); err != nil {
				return man, err
			}
			if man.Kind != manifestKind {
				return man, fmt.Errorf("not a FalconPulsar data backup (kind %q)", man.Kind)
			}
			return man, nil
		}
	}
	return man, fmt.Errorf("no manifest.json in archive")
}

// CoreFromOlderBackup reports whether an archive carries a Core directory
// copied by an fp backup older than the backup lease: live, file by file,
// with no fence. Such a copy may be torn (a catalog read while commits
// landed, WAL reclaimed mid-copy) although its manifest said
// "crash-consistent".
func (m Manifest) CoreFromOlderBackup() bool {
	if m.Core != nil {
		return false
	}
	for _, s := range m.Services {
		if s == "core" {
			return true
		}
	}
	return false
}

// isMountPoint is mountPoint, replaceable in tests.
var isMountPoint = mountPoint

// Restore places an archive's contents back onto the stack directories.
// The caller is responsible for stopping the affected services first and
// starting them after — the CLI layer owns that choreography (and the
// confirmation). Everything replaced is set aside, never deleted.
//
// Restored files and the directories made for them are given to the user
// the services run as (FP_UID:FP_GID) when the restore runs as root, so a
// restore under sudo does not leave Core a data directory it cannot write.
// Configuration files keep the owner and mode of the file they replace.
// Every restored file and directory is fsynced. Core's .fp-backup/ area is
// never restored.
func Restore(ctx context.Context, e Env, archive string, opts RestoreOptions) ([]string, error) {
	man, err := Peek(archive)
	if err != nil {
		return nil, err
	}
	want := map[string]bool{}
	if len(opts.Only) == 0 {
		for _, s := range man.Services {
			want[s] = true
		}
	} else {
		for _, s := range opts.Only {
			want[s] = true
		}
	}
	warn := func(format string, args ...any) {
		if opts.Warn != nil {
			opts.Warn(fmt.Sprintf(format, args...))
		}
	}

	// contained joins root and rest, and refuses anything that escapes root.
	//
	// Entry names come verbatim from the archive, and an archive is not necessarily one we
	// produced — a support bundle, a shared team backup, a file off a NAS. filepath.Join
	// CLEANS the result, so "core/../../../.ssh/authorized_keys" silently resolves to a path
	// outside the data directory rather than being rejected. That mattered more than usual
	// here because setAside RENAMES whatever already exists at the destination before the
	// archive content is written, so a traversal displaces the victim's file as well as
	// planting ours.
	contained := func(root, rest string) (string, bool) {
		if rest == "" || filepath.IsAbs(rest) || strings.HasPrefix(rest, "/") {
			return "", false
		}
		p := filepath.Join(root, rest)
		// Compare against root + separator so "/data/core-evil" cannot pass as inside "/data/core".
		if p != root && !strings.HasPrefix(p, root+string(os.PathSeparator)) {
			return "", false
		}
		return p, true
	}

	serviceRoot := func(service string) string {
		switch service {
		case "gateway":
			return e.GatewayDir
		case "engine":
			return e.EngineDir
		case "copilot":
			return e.CopilotDir
		case "core":
			return e.CoreDir
		case "config":
			return e.Home
		}
		return ""
	}

	dest := func(arcPath string) (string, bool) {
		service, rest, ok := strings.Cut(arcPath, "/")
		if !ok || !want[service] {
			return "", false
		}
		if service == "core" && underBackupDir(rest) {
			return "", false // Core's backup area is never restored
		}
		root := serviceRoot(service)
		if root == "" {
			return "", false
		}
		return contained(root, rest)
	}

	// Who restored files belong to. Only root can give a file away; anyone
	// else writes files they own, which is right when they ARE the service
	// user and is reported when they are not.
	asRoot := os.Geteuid() == 0
	serviceOwner := func(service string) *FileOwner {
		if service == "config" {
			return nil // per file: the owner of the file it replaces
		}
		if e.Owner != nil {
			return e.Owner
		}
		if uid, gid := ownerOf(serviceRoot(service)); uid >= 0 {
			return &FileOwner{uid, gid}
		}
		return nil
	}
	owners := map[string]*FileOwner{}
	for _, s := range []string{"core", "gateway", "engine", "copilot"} {
		owners[s] = serviceOwner(s) // before anything is set aside
	}
	warnedOwner := map[string]bool{}
	chown := func(service, p string, o *FileOwner) {
		if o == nil {
			return
		}
		if asRoot {
			if err := os.Lchown(p, o.UID, o.GID); err != nil {
				warn("could not give %s to %d:%d: %v", p, o.UID, o.GID, err)
			}
			return
		}
		if o.UID != os.Geteuid() && !warnedOwner[service] {
			warnedOwner[service] = true
			warn("%s's restored files belong to you (uid %d), not to the user the service runs as (%d:%d); "+
				"run fp restore with sudo, or: sudo chown -R %d:%d %s",
				service, os.Geteuid(), o.UID, o.GID, o.UID, o.GID, serviceRoot(service))
		}
	}

	stamp := time.Now().Format("20060102-150405")
	asides := []string{}
	asided := map[string]bool{} // top-level paths already set aside this run
	touchedDirs := map[string]bool{}
	syncRoots := map[string]bool{} // the service directories written into

	// recreate makes a set-aside directory again, as it was: its mode and
	// its owner.
	recreate := func(service, dir string, mode os.FileMode, o *FileOwner) error {
		if err := os.MkdirAll(dir, mode.Perm()); err != nil {
			return err
		}
		_ = os.Chmod(dir, mode.Perm())
		chown(service, dir, o)
		touchedDirs[dir] = true
		touchedDirs[filepath.Dir(dir)] = true
		return nil
	}

	setAside := func(service, p string) error {
		if asided[p] {
			return nil
		}
		asided[p] = true
		st, err := os.Lstat(p)
		if err != nil {
			return nil // nothing there to keep
		}
		owner := owners[service]
		if service == "config" || owner == nil {
			if uid, gid := ownerOf(p); uid >= 0 {
				owner = &FileOwner{uid, gid}
			}
		}
		if st.IsDir() && isMountPoint(p) {
			// A mount point (a dedicated data volume) cannot be renamed aside.
			// Its CONTENTS go aside, into a directory on the same volume.
			aside := filepath.Join(p, ".pre-restore-"+stamp)
			if err := os.Mkdir(aside, 0o700); err != nil {
				return err
			}
			entries, err := os.ReadDir(p)
			if err != nil {
				return err
			}
			for _, en := range entries {
				name := en.Name()
				if name == "lost+found" || strings.HasPrefix(name, ".pre-restore-") {
					continue // the volume's own, or an earlier restore's aside
				}
				if err := os.Rename(filepath.Join(p, name), filepath.Join(aside, name)); err != nil {
					return err
				}
			}
			_ = syncDir(aside)
			touchedDirs[p] = true
			asides = append(asides, aside)
			return nil
		}
		aside := p + ".pre-restore-" + stamp
		if err := os.Rename(p, aside); err != nil {
			return err
		}
		// A restored SQLite file must not inherit the OLD WAL/SHM: stale
		// siblings would replay obsolete frames over the restored data.
		for _, ext := range []string{"-wal", "-shm"} {
			if pathExists(p + ext) {
				_ = os.Rename(p+ext, aside+ext)
			}
		}
		touchedDirs[filepath.Dir(p)] = true
		asides = append(asides, aside)
		if st.IsDir() {
			return recreate(service, p, st.Mode(), owner)
		}
		return nil
	}

	// mkdirs makes the missing directories between top and dir, each given to
	// the service's user.
	mkdirs := func(service, top, dir string, o *FileOwner) error {
		if _, err := os.Lstat(top); err != nil {
			if err := os.MkdirAll(top, 0o755); err != nil {
				return err
			}
			chown(service, top, o)
			touchedDirs[top] = true
			touchedDirs[filepath.Dir(top)] = true
		}
		if dir == top {
			return nil
		}
		if !strings.HasPrefix(dir, top+string(os.PathSeparator)) {
			return os.MkdirAll(dir, 0o755)
		}
		rel, _ := filepath.Rel(top, dir)
		cur := top
		for _, part := range strings.Split(rel, string(os.PathSeparator)) {
			cur = filepath.Join(cur, part)
			if _, err := os.Lstat(cur); err == nil {
				continue
			}
			if err := os.Mkdir(cur, 0o755); err != nil && !os.IsExist(err) {
				return err
			}
			chown(service, cur, o)
			touchedDirs[filepath.Dir(cur)] = true
			touchedDirs[cur] = true
		}
		return nil
	}

	f, err := os.Open(archive)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return nil, err
	}
	tr := tar.NewReader(gz)

	// Directory trees (core/, engine/agentspecs/…) are set aside WHOLE at
	// their top level on first touch, then rebuilt file by file. core is
	// ALWAYS one tree — even its root-level files (fp_database.hdr) belong
	// to the tree aside, or the second core entry would sweep the first
	// restored file into the aside with the old data.
	topOf := func(hostPath, arcPath string) string {
		service, rest, _ := strings.Cut(arcPath, "/")
		if service == "core" {
			return e.CoreDir
		}
		parts := strings.SplitN(rest, "/", 2)
		if service == "engine" && len(parts) == 2 && parts[0] != "db" {
			return filepath.Join(e.EngineDir, parts[0]) // agentspecs, models, …
		}
		return hostPath // plain files (DBs, config files) aside individually
	}

	for {
		if err := ctx.Err(); err != nil {
			return asides, err
		}
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return asides, err
		}
		if hdr.Name == "manifest.json" || hdr.Typeflag == tar.TypeDir {
			continue
		}
		hostPath, ok := dest(hdr.Name)
		if !ok {
			continue
		}
		service, _, _ := strings.Cut(hdr.Name, "/")
		top := topOf(hostPath, hdr.Name)

		// A replaced configuration file keeps its owner and mode (.env is
		// 0640 falconpulsar:docker on Linux, 0600 on macOS).
		var keepMode os.FileMode
		owner := owners[service]
		if service == "config" {
			if st, err := os.Lstat(hostPath); err == nil {
				keepMode = st.Mode().Perm()
				if uid, gid := ownerOf(hostPath); uid >= 0 {
					owner = &FileOwner{uid, gid}
				}
			} else if uid, gid := ownerOf(e.Home); uid >= 0 {
				owner = &FileOwner{uid, gid}
			}
		}

		if err := setAside(service, top); err != nil {
			return asides, err
		}
		root := serviceRoot(service)
		if err := mkdirs(service, root, filepath.Dir(hostPath), owner); err != nil {
			return asides, err
		}
		mode := os.FileMode(hdr.Mode).Perm()
		if service != "config" {
			mode |= 0o600 // the service must be able to read and write its own files
		} else if keepMode != 0 {
			mode = keepMode
		}
		out, err := os.OpenFile(hostPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
		if err != nil {
			return asides, err
		}
		if _, err := io.Copy(out, tr); err != nil {
			out.Close()
			return asides, err
		}
		if syncEachFile {
			if err := out.Sync(); err != nil {
				out.Close()
				return asides, err
			}
		}
		if err := out.Close(); err != nil {
			return asides, err
		}
		_ = os.Chmod(hostPath, mode) // the umask narrowed it at create
		chown(service, hostPath, owner)
		touchedDirs[filepath.Dir(hostPath)] = true
		syncRoots[root] = true
	}

	// Durable before the caller starts the services: every restored file,
	// and every name in every directory it went into or was set aside from.
	if !syncEachFile {
		for root := range syncRoots {
			if err := syncFilesystem(root); err != nil {
				return asides, fmt.Errorf("sync %s: %w", root, err)
			}
		}
	}
	dirs := make([]string, 0, len(touchedDirs))
	for d := range touchedDirs {
		dirs = append(dirs, d)
	}
	sort.Strings(dirs)
	for _, d := range dirs {
		if err := syncDir(d); err != nil && !os.IsNotExist(err) {
			return asides, fmt.Errorf("sync %s: %w", d, err)
		}
	}
	sort.Strings(asides)
	return asides, nil
}

// ── small helpers ──────────────────────────────────────────────────────

func realDockerExec(ctx context.Context, container string, argv []string) error {
	args := append([]string{"exec", container}, argv...)
	cmd := exec.CommandContext(ctx, "docker", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker exec %s: %v — %s", container, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func realContainerRunning(ctx context.Context, container string) bool {
	cmd := exec.CommandContext(ctx, "docker", "inspect", "-f", "{{.State.Running}}", container)
	out, err := cmd.Output()
	return err == nil && strings.TrimSpace(string(out)) == "true"
}

func fileExists(p string) bool { st, err := os.Stat(p); return err == nil && !st.IsDir() }
func dirExists(p string) bool  { st, err := os.Stat(p); return err == nil && st.IsDir() }
func pathExists(p string) bool { _, err := os.Stat(p); return err == nil }

func addFile(tw *tar.Writer, hostPath, arcPath string) error {
	st, err := os.Stat(hostPath)
	if err != nil {
		return err
	}
	f, err := os.Open(hostPath)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := tw.WriteHeader(&tar.Header{
		Name: arcPath, Mode: int64(st.Mode() & 0o777), Size: st.Size(),
		ModTime: st.ModTime(),
	}); err != nil {
		return err
	}
	_, err = io.Copy(tw, f)
	return err
}

func addTree(tw *tar.Writer, root, prefix string, skip func(string) bool) error {
	return filepath.Walk(root, func(p string, st os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if skip != nil && skip(p) {
			if st.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if st.IsDir() || !st.Mode().IsRegular() {
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		return addFile(tw, p, prefix+"/"+filepath.ToSlash(rel))
	})
}
