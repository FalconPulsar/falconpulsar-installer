// SPDX-License-Identifier: AGPL-3.0-only
package actions

import (
	"strings"
	"testing"
)

func TestComponentImageRefMatchesComposeTagOverride(t *testing.T) {
	for _, test := range []struct{ name, env, component, tag, want string }{
		{"copilot override", "FP_COPILOT_IMAGE_TAG=alpha.123\n", "copilot", "latest", "registry.example/fp/copilot:alpha.123"},
		{"core keeps stack tag", "FP_COPILOT_IMAGE_TAG=alpha.123\n", "core", "stable", "registry.example/fp/core:stable"},
		{"copilot fallback", "", "copilot", "latest", "registry.example/fp/copilot:latest"},
		{"empty override", "FP_COPILOT_IMAGE_TAG=\n", "copilot", "stable", "registry.example/fp/copilot:stable"},
		{"mcp override", "FP_MCP_IMAGE_TAG=alpha.7\n", "mcp", "latest", "registry.example/fp/mcp:alpha.7"},
		{"mcp fallback", "FP_COPILOT_IMAGE_TAG=alpha.123\n", "mcp", "stable", "registry.example/fp/mcp:stable"},
	} {
		t.Run(test.name, func(t *testing.T) {
			stackWithEnv(t, test.env)
			if got := componentImageRef("registry.example/fp", test.tag, test.component); got != test.want {
				t.Fatalf("got %q, want %q", got, test.want)
			}
		})
	}
}

// "mcp" in COMPOSE_PROFILES is what compose reads, so it is the switch for
// every compose call and the update check, except that FP_MCP_ENABLED=false
// wins when the two disagree.
func TestMCPProfileFollowsComposeProfiles(t *testing.T) {
	for _, test := range []struct {
		name, env string
		want      bool
	}{
		{"no env", "", false},
		{"copilot only", "COMPOSE_PROFILES=copilot\n", false},
		{"mcp with copilot", "COMPOSE_PROFILES=copilot, mcp\n", true},
		{"quoted", "COMPOSE_PROFILES=\"mcp\"\n", true},
		{"not a prefix match", "COMPOSE_PROFILES=mcpx\n", false},
		{"flag true", "FP_MCP_ENABLED=true\nCOMPOSE_PROFILES=copilot,mcp\n", true},
		{"flag false wins", "FP_MCP_ENABLED=false\nCOMPOSE_PROFILES=copilot,mcp\n", false},
		{"flag false any case and quoted", "FP_MCP_ENABLED=\"False\"\nCOMPOSE_PROFILES=mcp\n", false},
		{"flag alone is not the profile", "FP_MCP_ENABLED=true\nCOMPOSE_PROFILES=copilot\n", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			stackWithEnv(t, test.env)
			if got := MCPEnabled(); got != test.want {
				t.Fatalf("MCPEnabled() = %v, want %v", got, test.want)
			}
			args := strings.Join(composeProfileArgs(), " ")
			if got := strings.Contains(args, "--profile mcp"); got != test.want {
				t.Errorf("composeProfileArgs() = %q, mcp included %v, want %v", args, got, test.want)
			}
			found := false
			for _, spec := range componentsForCheck() {
				if spec.containerName == "falconpulsar-mcp" {
					found = true
				}
			}
			if found != test.want {
				t.Errorf("componentsForCheck() has falconpulsar-mcp = %v, want %v", found, test.want)
			}
		})
	}
}

// The upgrade migration fp's own update path runs (the same rules as
// fp_migrate_mcp_setting in shared/lib/common.sh): the service is on by
// default, and FP_MCP_ENABLED=false keeps it off.
func TestEnsureMCPDefault(t *testing.T) {
	for _, test := range []struct {
		name, env    string
		wantProfiles string
		wantEnabled  string
		wantMCP      bool
	}{
		{"absent turns it on", "FP_UID=1000\nCOMPOSE_PROFILES=copilot\nFP_MCP_TOKEN=abc\n", "copilot,mcp", "true", true},
		{"absent with no profiles key", "FP_UID=1000\nFP_MCP_TOKEN=abc", "mcp", "true", true},
		{"false stays off and mcp is removed", "FP_MCP_ENABLED=false\nCOMPOSE_PROFILES=copilot, mcp,copilot\nFP_MCP_TOKEN=abc\n", "copilot", "false", false},
		{"true with copilot", "FP_MCP_ENABLED=true\nCOMPOSE_PROFILES=copilot\nFP_MCP_TOKEN=abc\n", "copilot,mcp", "true", true},
		{"crlf and quotes", "FP_MCP_ENABLED=true\r\nCOMPOSE_PROFILES=\"copilot\"\r\nFP_MCP_TOKEN=abc\r\n", "copilot,mcp", "true", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			stackWithEnv(t, test.env)
			if _, err := EnsureMCPDefault(); err != nil {
				t.Fatal(err)
			}
			env := parseEnvFile()
			if got := strings.TrimRight(env["COMPOSE_PROFILES"], "\r"); got != test.wantProfiles {
				t.Errorf("COMPOSE_PROFILES = %q, want %q", got, test.wantProfiles)
			}
			if got := strings.TrimRight(env["FP_MCP_ENABLED"], "\r"); got != test.wantEnabled {
				t.Errorf("FP_MCP_ENABLED = %q, want %q", got, test.wantEnabled)
			}
			if got := strings.TrimRight(env["FP_MCP_TOKEN"], "\r"); got != "abc" {
				t.Errorf("FP_MCP_TOKEN = %q, want the existing one kept", got)
			}
			if got := MCPEnabled(); got != test.wantMCP {
				t.Errorf("MCPEnabled() = %v, want %v", got, test.wantMCP)
			}
			// A second run has nothing left to change.
			if changes, err := EnsureMCPDefault(); err != nil || len(changes) != 0 {
				t.Errorf("second run: changes %v, err %v; want none", changes, err)
			}
		})
	}
}

func TestEnsureMCPDefaultMintsMissingToken(t *testing.T) {
	stackWithEnv(t, "FP_UID=1000\nFP_MCP_TOKEN=\n")
	if _, err := EnsureMCPDefault(); err != nil {
		t.Fatal(err)
	}
	if got := parseEnvFile()["FP_MCP_TOKEN"]; len(got) != 64 {
		t.Errorf("FP_MCP_TOKEN = %q, want 64 hex characters", got)
	}
}
