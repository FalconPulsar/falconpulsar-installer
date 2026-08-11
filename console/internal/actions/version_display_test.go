// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2024-2026 FalconPulsar Contributors

package actions

import "testing"

// The About surfaces (fp console, macOS QuickDock, Windows tray) all render a
// component as "<version> (<revision>)". That is right for a clean tag, and
// wrong for a `git describe` version, which ALREADY ends in the revision:
// "v0.1.4-alpha.89-5-g61ec2ad (61ec2ad)" says the same seven characters twice
// and — because the columns are fixed width — the repetition is what pushed
// the Core row past its column and truncated the SHA the operator needs.
//
// Three implementations of this rule exist in three languages, so this test
// pins the one that can be tested, and the same cases are mirrored in the
// Swift and C# comments.
func TestDisplayString(t *testing.T) {
	cases := []struct {
		name     string
		info     ContainerInfo
		expected string
	}{
		{
			name:     "clean tag keeps its revision suffix",
			info:     ContainerInfo{Version: "v0.1.4-alpha.157", Revision: "304e05c"},
			expected: "v0.1.4-alpha.157 (304e05c)",
		},
		{
			name:     "git describe version does not repeat the sha",
			info:     ContainerInfo{Version: "v0.1.4-alpha.89-5-g61ec2ad", Revision: "61ec2ad"},
			expected: "v0.1.4-alpha.89-5-g61ec2ad",
		},
		{
			name:     "digest fallback is not printed twice",
			info:     ContainerInfo{Version: "a03db27", Revision: "a03db27"},
			expected: "a03db27",
		},
		{
			name:     "no revision, nothing to append",
			info:     ContainerInfo{Version: "v0.1.28", Revision: ""},
			expected: "v0.1.28",
		},
		{
			name:     "unknown stays unknown",
			info:     ContainerInfo{Version: "n/a", Revision: "abc1234"},
			expected: "n/a",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.info.DisplayString(); got != tc.expected {
				t.Errorf("DisplayString() = %q, want %q", got, tc.expected)
			}
		})
	}
}
