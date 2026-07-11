package actions

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
)

// stackWithEnv points HomeDir at a temp stack dir containing the given
// .env content. Empty content means "no .env at all".
func stackWithEnv(t *testing.T, env string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("FP_HOME", home)
	if env != "" {
		if err := os.WriteFile(filepath.Join(home, ".env"), []byte(env), 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestEndpointURLsDefaultWithoutEnv(t *testing.T) {
	stackWithEnv(t, "")
	if got := RestURL(); got != api.DefaultBaseURL {
		t.Errorf("RestURL() = %q, want %q", got, api.DefaultBaseURL)
	}
	if got := UIURL(); got != "http://localhost:8080" {
		t.Errorf("UIURL() = %q, want default", got)
	}
	if got := GatewayURL(); got != "http://localhost:7436" {
		t.Errorf("GatewayURL() = %q, want default", got)
	}
}

func TestEndpointURLsHonorPortRemap(t *testing.T) {
	stackWithEnv(t,
		"FP_REST_PORT=17433\n"+
			"FP_UI_PORT=18080\n"+
			"FP_GATEWAY_PORT=17436\n")
	if got := RestURL(); got != "http://localhost:17433" {
		t.Errorf("RestURL() = %q, want remapped port", got)
	}
	if got := UIURL(); got != "http://localhost:18080" {
		t.Errorf("UIURL() = %q, want remapped port", got)
	}
	if got := GatewayURL(); got != "http://localhost:17436" {
		t.Errorf("GatewayURL() = %q, want remapped port", got)
	}
	if got := NewAPIClient().BaseURL; got != "http://localhost:17433" {
		t.Errorf("NewAPIClient().BaseURL = %q, want remapped port", got)
	}
}

func TestEndpointURLsIgnoreMalformedPorts(t *testing.T) {
	stackWithEnv(t,
		"FP_REST_PORT=core\n"+
			"FP_UI_PORT=0\n"+
			"FP_GATEWAY_PORT=99999\n")
	if got := RestURL(); got != api.DefaultBaseURL {
		t.Errorf("RestURL() = %q, want default for non-numeric port", got)
	}
	if got := UIURL(); got != "http://localhost:8080" {
		t.Errorf("UIURL() = %q, want default for port 0", got)
	}
	if got := GatewayURL(); got != "http://localhost:7436" {
		t.Errorf("GatewayURL() = %q, want default for out-of-range port", got)
	}
}

func TestAISetupIncomplete(t *testing.T) {
	stackWithEnv(t, "")
	if AISetupIncomplete() {
		t.Error("AISetupIncomplete() = true without .env, want false")
	}

	stackWithEnv(t, "FP_AI_SETUP_INCOMPLETE=1\n")
	if !AISetupIncomplete() {
		t.Error("AISetupIncomplete() = false with marker set, want true")
	}

	stackWithEnv(t, "FP_AI_SETUP_INCOMPLETE=0\n")
	if AISetupIncomplete() {
		t.Error("AISetupIncomplete() = true with marker=0, want false")
	}
}
