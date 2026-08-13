package configbackup

// End-to-end round trip against a REAL Core server.
//
// The bug this exists for could not be seen from unit tests: Core masks
// datasource secrets on the public list endpoint, so the export captured
// "********", the import POSTed it back, Core answered 201, and the summary
// said errors=0 — while every datasource on the restored plant held the mask as
// its password and could not authenticate.
//
// Skipped unless FP_E2E_BASE points at a disposable server, because it CREATES
// AND MUTATES datasources. Never point it at a live plant.
//
//	docker run -d --name fp-e2e -p 17435:7433 -v fp-e2e:/data \
//	  -e FP_ADMIN_USER=admin -e FP_ADMIN_PASS=testpassword123 falconpulsar/core:latest
//	FP_E2E_BASE=http://127.0.0.1:17435 FP_E2E_USER=admin FP_E2E_PASS=testpassword123 \
//	  go test ./internal/configbackup/ -run E2E -v

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
)

func e2eClient(t *testing.T) (*api.Client, context.Context) {
	t.Helper()
	base := os.Getenv("FP_E2E_BASE")
	if base == "" {
		t.Skip("set FP_E2E_BASE to a disposable Core server to run the round trip")
	}
	cli := api.New()
	cli.BaseURL = base
	ctx := context.Background()
	user, pass := os.Getenv("FP_E2E_USER"), os.Getenv("FP_E2E_PASS")
	if err := cli.Login(ctx, user, pass); err != nil {
		t.Fatalf("login to %s failed: %v", base, err)
	}
	return cli, ctx
}

// isolateHome points FP_HOME at a throwaway directory so Export/Import touch a
// scratch install instead of the developer's real ~/falconpulsar. Import writes
// .env and the AI stores, so this is not optional.
func isolateHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".env"),
		[]byte("FP_DATA_DIR="+filepath.Join(home, "data")+"\nFP_REST_PORT=7433\nFP_HOME="+home+"\n"),
		0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FP_HOME", home)
	return home
}

func TestE2EDatasourceCredentialSurvivesRoundTrip(t *testing.T) {
	cli, ctx := e2eClient(t)
	home := isolateHome(t)

	const dsName = "e2e-roundtrip-ds"
	const realPassword = "Sup3rS3cret-e2e"

	// A datasource whose credential must survive export -> import.
	_, err := cli.PostJSON(ctx, "/api/v1/datasources", map[string]any{
		"name": dsName,
		"type": "mqtt",
		"config": map[string]any{
			"host": "broker.invalid", "port": 1883,
			"username": "scada", "password": realPassword,
		},
	})
	if err != nil {
		t.Fatalf("could not create the fixture datasource: %v", err)
	}

	// The public surface must NOT reveal it — that is the security property the
	// masking exists for, and the reason the backup cannot use this endpoint.
	raw, err := cli.GetRaw(ctx, "/api/v1/datasources")
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range extractItems(raw, "datasources") {
		o, _ := it.(map[string]any)
		if o["name"] != dsName {
			continue
		}
		cfg, _ := o["config"].(map[string]any)
		if got := cfg["password"]; got != secretMask {
			t.Fatalf("expected the public endpoint to mask the password, got %v — "+
				"if Core stopped masking, this test no longer proves anything", got)
		}
	}

	// Export. It may legitimately report INCOMPLETE here: the scratch FP_HOME has
	// no containers, so the AI stores cannot be snapshotted. The API sections are
	// what this test cares about.
	archive := filepath.Join(home, "roundtrip.fpconfig")
	if err := Export(ctx, archive, cli, os.Getenv("FP_E2E_USER"), os.Getenv("FP_E2E_PASS")); err != nil {
		var incomplete *IncompleteExportError
		if !asIncomplete(err, &incomplete) {
			t.Fatalf("export failed: %v", err)
		}
		t.Logf("export reported incomplete (expected without containers): %v", incomplete.Problems)
	}
	if _, err := os.Stat(archive); err != nil {
		t.Fatalf("no archive was written: %v", err)
	}

	// Break the credential, the way a rebuilt server would have none.
	id := datasourceIDByName(t, ctx, cli, dsName)
	if _, err := cli.PatchJSON(ctx, "/api/v1/datasources/"+itoa(id),
		map[string]any{"config": map[string]any{"password": "WRONG-value"}}); err != nil {
		t.Fatalf("could not clobber the credential: %v", err)
	}

	// Import must put the real one back.
	if _, err := Import(ctx, archive, cli, os.Getenv("FP_E2E_USER"), os.Getenv("FP_E2E_PASS")); err != nil {
		t.Fatalf("import failed: %v", err)
	}

	got := passwordFromBundle(t, ctx, cli, dsName)
	if got == secretMask {
		t.Fatal("the MASK was restored as the credential — the datasource would fail to authenticate " +
			"while appearing correctly configured")
	}
	if got != realPassword {
		t.Fatalf("credential not restored: got %q, want %q", got, realPassword)
	}
}

// ── helpers ────────────────────────────────────────────────────────────────

func asIncomplete(err error, target **IncompleteExportError) bool {
	return errorsAs(err, target)
}

func datasourceIDByName(t *testing.T, ctx context.Context, cli *api.Client, name string) int {
	t.Helper()
	raw, err := cli.GetRaw(ctx, "/api/v1/datasources")
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range extractItems(raw, "datasources") {
		if o, ok := it.(map[string]any); ok && o["name"] == name {
			if id, ok := o["id"].(float64); ok {
				return int(id)
			}
		}
	}
	t.Fatalf("datasource %q not found on the server", name)
	return 0
}

// passwordFromBundle reads the credential back through the admin bundle — the
// only channel that returns it unmasked.
func passwordFromBundle(t *testing.T, ctx context.Context, cli *api.Client, name string) string {
	t.Helper()
	raw, err := cli.GetRaw(ctx, "/api/v1/admin/config-bundle")
	if err != nil {
		t.Fatalf("config-bundle unavailable: %v", err)
	}
	var bundle struct {
		DatasourceSecrets []struct {
			Name   string         `json:"name"`
			Config map[string]any `json:"config"`
		} `json:"datasource_secrets"`
	}
	if err := jsonUnmarshal(raw, &bundle); err != nil {
		t.Fatalf("bundle did not parse: %v", err)
	}
	for _, ds := range bundle.DatasourceSecrets {
		if ds.Name == name {
			s, _ := ds.Config["password"].(string)
			return s
		}
	}
	t.Fatalf("%q has no entry in datasource_secrets — Core is not emitting it", name)
	return ""
}

func errorsAs(err error, target **IncompleteExportError) bool { return errors.As(err, target) }
func jsonUnmarshal(b []byte, v any) error                     { return json.Unmarshal(b, v) }
func itoa(i int) string                                       { return strconv.Itoa(i) }
