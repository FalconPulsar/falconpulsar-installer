// SPDX-License-Identifier: AGPL-3.0-only
package actions

import "testing"

func TestComponentImageRefMatchesComposeTagOverride(t *testing.T) {
	for _, test := range []struct{ name, env, component, tag, want string }{
		{"copilot override", "FP_COPILOT_IMAGE_TAG=alpha.123\n", "copilot", "latest", "registry.example/fp/copilot:alpha.123"},
		{"core keeps stack tag", "FP_COPILOT_IMAGE_TAG=alpha.123\n", "core", "stable", "registry.example/fp/core:stable"},
		{"copilot fallback", "", "copilot", "latest", "registry.example/fp/copilot:latest"},
		{"empty override", "FP_COPILOT_IMAGE_TAG=\n", "copilot", "stable", "registry.example/fp/copilot:stable"},
	} {
		t.Run(test.name, func(t *testing.T) {
			stackWithEnv(t, test.env)
			if got := componentImageRef("registry.example/fp", test.tag, test.component); got != test.want {
				t.Fatalf("got %q, want %q", got, test.want)
			}
		})
	}
}
