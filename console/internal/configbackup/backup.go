// Package configbackup implements the .fpconfig file format — the cross-platform
// FalconPulsar configuration backup. File format (binary) is identical to the
// macOS Swift and Windows C# implementations. See ConfigBackup.swift /
// ConfigBackup.cs in the repo for the authoritative spec.
//
//	[0..3]   Magic = "FPCF"        (4 bytes)
//	[4]      Format version       (1 byte; current: 2, accepts: 1, 2)
//	[5..20]  PBKDF2 salt           (16 bytes)
//	[21..32] AES-GCM nonce         (12 bytes)
//	[33..]   AES-256-GCM ciphertext of the zip payload
//	[tail 16 bytes] GCM tag
//
// Key = PBKDF2-HMAC-SHA256("<user>:<pass>", salt, 100_000, 32)
//
// Payload zip layout:
//
//	manifest.json                ← format_version + fp_version + timestamp + host + platform
//	files/compose.yml            ← docker compose for the FalconPulsar stack
//	files/.env                   ← env vars (may contain secrets)
//	files/gateway.yaml           ← AI Gateway config seed
//	api/roles.json               ← GET /api/v1/roles
//	api/users.json               ← GET /api/v1/users
//	api/asset-types.json         ← GET /api/v1/asset-types       (NEW in v2)
//	api/assets.json              ← GET /api/v1/assets
//	api/datasources.json         ← GET /api/v1/datasources
//	api/series.json              ← GET /api/v1/series?include_engineering=true&limit=100000   (NEW in v2)
//	api/mappings.json            ← GET /api/v1/mappings
//	api/relationships.json       ← GET /api/v1/relationships    (NEW in v2)
//	api/annotations.json         ← GET /api/v1/annotations      (NEW in v2)
//
// Format version compatibility:
//
//	v1: 5 sections (users, roles, datasources, mappings, assets). Import still works.
//	v2: adds asset-types, series, relationships, annotations. Imports of v1 files
//	    succeed (the missing sections are skipped silently). Imports of v2 files
//	    on older clients that only know v1 are rejected at the magic-byte check
//	    by the version byte mismatch.
package configbackup

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
	"golang.org/x/crypto/pbkdf2"
)

const (
	// FormatVersion is the version this build *writes*. Older versions are
	// still accepted on import (see decrypt() validation).
	FormatVersion = 2

	// MinReadableFormatVersion is the oldest format we can still decrypt
	// and parse.
	MinReadableFormatVersion = 1

	SaltLen    = 16
	NonceLen   = 12
	TagLen     = 16
	Iterations = 100_000
	KeyLen     = 32
)

var Magic = []byte{0x46, 0x50, 0x43, 0x46} // "FPCF"

// ImportSummary reports the per-section outcome of an Import operation.
//
// `Created` counts items that were applied successfully (HTTP 2xx).
// `Skipped` counts items the server rejected with 409 Conflict — these are
// typically already-present items that the import did not overwrite. They
// are not errors in the disaster-recovery sense.
// `Errors` counts items the server rejected with any other 4xx/5xx and any
// network failures. `ErrorDetails` carries the first few error messages
// from those failures for surfacing to the user.
type ImportSummary struct {
	Sections     map[string]SectionStats `json:"sections"`
	TotalCreated int                     `json:"total_created"`
	TotalSkipped int                     `json:"total_skipped"`
	TotalErrors  int                     `json:"total_errors"`
}

// SectionStats describes the outcome of importing one section of the backup.
type SectionStats struct {
	Created      int      `json:"created"`
	Skipped      int      `json:"skipped"`        // 409 Conflict
	Errors       int      `json:"errors"`         // other failures
	ErrorDetails []string `json:"error_details"`  // first 5 error messages
}

func (s ImportSummary) HumanReadable() string {
	if len(s.Sections) == 0 {
		return "Import: nothing applied."
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Import complete: %d created, %d skipped (already existed), %d errors.\n",
		s.TotalCreated, s.TotalSkipped, s.TotalErrors)
	for _, name := range []string{
		"roles", "users", "asset-types", "assets",
		"datasources", "series", "mappings", "relationships", "annotations",
	} {
		st, ok := s.Sections[name]
		if !ok {
			continue
		}
		fmt.Fprintf(&b, "  • %-13s  created=%d  skipped=%d  errors=%d\n",
			name, st.Created, st.Skipped, st.Errors)
		for _, msg := range st.ErrorDetails {
			fmt.Fprintf(&b, "      ! %s\n", msg)
		}
	}
	return b.String()
}

func deriveKey(user, pass string, salt []byte) []byte {
	return pbkdf2.Key([]byte(user+":"+pass), salt, Iterations, KeyLen, sha256.New)
}

func encrypt(plain []byte, user, pass string) ([]byte, error) {
	salt := make([]byte, SaltLen)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	nonce := make([]byte, NonceLen)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(deriveKey(user, pass, salt))
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	ct := gcm.Seal(nil, nonce, plain, nil)
	var out bytes.Buffer
	out.Write(Magic)
	out.WriteByte(FormatVersion)
	out.Write(salt)
	out.Write(nonce)
	out.Write(ct)
	return out.Bytes(), nil
}

func decrypt(data []byte, user, pass string) ([]byte, error) {
	head := 4 + 1 + SaltLen + NonceLen
	if len(data) < head+TagLen {
		return nil, errors.New("file too short")
	}
	if !bytes.Equal(data[:4], Magic) {
		return nil, errors.New("not a FalconPulsar backup file (magic mismatch)")
	}
	// Accept any format version we know how to read. The version byte is
	// authenticated by the GCM tag, so a tampered value would fail decryption
	// later. We just need to reject versions we have no code for.
	if v := data[4]; v < MinReadableFormatVersion || v > FormatVersion {
		return nil, fmt.Errorf("unsupported backup format version %d (this client supports v%d–v%d)",
			v, MinReadableFormatVersion, FormatVersion)
	}
	salt := data[5 : 5+SaltLen]
	nonce := data[5+SaltLen : head]
	ct := data[head:]

	block, err := aes.NewCipher(deriveKey(user, pass, salt))
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return nil, fmt.Errorf("decryption failed — wrong admin credentials or corrupted file")
	}
	return plain, nil
}

// HomeDir resolves the FalconPulsar stack directory (~/falconpulsar).
func HomeDir() string {
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, "falconpulsar")
	}
	return "/root/falconpulsar"
}

// Export reads config + API data, zips, encrypts, writes to output.
func Export(ctx context.Context, output string, cli *api.Client, user, pass string) error {
	var zipBuf bytes.Buffer
	zw := zip.NewWriter(&zipBuf)
	home := HomeDir()

	// manifest.json
	manifest := map[string]any{
		"format_version":       FormatVersion,
		"falconpulsar_version": "0.1.3",
		"exported_at":          time.Now().UTC().Format(time.RFC3339),
		"source_host":          hostname(),
		"source_platform":      runtime.GOOS,
	}
	mb, _ := json.MarshalIndent(manifest, "", "  ")
	if err := writeZipFile(zw, "manifest.json", mb); err != nil {
		return err
	}

	// config files
	for _, name := range []string{"compose.yml", ".env", "gateway.yaml"} {
		p := filepath.Join(home, name)
		if data, err := os.ReadFile(p); err == nil {
			if err := writeZipFile(zw, "files/"+name, data); err != nil {
				return err
			}
		}
	}

	// API endpoints harvested as JSON files inside the zip. Order doesn't
	// matter here (we only read; ordering is handled at import time to
	// satisfy parent/child dependencies). For series we ask the server to
	// include engineering limits + alarm thresholds inline, and we bump
	// limit way up since the default is small (paginated).
	for _, ep := range []struct{ name, path string }{
		{"roles.json", "/api/v1/roles"},
		{"users.json", "/api/v1/users"},
		{"asset-types.json", "/api/v1/asset-types"},
		{"assets.json", "/api/v1/assets"},
		{"datasources.json", "/api/v1/datasources"},
		{"series.json", "/api/v1/series?include_engineering=true&limit=100000"},
		{"mappings.json", "/api/v1/mappings"},
		{"relationships.json", "/api/v1/relationships"},
		{"annotations.json", "/api/v1/annotations?limit=100000"},
	} {
		if data, err := cli.GetRaw(ctx, ep.path); err == nil {
			// File name in the archive uses the section name (no query string).
			fileName := ep.name
			_ = writeZipFile(zw, "api/"+fileName, data)
		}
	}

	if err := zw.Close(); err != nil {
		return err
	}
	ct, err := encrypt(zipBuf.Bytes(), user, pass)
	if err != nil {
		return err
	}
	return os.WriteFile(output, ct, 0600)
}

// Import decrypts, unzips, and pushes config back to Core.
//
// Returns a non-nil ImportSummary even on partial failure — callers should
// always check the summary to know what was actually applied. A non-nil
// error indicates a fatal pre-flight failure (file unreadable, bad creds,
// invalid archive) that aborted the import before any section ran.
func Import(ctx context.Context, input string, cli *api.Client, user, pass string) (ImportSummary, error) {
	summary := ImportSummary{Sections: map[string]SectionStats{}}

	enc, err := os.ReadFile(input)
	if err != nil {
		return summary, err
	}
	plain, err := decrypt(enc, user, pass)
	if err != nil {
		return summary, err
	}
	zr, err := zip.NewReader(bytes.NewReader(plain), int64(len(plain)))
	if err != nil {
		return summary, fmt.Errorf("invalid archive inside backup: %w", err)
	}
	home := HomeDir()
	_ = os.MkdirAll(home, 0755)

	// Index zip entries by path for easy lookup
	entries := map[string]*zip.File{}
	for _, f := range zr.File {
		entries[f.Name] = f
	}

	// Restore config files (compose.yml, .env, gateway.yaml). These aren't
	// API-driven so failures don't go in the summary; we propagate them as
	// hard errors because they block the stack from running.
	for _, name := range []string{"compose.yml", ".env", "gateway.yaml"} {
		if f, ok := entries["files/"+name]; ok {
			if err := extractTo(f, filepath.Join(home, name)); err != nil {
				return summary, err
			}
		}
	}

	// Push API data in dependency order. Each section is applied with
	// per-item retry/skip handling so one bad record doesn't abort the
	// rest. The first 5 error messages per section are retained so the
	// caller can show them in the UI.
	//
	// Dependency order rationale:
	//   roles        — no foreign keys
	//   asset-types  — no foreign keys
	//   users        — references role_id
	//   datasources  — no foreign keys
	//   assets       — references asset_type_id, parent_id
	//   series       — references asset_id
	//   mappings     — references datasource_id + series_id (must come after both)
	//   relationships— references source_asset_id + target_asset_id
	//   annotations  — references series_id
	//
	// Note on v1 backups: missing sections (asset-types, series, relationships,
	// annotations) are silently skipped. The loop just no-ops when the zip
	// entry isn't present.
	for _, ep := range []struct {
		section, file, path string
	}{
		{"roles", "roles.json", "/api/v1/roles"},
		{"asset-types", "asset-types.json", "/api/v1/asset-types"},
		{"users", "users.json", "/api/v1/users"},
		{"datasources", "datasources.json", "/api/v1/datasources"},
		{"assets", "assets.json", "/api/v1/assets"},
		{"series", "series.json", "/api/v1/series"},
		{"mappings", "mappings.json", "/api/v1/mappings"},
		{"relationships", "relationships.json", "/api/v1/relationships"},
		{"annotations", "annotations.json", "/api/v1/annotations"},
	} {
		f, ok := entries["api/"+ep.file]
		if !ok {
			continue
		}
		raw, err := readZipFile(f)
		if err != nil {
			st := summary.Sections[ep.section]
			st.Errors++
			st.ErrorDetails = appendCapped(st.ErrorDetails, "read zip: "+err.Error(), 5)
			summary.Sections[ep.section] = st
			summary.TotalErrors++
			continue
		}
		items := extractItems(raw, ep.section)
		st := summary.Sections[ep.section]
		for _, item := range items {
			// Strip server-assigned fields that would conflict on the target.
			// Different servers issue different UUIDs/ids; we want the target
			// to mint fresh ones based on the natural keys (name, path, etc.).
			cleanItem := stripServerIDs(item)
			_, err := cli.PostJSON(ctx, ep.path, cleanItem)
			if err == nil {
				st.Created++
				summary.TotalCreated++
				continue
			}
			msg := err.Error()
			// PostJSON returns "POST /path: HTTP 409" for conflicts.
			if strings.Contains(msg, "HTTP 409") {
				st.Skipped++
				summary.TotalSkipped++
				continue
			}
			st.Errors++
			summary.TotalErrors++
			st.ErrorDetails = appendCapped(st.ErrorDetails, msg, 5)
		}
		summary.Sections[ep.section] = st
	}
	return summary, nil
}

// extractItems normalises the JSON returned by a list endpoint into a flat
// array of objects. The Core API uses several response shapes depending on
// the endpoint:
//
//	[{...}, {...}]                  ← raw array (rare)
//	{"items": [...]}                ← generic wrapper
//	{"users": [...]}                ← keyed by entity type (most common)
//	{"series": [...], "total": ...} ← keyed + paginated
//
// `sectionKey` is the entity name (e.g. "users") used to try a keyed lookup.
func extractItems(raw []byte, sectionKey string) []any {
	// Try a bare array first.
	var arr []any
	if err := json.Unmarshal(raw, &arr); err == nil {
		return arr
	}
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil
	}
	// Try the keyed-by-section convention first ("users" → users[])
	if v, ok := obj[sectionKey].([]any); ok {
		return v
	}
	// Try generic "items" wrapper
	if v, ok := obj["items"].([]any); ok {
		return v
	}
	// Try a few aliases (hyphen vs underscore vs singular)
	for _, alias := range []string{
		strings.ReplaceAll(sectionKey, "-", "_"),
		strings.TrimSuffix(sectionKey, "s"),
	} {
		if v, ok := obj[alias].([]any); ok {
			return v
		}
	}
	return nil
}

// stripServerIDs removes fields the target server should generate fresh.
// Without this, the POST would either fail with a uniqueness conflict or
// clone the source instance's UUIDs into the target (collision risk).
//
// We strip top-level `id`, `created_at`, `updated_at`, and `disk_bytes`
// (a runtime stat). The natural keys (`name`, `path`, `username`) are kept
// so the server can de-dupe.
func stripServerIDs(item any) any {
	obj, ok := item.(map[string]any)
	if !ok {
		return item
	}
	out := make(map[string]any, len(obj))
	for k, v := range obj {
		switch k {
		case "id", "created_at", "updated_at", "disk_bytes",
			"point_count", "first_timestamp", "last_timestamp",
			"last_value_ts", "last_value":
			// drop
		default:
			out[k] = v
		}
	}
	return out
}

func appendCapped(s []string, msg string, max int) []string {
	if len(s) >= max {
		return s
	}
	return append(s, msg)
}

func writeZipFile(zw *zip.Writer, name string, data []byte) error {
	w, err := zw.Create(name)
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

func readZipFile(f *zip.File) ([]byte, error) {
	rc, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

func extractTo(f *zip.File, dst string) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, rc)
	return err
}

func hostname() string {
	if h, err := os.Hostname(); err == nil {
		return h
	}
	return "unknown"
}
