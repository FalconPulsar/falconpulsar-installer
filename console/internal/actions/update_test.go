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

// The outside assistant service has no FP_*_ENABLED flag: "mcp" in
// COMPOSE_PROFILES is the switch, and every compose call and the update
// check must then include it.
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
