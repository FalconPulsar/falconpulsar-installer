package configbackup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Run only against the disposable server configured by e2eClient. MQTT parser
// settings live in ds_ext.<name>.subscriptions, outside the datasource list and
// its reconstructed certificate/password config. A successful import summary
// alone therefore cannot prove that an MQTT datasource was restored.
func TestE2EMqttExtendedConfigSurvivesRoundTrip(t *testing.T) {
	cli, ctx := e2eClient(t)
	home := isolateHome(t)
	const name = "e2e-mqtt-extended-config"
	path := "/api/v1/datasources/" + name + "/mqtt/subscriptions"
	if _, err := cli.PostJSON(ctx, "/api/v1/datasources", map[string]any{
		"name": name, "type": "mqtt",
		"config": map[string]any{"host": "broker.invalid", "port": 1883},
	}); err != nil {
		t.Fatal(err)
	}
	var expected map[string]any
	if err := json.Unmarshal([]byte(`{
		"payload_definitions":[{"id":"temperature","name":"Temperature",
		"priority":5,"condition":"auto","enabled":false,
		"fields":{"tag":{"path":"$.tag","is_address":true},"value":{"path":"$.value","type":"number"}},
		"mappings":[]}],
		"subscriptions":[{"id":"plant","topic":"plant/+/measurements","qos":1,"enabled":true}]
	}`), &expected); err != nil {
		t.Fatal(err)
	}
	if _, err := cli.PostJSON(ctx, path, expected); err != nil {
		t.Fatalf("save MQTT fixture: %v", err)
	}
	archive := filepath.Join(home, "mqtt-roundtrip.fpconfig")
	if err := Export(ctx, archive, cli, os.Getenv("FP_E2E_USER"), os.Getenv("FP_E2E_PASS")); err != nil {
		var incomplete *IncompleteExportError
		if !asIncomplete(err, &incomplete) {
			t.Fatalf("export: %v", err)
		}
		// This fixture intentionally has no companion service databases.
		t.Log("Companion snapshots unavailable in the disposable fixture")
	}
	if _, err := cli.PostJSON(ctx, path, map[string]any{"payload_definitions": []any{}, "subscriptions": []any{}}); err != nil {
		t.Fatal(err)
	}
	if _, err := Import(ctx, archive, cli, os.Getenv("FP_E2E_USER"), os.Getenv("FP_E2E_PASS")); err != nil {
		t.Fatalf("import: %v", err)
	}
	got, err := cli.GetJSON(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, expected) {
		t.Fatal("MQTT payload definitions/subscriptions did not survive native export/import")
	}
}
