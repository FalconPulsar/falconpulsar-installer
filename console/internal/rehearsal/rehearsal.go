// SPDX-License-Identifier: AGPL-3.0-only
// Package rehearsal validates native data backups and restores them in isolation.
package rehearsal

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/databackup"
)

const maxManifestBytes = 1 << 20
const maxEntries = 1000000

type File struct {
	Path      string `json:"path"`
	SizeBytes int64  `json:"size_bytes"`
	SHA256    string `json:"sha256"`
}

type Report struct {
	SchemaVersion               int                 `json:"schema_version"`
	Operation                   string              `json:"operation"`
	Status                      string              `json:"status"`
	Archive                     string              `json:"archive"`
	ArchiveSHA256               string              `json:"archive_sha256"`
	ArchiveBytes                int64               `json:"archive_bytes"`
	Manifest                    databackup.Manifest `json:"manifest"`
	FileCount                   int                 `json:"file_count"`
	TotalBytes                  int64               `json:"total_bytes"`
	Files                       []File              `json:"files"`
	CoreCleanCheckpointVerified bool                `json:"core_clean_checkpoint_verified"`
	Destination                 string              `json:"destination,omitempty"`
	Paths                       map[string]string   `json:"paths,omitempty"`
}

func service(name string) bool {
	switch name {
	case "core", "gateway", "engine", "copilot", "config":
		return true
	}
	return false
}

func entryName(h *tar.Header) (string, error) {
	name := h.Name
	if h.Typeflag == tar.TypeDir {
		name = strings.TrimSuffix(name, "/")
	}
	if name == "" || len(name) > 4096 || path.IsAbs(name) || strings.ContainsAny(name, "\\:\x00") || path.Clean(name) != name {
		return "", fmt.Errorf("unsafe archive path %q", h.Name)
	}
	for _, part := range strings.Split(name, "/") {
		if part == ".." || part == "." || part == "" {
			return "", fmt.Errorf("unsafe archive path %q", h.Name)
		}
	}
	if name != "manifest.json" {
		prefix, _, hasRest := strings.Cut(name, "/")
		if !service(prefix) || (!hasRest && h.Typeflag != tar.TypeDir) {
			return "", fmt.Errorf("unrecognized archive entry %q", h.Name)
		}
	}
	return name, nil
}

// Inspect reads the complete gzip stream, verifies framing and checksums, and
// rejects entries that native Restore must never see. FileCount excludes the manifest.
func Inspect(archive string) (Report, error) {
	abs, err := filepath.Abs(archive)
	if err != nil {
		return Report{}, err
	}
	r := Report{SchemaVersion: 1, Operation: "inspect", Archive: abs, Files: []File{}}
	f, err := os.Open(abs)
	if err != nil {
		return r, err
	}
	defer f.Close()
	before, err := f.Stat()
	if err != nil {
		return r, err
	}
	if !before.Mode().IsRegular() {
		return r, fmt.Errorf("archive must be a regular file")
	}
	hash := sha256.New()
	compressed := bufio.NewReader(io.TeeReader(f, hash))
	gz, err := gzip.NewReader(compressed)
	if err != nil {
		return r, err
	}
	defer gz.Close()
	gz.Multistream(false)
	tr := tar.NewReader(gz)
	entries := map[string]byte{}
	parents := map[string]bool{}
	var foundManifest bool
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return r, fmt.Errorf("archive tar: %w", err)
		}
		if h.Typeflag != tar.TypeReg && h.Typeflag != tar.TypeRegA && h.Typeflag != tar.TypeDir {
			return r, fmt.Errorf("unsupported archive entry type for %q", h.Name)
		}
		name, err := entryName(h)
		if err != nil {
			return r, err
		}
		if _, ok := entries[name]; ok {
			return r, fmt.Errorf("duplicate archive entry %q", name)
		}
		if len(entries) >= maxEntries {
			return r, fmt.Errorf("too many archive entries")
		}
		if h.Typeflag != tar.TypeDir && parents[name] {
			return r, fmt.Errorf("file conflicts with directory %q", name)
		}
		for parent := path.Dir(name); parent != "."; parent = path.Dir(parent) {
			if typ, ok := entries[parent]; ok && typ != tar.TypeDir {
				return r, fmt.Errorf("file used as directory %q", parent)
			}
			parents[parent] = true
		}
		entries[name] = h.Typeflag
		if h.Size < 0 || (h.Typeflag == tar.TypeDir && h.Size != 0) {
			return r, fmt.Errorf("invalid entry size for %q", name)
		}
		if h.Typeflag == tar.TypeDir {
			continue
		}
		if name == "manifest.json" {
			if h.Size > maxManifestBytes {
				return r, fmt.Errorf("manifest exceeds %d bytes", maxManifestBytes)
			}
			data, err := io.ReadAll(tr)
			if err != nil {
				return r, err
			}
			if err := json.Unmarshal(data, &r.Manifest); err != nil {
				return r, fmt.Errorf("manifest: %w", err)
			}
			foundManifest = true
			continue
		}
		hashFile := sha256.New()
		n, err := io.Copy(hashFile, tr)
		if err != nil {
			return r, fmt.Errorf("entry %s: %w", name, err)
		}
		if n != h.Size || n > math.MaxInt64-r.TotalBytes {
			return r, fmt.Errorf("invalid total size")
		}
		r.Files = append(r.Files, File{name, n, hex.EncodeToString(hashFile.Sum(nil))})
		r.TotalBytes += n
	}
	// tar EOF is not gzip EOF. Drain to force CRC/trailer validation and permit
	// only conventional zero padding after the tar terminator.
	padding, err := io.ReadAll(io.LimitReader(gz, maxManifestBytes+1))
	if err != nil {
		return r, fmt.Errorf("gzip footer: %w", err)
	}
	if len(padding) > maxManifestBytes {
		return r, fmt.Errorf("excessive tar padding")
	}
	for _, b := range padding {
		if b != 0 {
			return r, fmt.Errorf("data after tar terminator")
		}
	}
	if _, err := compressed.ReadByte(); err != io.EOF {
		if err == nil {
			return r, fmt.Errorf("data after gzip stream")
		}
		return r, err
	}
	if !foundManifest || r.Manifest.Kind != "falconpulsar-data-backup" || r.Manifest.Version != 1 {
		return r, fmt.Errorf("unsupported or missing native backup manifest")
	}
	listed := map[string]bool{}
	for _, s := range r.Manifest.Services {
		if !service(s) || listed[s] {
			return r, fmt.Errorf("invalid manifest service %q", s)
		}
		listed[s] = true
	}
	if len(listed) == 0 || (r.Manifest.SkipedCore && listed["core"]) {
		return r, fmt.Errorf("inconsistent manifest services")
	}
	for _, file := range r.Files {
		prefix, _, _ := strings.Cut(file.Path, "/")
		if !listed[prefix] {
			return r, fmt.Errorf("entry %q absent from manifest services", file.Path)
		}
	}
	after, err := os.Stat(abs)
	if err != nil || !os.SameFile(before, after) || before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return r, fmt.Errorf("archive changed during inspection")
	}
	// Keep native manifest handling in the path as well as strict validation.
	native, err := databackup.Peek(abs)
	if err != nil {
		return r, err
	}
	if !reflect.DeepEqual(native, r.Manifest) {
		return r, fmt.Errorf("manifest changed during inspection")
	}
	after, err = os.Stat(abs)
	if err != nil || !os.SameFile(before, after) || before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return r, fmt.Errorf("archive changed during native manifest inspection")
	}
	r.ArchiveSHA256 = hex.EncodeToString(hash.Sum(nil))
	r.ArchiveBytes = before.Size()
	r.FileCount = len(r.Files)
	r.Status = "validated"
	return r, nil
}

// Restore validates a private copy before exclusively creating the destination.
// It invokes only native data restore, never service actions or Docker commands.
func Restore(ctx context.Context, archive, destination string) (report Report, err error) {
	dest, err := filepath.Abs(destination)
	if err != nil {
		return report, err
	}
	if _, e := os.Lstat(dest); !os.IsNotExist(e) {
		return report, fmt.Errorf("destination must not exist")
	}
	stage, err := os.MkdirTemp(filepath.Dir(dest), ".fp-rehearse-")
	if err != nil {
		return report, err
	}
	defer os.RemoveAll(stage)
	snapshot := filepath.Join(stage, "archive.tar.gz")
	input, err := os.Open(archive)
	if err != nil {
		return report, err
	}
	before, err := input.Stat()
	if err != nil {
		input.Close()
		return report, err
	}
	if !before.Mode().IsRegular() {
		input.Close()
		return report, fmt.Errorf("archive must be a regular file")
	}
	copy, err := os.OpenFile(snapshot, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		input.Close()
		return report, err
	}
	_, copyErr := io.Copy(copy, input)
	closeErr := copy.Close()
	after, statErr := input.Stat()
	input.Close()
	if copyErr != nil {
		return report, copyErr
	}
	if closeErr != nil {
		return report, closeErr
	}
	if statErr != nil || before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return report, fmt.Errorf("archive changed while copying")
	}
	named, statErr := os.Stat(archive)
	if statErr != nil || !os.SameFile(before, named) || before.Size() != named.Size() || !before.ModTime().Equal(named.ModTime()) {
		return report, fmt.Errorf("archive replaced while copying")
	}
	if err = os.Chmod(snapshot, 0o400); err != nil {
		return report, err
	}
	report, err = Inspect(snapshot)
	if err != nil {
		return Report{}, err
	}
	report.Archive, err = filepath.Abs(archive)
	if err != nil {
		return Report{}, err
	}
	// Mkdir is exclusive; unlike a plain rename it cannot replace a directory
	// created by someone else while validation was in progress.
	if err = os.Mkdir(dest, 0o700); err != nil {
		return Report{}, err
	}
	defer func() {
		if err != nil {
			os.RemoveAll(dest)
			report = Report{}
		}
	}()
	env := databackup.Env{Home: filepath.Join(dest, "captured-config"), CoreDir: filepath.Join(dest, "core"), GatewayDir: filepath.Join(dest, "gateway"), EngineDir: filepath.Join(dest, "engine"), CopilotDir: filepath.Join(dest, "copilot")}
	_, err = databackup.Restore(ctx, env, snapshot, databackup.RestoreOptions{})
	if err != nil {
		return Report{}, err
	}
	report.Operation, report.Status = "restore", "restored"
	report.Destination = dest
	report.Paths = map[string]string{"core": env.CoreDir, "gateway": env.GatewayDir, "engine": env.EngineDir, "copilot": env.CopilotDir, "captured_config": env.Home}
	return report, nil
}
