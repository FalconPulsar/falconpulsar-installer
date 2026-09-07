package configbackup

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Build encrypted synthetic archives, including ZIP checksum failures, without
// contacting a server, invoking Export, or reading an installed stack.
func writeInspectFixture(t *testing.T, entries map[string]string, corrupt string, version byte) string {
	t.Helper()
	var payload bytes.Buffer
	zw := zip.NewWriter(&payload)
	names := make([]string, 0, len(entries))
	for name := range entries {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Store})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(entries[name])); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	plain := payload.Bytes()
	if corrupt != "" {
		zr, err := zip.NewReader(bytes.NewReader(plain), int64(len(plain)))
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, f := range zr.File {
			if f.Name == corrupt {
				offset, err := f.DataOffset()
				if err != nil || f.UncompressedSize64 == 0 {
					t.Fatalf("invalid corruption fixture: %v", err)
				}
				plain[offset] ^= 0xff
				found = true
			}
		}
		if !found {
			t.Fatalf("fixture entry %q not found", corrupt)
		}
	}
	enc, err := encrypt(plain, "fixture-admin", "fixture-password")
	if err != nil {
		t.Fatal(err)
	}
	enc[4] = version
	path := filepath.Join(t.TempDir(), "synthetic.fpconfig")
	if err := os.WriteFile(path, enc, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func inspectFixture(t *testing.T, entries map[string]string, corrupt string, version byte) (InspectResult, error) {
	t.Helper()
	return Inspect(writeInspectFixture(t, entries, corrupt, version), "fixture-admin", "fixture-password")
}

func TestInspectListsDeclaredConfigurationWithoutSecretContents(t *testing.T) {
	const secret = "synthetic-secret-must-never-be-printed"
	entries := map[string]string{
		"manifest.json":           `{"bundle":true,"sections":["asset_types"],"config_stores":["ai_config.db","db/fp-agentics.db"],"incomplete":false,"errors":null}`,
		"api/config-bundle.json":  `{"password":"` + secret + `"}`,
		"api/asset-types.json":    `{"asset_types":[{"id":1},{"id":2}]}`,
		"files/ai_config.db":      "synthetic SQLite content " + secret,
		"files/db_fp-agentics.db": "synthetic engine SQLite content " + secret,
	}
	res, err := inspectFixture(t, entries, "", FormatVersion)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Warnings) != 0 || res.TotalItems != 2 {
		t.Fatalf("unexpected report counts: warnings=%d, items=%d", len(res.Warnings), res.TotalItems)
	}
	if res.ConfigBundle == nil || res.ConfigBundle.Size != int64(len(entries["api/config-bundle.json"])) {
		t.Fatal("config bundle metadata missing or incorrect")
	}
	if len(res.StackFiles) != 2 || res.StackFiles[0].Name != "ai_config.db" || res.StackFiles[1].Name != "db_fp-agentics.db" {
		t.Fatalf("configuration store inventory is incorrect: %+v", res.StackFiles)
	}
	encoded, err := json.Marshal(res)
	if err != nil {
		t.Fatal(err)
	}
	for _, report := range []string{res.HumanReadable(), string(encoded)} {
		if strings.Contains(report, secret) {
			t.Fatal("inspect report exposed a configuration payload")
		}
		if !strings.Contains(report, "config-bundle.json") && !strings.Contains(report, "config bundle: present") {
			t.Fatal("inspect report omitted config bundle presence")
		}
	}
}

func TestInspectRejectsMissingDeclaredContents(t *testing.T) {
	for _, tc := range []struct{ name, manifest, missing string }{
		{"bundle", `{"bundle":true}`, "api/config-bundle.json"},
		{"store", `{"config_stores":["db/fp-agentics.db"]}`, "files/db_fp-agentics.db"},
		{"section", `{"sections":["asset_types"]}`, "api/asset-types.json"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := inspectFixture(t, map[string]string{"manifest.json": tc.manifest}, "", FormatVersion)
			if err == nil || !strings.Contains(err.Error(), "missing declared entry "+tc.missing) {
				t.Fatalf("expected missing-entry error for %s, got %v", tc.missing, err)
			}
		})
	}
}

func TestInspectRejectsCorruptDeclaredContents(t *testing.T) {
	for _, tc := range []struct{ name, manifest, file string }{
		{"bundle", `{"bundle":true}`, "api/config-bundle.json"},
		{"store", `{"config_stores":["db/fp-agentics.db"]}`, "files/db_fp-agentics.db"},
		{"section", `{"sections":["asset_types"]}`, "api/asset-types.json"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := inspectFixture(t, map[string]string{"manifest.json": tc.manifest, tc.file: "synthetic content"}, tc.file, FormatVersion)
			if err == nil || !strings.Contains(err.Error(), tc.file) || !strings.Contains(err.Error(), "checksum") {
				t.Fatalf("expected ZIP checksum error for %s, got %v", tc.file, err)
			}
		})
	}
}

func TestInspectRejectsMalformedManifest(t *testing.T) {
	for _, tc := range []struct{ name, manifest, corrupt string }{
		{"invalid JSON", "{", ""},
		{"null", "null", ""},
		{"array", "[]", ""},
		{"checksum", "{}", "manifest.json"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := inspectFixture(t, map[string]string{"manifest.json": tc.manifest}, tc.corrupt, FormatVersion)
			if err == nil || !strings.Contains(err.Error(), "manifest.json") {
				t.Fatalf("expected invalid-manifest error, got %v", err)
			}
		})
	}
}

func TestInspectReportsDeclaredPartialExport(t *testing.T) {
	res, err := inspectFixture(t, map[string]string{
		"manifest.json":  `{"bundle":false,"sections":["users"],"config_stores":null,"incomplete":true,"errors":["series: unavailable"]}`,
		"api/users.json": `{"users":[]}`,
	}, "", FormatVersion)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Warnings) != 2 {
		t.Fatalf("expected both incomplete and export-error warnings, got %v", res.Warnings)
	}
	encoded, err := json.Marshal(res)
	if err != nil {
		t.Fatal(err)
	}
	for _, report := range []string{res.HumanReadable(), string(encoded)} {
		if !strings.Contains(report, "INCOMPLETE") || !strings.Contains(report, "series: unavailable") {
			t.Fatal("inspect report hid the partial export")
		}
	}
}

func TestInspectRejectsMalformedDeclarations(t *testing.T) {
	for _, tc := range []struct{ name, manifest string }{
		{"bundle", `{"bundle":"true"}`},
		{"sections", `{"sections":"users"}`},
		{"store name", `{"config_stores":[42]}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := inspectFixture(t, map[string]string{"manifest.json": tc.manifest}, "", FormatVersion)
			if err == nil || !strings.Contains(err.Error(), "manifest") {
				t.Fatalf("expected declaration error, got %v", err)
			}
		})
	}
}

func TestInspectAcceptsLegacyUnknownCoverage(t *testing.T) {
	for _, tc := range []struct {
		name    string
		entries map[string]string
		version byte
	}{
		{"no manifest", map[string]string{"api/users.json": `{"users":[]}`}, 1},
		{"old manifest", map[string]string{"manifest.json": `{"format_version":2,"bundle":null}`, "files/ai_config.db": "synthetic SQLite content"}, 2},
		{"empty metadata", map[string]string{"manifest.json": `{"bundle":false,"sections":null,"config_stores":[],"errors":null}`}, 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res, err := inspectFixture(t, tc.entries, "", tc.version)
			if err != nil || len(res.Warnings) != 0 {
				t.Fatalf("legacy/empty declarations should remain inspectable: %v, warnings %v", err, res.Warnings)
			}
		})
	}
}
