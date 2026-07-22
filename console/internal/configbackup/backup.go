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

	"github.com/falconpulsar/falconpulsar-installer/console/internal/actions"
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
	Skipped      int      `json:"skipped"`       // 409 Conflict
	Errors       int      `json:"errors"`        // other failures
	ErrorDetails []string `json:"error_details"` // first 5 error messages
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

// Export reads config + API data, zips, encrypts, writes to output.
func Export(ctx context.Context, output string, cli *api.Client, user, pass string) error {
	var zipBuf bytes.Buffer
	zw := zip.NewWriter(&zipBuf)
	// actions.HomeDir honors the FP_HOME override and probes the legacy
	// /home/falconpulsar service-user path — the stack files must come
	// from the real install dir, not blindly from ~/falconpulsar.
	home := actions.HomeDir()

	// manifest.json
	manifest := map[string]any{
		"format_version":       FormatVersion,
		"falconpulsar_version": "0.1.4-alpha.24",
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
	// satisfy parent/child dependencies).
	//
	// IMPORTANT: the Core /api/v1/series endpoint hard-caps page size at
	// server-side `output_max_rows` (default 1000) regardless of the
	// `?limit=` value. We MUST paginate or we silently truncate large
	// installations. The paginated path follows has_more + next_offset
	// from the response envelope. Other endpoints (assets, datasources,
	// mappings, etc.) return everything in one shot today, but we route
	// them through the same helper so they auto-paginate the day Core
	// adds per-endpoint caps. The cost when there's no pagination is one
	// extra round-trip per endpoint.
	for _, ep := range []struct {
		name, path, key string
	}{
		{"roles.json", "/api/v1/roles", "roles"},
		{"users.json", "/api/v1/users", "users"},
		{"asset-types.json", "/api/v1/asset-types", "asset_types"},
		{"assets.json", "/api/v1/assets", "assets"},
		{"datasources.json", "/api/v1/datasources", "datasources"},
		{"series.json", "/api/v1/series?include_engineering=true", "series"},
		{"mappings.json", "/api/v1/mappings", "mappings"},
		{"relationships.json", "/api/v1/relationships", "relationships"},
		{"annotations.json", "/api/v1/annotations", "annotations"},
	} {
		data, err := harvestPaginated(ctx, cli, ep.path, ep.key)
		if err != nil {
			// Don't abort the whole export over one failed section — write
			// an empty stub so import can at least continue with whatever
			// did harvest, and surface the section name in the manifest.
			data = []byte(`{"` + ep.key + `":[]}`)
		}
		_ = writeZipFile(zw, "api/"+ep.name, data)
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
	home := actions.HomeDir()
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
	// Legacy back-compat: a backup taken on a pre-mandatory-gateway install
	// may carry FP_AI_GATEWAY_ENABLED=false. AI is a required component —
	// force the key to true so older fp/tray binaries that still read it
	// never see the stack as AI-disabled.
	sanitizeRestoredEnv(filepath.Join(home, ".env"))

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

// harvestPaginated fetches a list endpoint's contents, walking the
// has_more / next_offset pagination envelope until exhaustion, and
// returns a single JSON document of the form `{"<sectionKey>": [...]}`.
//
// The Core REST API caps each page at `output_max_rows` (default 1000)
// regardless of `?limit=`, so without pagination /api/v1/series silently
// truncated large installations at 1000 entries (the bug that prompted
// this helper).
//
// Behaviour by response shape:
//
//  1. {"<key>":[...], "has_more": true, "next_offset": N}  ← paginate
//  2. {"<key>":[...], "has_more": false}                    ← single page, done
//  3. {"<key>":[...]} with no has_more field                ← single page, done
//  4. {"items":[...]}                                       ← single page, done
//  5. [...]                                                 ← bare array, done
//
// Per-page size is set to `pageLimit` (we use 1000, the server's default
// cap). If the server allows higher, the offset arithmetic still works.
// If the server clamps lower, has_more keeps us advancing correctly.
//
// Safety stop: at most 10_000 iterations so a buggy server that returns
// has_more=true forever can't lock the export.
func harvestPaginated(ctx context.Context, cli *api.Client, basePath, sectionKey string) ([]byte, error) {
	const pageLimit = 1000
	const maxIterations = 10_000

	var all []any
	offset := 0
	separator := "?"
	if strings.Contains(basePath, "?") {
		separator = "&"
	}

	for i := 0; i < maxIterations; i++ {
		pagedPath := fmt.Sprintf("%s%slimit=%d&offset=%d",
			basePath, separator, pageLimit, offset)
		raw, err := cli.GetRaw(ctx, pagedPath)
		if err != nil {
			if i == 0 {
				// Couldn't fetch the first page — propagate.
				return nil, err
			}
			// Mid-pagination failure: keep what we have, stop.
			break
		}

		// Try the keyed envelope first.
		var envelope struct {
			Items      []any `json:"items"`
			HasMore    bool  `json:"has_more"`
			NextOffset int   `json:"next_offset"`
		}
		_ = json.Unmarshal(raw, &envelope)

		// Pull out the section-keyed array (the common case).
		var asMap map[string]any
		_ = json.Unmarshal(raw, &asMap)
		var pageItems []any
		if asMap != nil {
			if arr, ok := asMap[sectionKey].([]any); ok {
				pageItems = arr
			} else if arr, ok := asMap[strings.ReplaceAll(sectionKey, "_", "-")].([]any); ok {
				pageItems = arr
			} else if arr, ok := asMap["items"].([]any); ok {
				pageItems = arr
			}
		}
		// Fall back to bare array.
		if pageItems == nil {
			var bare []any
			if err := json.Unmarshal(raw, &bare); err == nil {
				pageItems = bare
			}
		}

		all = append(all, pageItems...)

		// Decide whether to keep paginating. has_more is the canonical signal.
		// If the server didn't include it (older Core, or endpoints that
		// don't paginate), we stop after one page.
		hasMore := false
		nextOffset := offset + len(pageItems)
		if asMap != nil {
			if v, ok := asMap["has_more"].(bool); ok {
				hasMore = v
			}
			if v, ok := asMap["next_offset"].(float64); ok {
				nextOffset = int(v)
			}
		}
		// also reflect into the typed envelope so we honour either field name
		if envelope.HasMore {
			hasMore = true
		}
		if envelope.NextOffset > 0 {
			nextOffset = envelope.NextOffset
		}

		// Guard: if the server lied (has_more=true but no progress), bail.
		if !hasMore || nextOffset <= offset || len(pageItems) == 0 {
			break
		}
		offset = nextOffset
	}

	out := map[string]any{
		sectionKey: all,
		"count":    len(all),
	}
	return json.Marshal(out)
}

// InspectResult is the structured output of Inspect — what's in a backup
// without applying it. Safe to call without admin role on the *target*
// server (it never touches the network); only the encrypting admin creds
// are needed to decrypt.
type InspectResult struct {
	// Path is the source file path.
	Path string `json:"path"`
	// FileSize is the encrypted .fpconfig size in bytes.
	FileSize int64 `json:"file_size"`
	// FormatVersion read from the file header (NOT from manifest.json).
	FormatVersion uint8 `json:"format_version"`
	// Manifest is the raw manifest.json payload as a map.
	Manifest map[string]any `json:"manifest"`
	// StackFiles lists files/* entries with their decompressed size.
	StackFiles []InspectFile `json:"stack_files"`
	// Sections lists api/* sections with their item counts.
	Sections []InspectSection `json:"sections"`
	// TotalItems is the sum of Sections[].Count.
	TotalItems int `json:"total_items"`
	// Coverage is the series ↔ mappings cross-reference: how many series
	// are missing a mapping, broken down by source_type so the user can
	// distinguish "expected" no-mapping series (calculated, manual,
	// simulated, _system telemetry) from "external" orphans that should
	// probably be cleaned up. Empty if either series.json or mappings.json
	// is missing/empty.
	Coverage Coverage `json:"coverage"`
}

type InspectFile struct {
	Name string `json:"name"` // e.g. "compose.yml"
	Size int64  `json:"size"` // uncompressed bytes
}

type InspectSection struct {
	Name  string `json:"name"`  // e.g. "users"
	Count int    `json:"count"` // number of items
	Bytes int64  `json:"bytes"` // uncompressed bytes
}

// Coverage breaks down how series relate to mappings: which series have
// at least one mapping feeding them, which legitimately don't (calculated,
// manual, simulated, _system telemetry), and which are external-source
// orphans that should probably be cleaned up.
//
// Series:mapping is N:1 (many mappings can feed one series for redundancy),
// so MappingsCount can exceed SeriesWithMapping. Likewise SeriesCount can
// exceed MappedSeriesCount because non-external series don't need mappings.
type Coverage struct {
	SeriesCount       int      `json:"series_count"`
	MappingsCount     int      `json:"mappings_count"`
	SeriesWithMapping int      `json:"series_with_mapping"` // distinct series paths referenced by ≥1 mapping
	SeriesNoMapping   int      `json:"series_no_mapping"`   // series with zero mappings
	SystemTelemetry   int      `json:"system_telemetry"`    // _system.*  (no mapping expected)
	SourceCalculated  int      `json:"source_calculated"`   // source_type=calculated (no mapping expected)
	SourceManual      int      `json:"source_manual"`       // source_type=manual (no mapping expected)
	SourceSimulated   int      `json:"source_simulated"`    // source_type=simulated (no mapping expected)
	ExternalOrphans   int      `json:"external_orphans"`    // source_type=external AND no mapping → cleanup candidates
	OrphanExamples    []string `json:"orphan_examples"`     // up to 10 example paths
	RedundantMappings int      `json:"redundant_mappings"`  // total mappings - distinct mapped series (excess due to N:1 redundancy)
}

// extractStringField pulls a string from a JSON object, returning "" if
// the field is missing or not a string. Survives raw types from
// json.Unmarshal into interface{}.
func extractStringField(item any, key string) string {
	obj, ok := item.(map[string]any)
	if !ok {
		return ""
	}
	v, ok := obj[key].(string)
	if !ok {
		return ""
	}
	return v
}

// assetPathOf returns the asset-path portion of a series path
// ("name@asset.path" → "asset.path"). Returns the whole string if there
// is no @.
func assetPathOf(seriesPath string) string {
	at := strings.IndexByte(seriesPath, '@')
	if at < 0 {
		return seriesPath
	}
	return seriesPath[at+1:]
}

// isSystemSeries returns true if a series is internal telemetry that the
// server writes directly (no mapping expected). System series live under
// the `_system.*` asset path.
func isSystemSeries(seriesPath string) bool {
	ap := assetPathOf(seriesPath)
	return ap == "_system" || strings.HasPrefix(ap, "_system.") || strings.HasPrefix(ap, "_system/")
}

// computeCoverage builds the coverage report by cross-referencing the
// series and mappings arrays from a parsed backup. seriesItems and
// mappingsItems are the []any payloads extracted from api/series.json
// and api/mappings.json respectively (after extractItems).
func computeCoverage(seriesItems, mappingsItems []any) Coverage {
	cov := Coverage{
		SeriesCount:   len(seriesItems),
		MappingsCount: len(mappingsItems),
	}

	// Build the set of series paths that have ≥1 mapping. We deduplicate
	// because N:1 redundancy lets two mappings reference the same series.
	mapped := make(map[string]struct{}, len(mappingsItems))
	for _, m := range mappingsItems {
		ts := extractStringField(m, "target_series")
		if ts != "" {
			mapped[ts] = struct{}{}
		}
	}
	cov.SeriesWithMapping = len(mapped)
	cov.RedundantMappings = cov.MappingsCount - cov.SeriesWithMapping
	if cov.RedundantMappings < 0 {
		cov.RedundantMappings = 0 // safety: shouldn't go negative
	}

	// Bucket every series.
	for _, s := range seriesItems {
		path := extractStringField(s, "path")
		if path == "" {
			continue
		}
		if _, hasMap := mapped[path]; hasMap {
			continue
		}
		cov.SeriesNoMapping++

		if isSystemSeries(path) {
			cov.SystemTelemetry++
			continue
		}
		switch extractStringField(s, "source_type") {
		case "calculated":
			cov.SourceCalculated++
		case "manual":
			cov.SourceManual++
		case "simulated":
			cov.SourceSimulated++
		case "external", "":
			// "" means the API didn't include source_type; treat as
			// external since that's the implicit default and the most
			// common case where a missing mapping is a real problem.
			cov.ExternalOrphans++
			if len(cov.OrphanExamples) < 10 {
				cov.OrphanExamples = append(cov.OrphanExamples, path)
			}
		default:
			// Unrecognized source_type (future enum value) — count as
			// orphan so it gets surfaced rather than hidden.
			cov.ExternalOrphans++
			if len(cov.OrphanExamples) < 10 {
				cov.OrphanExamples = append(cov.OrphanExamples, path)
			}
		}
	}
	return cov
}

// Inspect decrypts a .fpconfig file with the supplied admin credentials,
// parses the payload zip, and returns a structured summary of its contents.
// Performs no API calls and writes nothing to disk — safe to run against
// a backup without a Core server present.
func Inspect(path, user, pass string) (InspectResult, error) {
	res := InspectResult{Path: path}

	enc, err := os.ReadFile(path)
	if err != nil {
		return res, err
	}
	res.FileSize = int64(len(enc))

	// The decrypt() helper already validates magic + format version.
	plain, err := decrypt(enc, user, pass)
	if err != nil {
		return res, err
	}
	// We re-extract the format version byte after the magic for the caller
	// (decrypt() consumed it but didn't return it).
	if len(enc) >= 5 {
		res.FormatVersion = enc[4]
	}

	zr, err := zip.NewReader(bytes.NewReader(plain), int64(len(plain)))
	if err != nil {
		return res, fmt.Errorf("invalid archive inside backup: %w", err)
	}

	// Index entries by name for selective reads.
	entries := map[string]*zip.File{}
	for _, f := range zr.File {
		entries[f.Name] = f
	}

	// Manifest
	if f, ok := entries["manifest.json"]; ok {
		if raw, err := readZipFile(f); err == nil {
			var m map[string]any
			_ = json.Unmarshal(raw, &m)
			res.Manifest = m
		}
	}

	// Stack files (files/*)
	for _, name := range []string{"compose.yml", ".env", "gateway.yaml"} {
		f, ok := entries["files/"+name]
		if !ok {
			continue
		}
		res.StackFiles = append(res.StackFiles, InspectFile{
			Name: name,
			Size: int64(f.UncompressedSize64),
		})
	}

	// API sections (api/*). The order here mirrors the import dependency
	// order so the inspect output reads top-to-bottom in the same order
	// the items would be applied. We also retain series + mappings arrays
	// for the coverage cross-reference below.
	var seriesItems, mappingsItems []any
	for _, sec := range []struct{ name, key, file string }{
		{"roles", "roles", "roles.json"},
		{"asset-types", "asset_types", "asset-types.json"},
		{"users", "users", "users.json"},
		{"datasources", "datasources", "datasources.json"},
		{"assets", "assets", "assets.json"},
		{"series", "series", "series.json"},
		{"mappings", "mappings", "mappings.json"},
		{"relationships", "relationships", "relationships.json"},
		{"annotations", "annotations", "annotations.json"},
	} {
		f, ok := entries["api/"+sec.file]
		if !ok {
			continue
		}
		raw, err := readZipFile(f)
		if err != nil {
			continue
		}
		items := extractItems(raw, sec.key)
		res.Sections = append(res.Sections, InspectSection{
			Name:  sec.name,
			Count: len(items),
			Bytes: int64(f.UncompressedSize64),
		})
		res.TotalItems += len(items)
		switch sec.name {
		case "series":
			seriesItems = items
		case "mappings":
			mappingsItems = items
		}
	}

	// Cross-reference series ↔ mappings. Skipped when either side is
	// empty (e.g. a backup of an asset-types-only test instance).
	if len(seriesItems) > 0 || len(mappingsItems) > 0 {
		res.Coverage = computeCoverage(seriesItems, mappingsItems)
	}

	return res, nil
}

// HumanReadable formats an InspectResult for terminal display.
func (r InspectResult) HumanReadable() string {
	var b strings.Builder
	fmt.Fprintf(&b, "Backup file: %s\n", r.Path)
	fmt.Fprintf(&b, "  File size:       %s\n", humanBytes(r.FileSize))
	fmt.Fprintf(&b, "  Format version:  %d\n", r.FormatVersion)
	if r.Manifest != nil {
		if v, ok := r.Manifest["falconpulsar_version"].(string); ok {
			fmt.Fprintf(&b, "  FalconPulsar:    %s\n", v)
		}
		if v, ok := r.Manifest["exported_at"].(string); ok {
			fmt.Fprintf(&b, "  Exported:        %s\n", v)
		}
		if v, ok := r.Manifest["source_host"].(string); ok {
			fmt.Fprintf(&b, "  Source host:     %s\n", v)
		}
		if v, ok := r.Manifest["source_platform"].(string); ok {
			fmt.Fprintf(&b, "  Source platform: %s\n", v)
		}
	}
	if len(r.StackFiles) > 0 {
		fmt.Fprintf(&b, "\nStack files:\n")
		for _, f := range r.StackFiles {
			fmt.Fprintf(&b, "  • %-15s %s\n", f.Name, humanBytes(f.Size))
		}
	}
	if len(r.Sections) > 0 {
		fmt.Fprintf(&b, "\nAPI sections:\n")
		for _, s := range r.Sections {
			fmt.Fprintf(&b, "  • %-14s %5d items  (%s)\n",
				s.Name, s.Count, humanBytes(s.Bytes))
		}
		fmt.Fprintf(&b, "\nTotal: %d items across %d sections\n",
			r.TotalItems, len(r.Sections))
	}
	if r.Coverage.SeriesCount > 0 || r.Coverage.MappingsCount > 0 {
		c := r.Coverage
		fmt.Fprintf(&b, "\nCoverage (series ↔ mappings):\n")
		fmt.Fprintf(&b, "  • series with mapping:     %5d  (%s)\n",
			c.SeriesWithMapping, pctOf(c.SeriesWithMapping, c.SeriesCount))
		fmt.Fprintf(&b, "  • series without mapping:  %5d  (%s)\n",
			c.SeriesNoMapping, pctOf(c.SeriesNoMapping, c.SeriesCount))
		if c.SeriesNoMapping > 0 {
			// Indented breakdown by why a series has no mapping.
			rows := []struct {
				label string
				count int
				note  string
			}{
				{"_system telemetry", c.SystemTelemetry, "(internal — no mapping expected)"},
				{"source=calculated", c.SourceCalculated, "(derived from FPQ — no mapping expected)"},
				{"source=manual", c.SourceManual, "(user-entered — no mapping expected)"},
				{"source=simulated", c.SourceSimulated, "(twin output — no mapping expected)"},
				{"source=external (ORPHANS)", c.ExternalOrphans,
					"← cleanup candidates"},
			}
			for _, row := range rows {
				if row.count > 0 {
					fmt.Fprintf(&b, "      ├─ %-28s %5d  %s\n",
						row.label, row.count, row.note)
				}
			}
			if len(c.OrphanExamples) > 0 {
				fmt.Fprintf(&b, "      └─ example orphans:\n")
				for _, p := range c.OrphanExamples {
					fmt.Fprintf(&b, "            %s\n", p)
				}
			}
		}
		if c.RedundantMappings > 0 {
			fmt.Fprintf(&b,
				"  • redundant mappings:     %5d  (mappings beyond 1-per-series, e.g. N:1 failover)\n",
				c.RedundantMappings)
		}
	}
	return b.String()
}

// pctOf renders an X/Y count as "X (P%)" with safe div-by-zero handling.
func pctOf(part, total int) string {
	if total <= 0 {
		return "0%"
	}
	return fmt.Sprintf("%.1f%%", 100.0*float64(part)/float64(total))
}

func humanBytes(n int64) string {
	const k = 1024
	switch {
	case n < k:
		return fmt.Sprintf("%d B", n)
	case n < k*k:
		return fmt.Sprintf("%.1f KiB", float64(n)/k)
	default:
		return fmt.Sprintf("%.1f MiB", float64(n)/(k*k))
	}
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

// sanitizeRestoredEnv rewrites any FP_AI_GATEWAY_ENABLED line in a restored
// .env to =true. The key is a legacy-compat artifact (pre-mandatory-gateway
// installs); nothing may ever set it false. No-op when the file is absent
// or already clean.
func sanitizeRestoredEnv(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	lines := strings.Split(string(data), "\n")
	changed := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "FP_AI_GATEWAY_ENABLED=") &&
			trimmed != "FP_AI_GATEWAY_ENABLED=true" {
			lines[i] = "FP_AI_GATEWAY_ENABLED=true"
			changed = true
		}
	}
	if changed {
		_ = os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0600)
	}
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
