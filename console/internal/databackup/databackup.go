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
//	engine/{agentspecs,workorders,outbox,replay,models}/…
//	copilot/command-center.db
//	core/…                           TimeSeries Core's whole data directory
//
// CONSISTENCY. Every SQLite file is snapshotted with VACUUM INTO executed
// INSIDE its owning container (phase-4 discipline: one writer per file, and
// that writer makes the copy), which yields a point-in-time, WAL-free,
// defragmented database regardless of live traffic. A stopped container's
// files are copied cold (db + -wal + -shm), which is equally consistent.
// Core has its own write-ahead log (wal/*.fpw): its directory is copied
// live, which is CRASH-consistent — on restore Core replays its WAL exactly
// as it would after a power cut. The manifest records which semantics each
// entry got.
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
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
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
	Semantics  map[string]string `json:"semantics"` // service -> point-in-time | crash-consistent | cold-copy
	SkipedCore bool              `json:"skipped_core,omitempty"`
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
	// DockerExec runs `docker exec <container> <argv…>`; nil = real docker.
	DockerExec func(ctx context.Context, container string, argv []string) error
	// ContainerRunning reports whether the named container is up; nil = real docker.
	ContainerRunning func(ctx context.Context, container string) bool
}

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
				"confirm_ids.db", "watches.db", "knowledge.db",
			},
			runner: func(cd, s, d string) []string { return pyVacuum("/app/data", s, d) },
		},
		{
			name: "engine", container: "falconpulsar-ai-engine", hostDir: e.EngineDir,
			dbs:    []string{"db/fp-agentics.db"},
			extras: []string{"agentspecs", "workorders", "outbox", "replay", "models", "config"},
			runner: func(cd, s, d string) []string { return nodeVacuum("/data", s, d) },
		},
		{
			name: "copilot", container: "falconpulsar-copilot", hostDir: e.CopilotDir,
			dbs:    []string{"command-center.db"},
			runner: func(cd, s, d string) []string { return nodeVacuum("/data", s, d) },
		},
	}
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
	return Env{
		Home:       home,
		CoreDir:    coreDir,
		GatewayDir: orDefault("FP_GATEWAY_DATA_DIR", filepath.Join(base, "ai-gateway-data")),
		EngineDir:  orDefault("FP_ENGINE_DATA_DIR", filepath.Join(base, "ai-engine-data")),
		CopilotDir: orDefault("FP_COPILOT_DATA_DIR", filepath.Join(base, "copilot-data")),
		FPVersion:  vals["FP_VERSION"],
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

// Options for Backup.
type BackupOptions struct {
	SkipCore bool
}

// Backup writes a .tar.gz at outPath and returns its manifest.
func Backup(ctx context.Context, e Env, outPath string, opts BackupOptions) (Manifest, error) {
	if e.DockerExec == nil {
		e.DockerExec = realDockerExec
	}
	if e.ContainerRunning == nil {
		e.ContainerRunning = realContainerRunning
	}

	man := Manifest{
		Kind: manifestKind, Version: manifestVersion,
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
		FPVersion: e.FPVersion, Semantics: map[string]string{},
		SkipedCore: opts.SkipCore,
	}
	if h, err := os.Hostname(); err == nil {
		man.Host = h
	}

	out, err := os.Create(outPath)
	if err != nil {
		return man, err
	}
	defer out.Close()
	gz := gzip.NewWriter(out)
	defer gz.Close()
	tw := tar.NewWriter(gz)
	defer tw.Close()

	// The manifest is finalized before any data is walked so its byte size
	// is known up front — services list first.
	for _, t := range targets(e) {
		if dirExists(t.hostDir) {
			man.Services = append(man.Services, t.name)
		}
	}
	if !opts.SkipCore && dirExists(e.CoreDir) {
		man.Services = append(man.Services, "core")
		man.Semantics["core"] = "crash-consistent (Core replays its own WAL on restore)"
	}
	man.Services = append(man.Services, "config")

	for _, t := range targets(e) {
		if !dirExists(t.hostDir) {
			continue
		}
		sem, err := backupTarget(ctx, e, tw, t)
		if err != nil {
			return man, fmt.Errorf("%s: %w", t.name, err)
		}
		man.Semantics[t.name] = sem
	}

	if !opts.SkipCore && dirExists(e.CoreDir) {
		if err := addTree(tw, e.CoreDir, "core", func(p string) bool {
			return filepath.Base(p) == ".DS_Store"
		}); err != nil {
			return man, fmt.Errorf("core: %w", err)
		}
	}

	for _, f := range []string{"compose.yml", ".env", "gateway.yaml"} {
		p := filepath.Join(e.Home, f)
		if fileExists(p) {
			if err := addFile(tw, p, "config/"+f); err != nil {
				return man, fmt.Errorf("config/%s: %w", f, err)
			}
		}
	}

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
	return semantics, nil
}

// Options for Restore.
type RestoreOptions struct {
	// Only restricts restoration to these service names (empty = all in archive).
	Only []string
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

// Restore places an archive's contents back onto the stack directories.
// The caller is responsible for stopping the affected services first and
// starting them after — the CLI layer owns that choreography (and the
// confirmation). Everything replaced is set aside, never deleted.
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

	dest := func(arcPath string) (string, bool) {
		service, rest, ok := strings.Cut(arcPath, "/")
		if !ok || !want[service] {
			return "", false
		}
		switch service {
		case "gateway":
			return contained(e.GatewayDir, rest)
		case "engine":
			return contained(e.EngineDir, rest)
		case "copilot":
			return contained(e.CopilotDir, rest)
		case "core":
			return contained(e.CoreDir, rest)
		case "config":
			return contained(e.Home, rest)
		}
		return "", false
	}

	stamp := time.Now().Format("20060102-150405")
	asides := []string{}
	asided := map[string]bool{} // top-level paths already set aside this run

	setAside := func(p string) error {
		if asided[p] || !pathExists(p) {
			asided[p] = true
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
		asides = append(asides, aside)
		asided[p] = true
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
		if err := setAside(topOf(hostPath, hdr.Name)); err != nil {
			return asides, err
		}
		if err := os.MkdirAll(filepath.Dir(hostPath), 0o755); err != nil {
			return asides, err
		}
		out, err := os.OpenFile(hostPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, os.FileMode(hdr.Mode)&0o777)
		if err != nil {
			return asides, err
		}
		if _, err := io.Copy(out, tr); err != nil {
			out.Close()
			return asides, err
		}
		out.Close()
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
