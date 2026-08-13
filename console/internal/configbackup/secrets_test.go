package configbackup

// The mask must never be written back as if it were a credential.
//
// Core masks password / token / client_key / private_key to "********" on the
// public datasource endpoints, and its create handler has no unmask step. Before
// this was fixed, import POSTed the mask straight through: Core answered 201, the
// import reported "errors=0", and every datasource on the restored plant held
// "********" as its password and could not authenticate — while the UI rendered
// it exactly as it renders a real secret, so nothing looked wrong.

import (
	"encoding/json"
	"testing"
)

func configOf(t *testing.T, v any) map[string]any {
	t.Helper()
	obj, ok := v.(map[string]any)
	if !ok {
		t.Fatalf("expected an object, got %T", v)
	}
	cfg, ok := obj["config"].(map[string]any)
	if !ok {
		t.Fatalf("expected a config object, got %T", obj["config"])
	}
	return cfg
}

func TestStripMaskedSecretsRemovesEveryMaskedKey(t *testing.T) {
	item := map[string]any{
		"name": "plc1",
		"config": map[string]any{
			"endpoint":    "opc.tcp://10.0.0.5:4840",
			"username":    "scada",
			"password":    secretMask,
			"token":       secretMask,
			"client_key":  secretMask,
			"private_key": secretMask,
		},
	}

	cfg := configOf(t, stripMaskedSecrets(item))

	for _, k := range secretConfigKeys {
		if v, present := cfg[k]; present {
			t.Errorf("%q survived stripping with value %q — it would be stored as the credential", k, v)
		}
	}
	// Non-secret fields must be untouched, or the datasource loses its identity.
	if cfg["endpoint"] != "opc.tcp://10.0.0.5:4840" {
		t.Errorf("endpoint was altered: %v", cfg["endpoint"])
	}
	if cfg["username"] != "scada" {
		t.Errorf("username was altered: %v", cfg["username"])
	}
}

func TestStripMaskedSecretsKeepsRealCredentials(t *testing.T) {
	// A backup taken from a Core old enough to return unmasked configs still
	// restores directly. Only the literal mask is dropped.
	item := map[string]any{
		"config": map[string]any{
			"password": "Hunter2!",
			"token":    secretMask,
		},
	}

	cfg := configOf(t, stripMaskedSecrets(item))

	if cfg["password"] != "Hunter2!" {
		t.Errorf("a real password was dropped: %v", cfg["password"])
	}
	if _, present := cfg["token"]; present {
		t.Error("the masked token survived")
	}
}

func TestStripMaskedSecretsToleratesOddShapes(t *testing.T) {
	// Import feeds this whatever the archive holds, including from older or
	// hand-edited files. It must not panic.
	for name, item := range map[string]any{
		"no config key":      map[string]any{"name": "x"},
		"config is a string": map[string]any{"config": "not-an-object"},
		"config is null":     map[string]any{"config": nil},
		"not an object":      []any{1, 2, 3},
		"empty config":       map[string]any{"config": map[string]any{}},
	} {
		t.Run(name, func(t *testing.T) {
			_ = stripMaskedSecrets(item) // must simply not panic
		})
	}
}

// The bundle section Core emits must parse into what the restore path reads.
// If either side renames the field this fails, rather than silently restoring
// no credentials at all.
func TestBundleDatasourceSecretsShapeParses(t *testing.T) {
	bundle := []byte(`{
	  "manifest": {"version": 3},
	  "datasource_secrets": [
	    {"name": "plc1", "config": {"endpoint": "opc.tcp://h:4840", "password": "Hunter2!"}},
	    {"name": "broker", "config": {"token": "abc123"}}
	  ]
	}`)

	var parsed struct {
		DatasourceSecrets []struct {
			Name   string         `json:"name"`
			Config map[string]any `json:"config"`
		} `json:"datasource_secrets"`
	}
	if err := json.Unmarshal(bundle, &parsed); err != nil {
		t.Fatalf("bundle did not parse: %v", err)
	}
	if len(parsed.DatasourceSecrets) != 2 {
		t.Fatalf("expected 2 datasource secrets, got %d", len(parsed.DatasourceSecrets))
	}
	if parsed.DatasourceSecrets[0].Config["password"] != "Hunter2!" {
		t.Errorf("password did not survive the round trip: %v",
			parsed.DatasourceSecrets[0].Config["password"])
	}
}

// A v1/v2 archive has no datasource_secrets section. Restore must no-op rather
// than error, so older backups keep importing.
func TestBundleWithoutSecretsSectionIsTolerated(t *testing.T) {
	var parsed struct {
		DatasourceSecrets []struct {
			Name string `json:"name"`
		} `json:"datasource_secrets"`
	}
	if err := json.Unmarshal([]byte(`{"manifest":{"version":2}}`), &parsed); err != nil {
		t.Fatalf("a v2 bundle must still parse: %v", err)
	}
	if len(parsed.DatasourceSecrets) != 0 {
		t.Errorf("expected no secrets, got %d", len(parsed.DatasourceSecrets))
	}
}
