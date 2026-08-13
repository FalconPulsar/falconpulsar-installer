package configbackup

import "testing"

// Core returns assets in sorted BYTE order over "_asset/id/<decimal>", so id
// 100 arrives before id 95. Imported in that order a child can be POSTed before
// its parent; Core auto-creates the parent as a placeholder and the real
// parent's POST then comes back 409, counted as "skipped" — so its asset_type,
// properties and status are lost with no error reported.
func TestAssetsAreOrderedParentsBeforeChildren(t *testing.T) {
	// Deliberately in the order Core would return them: "/plant/line1/press"
	// (id 100) ahead of "/plant" (id 95).
	items := []any{
		map[string]any{"id": 100.0, "path": "/plant/line1/press"},
		map[string]any{"id": 95.0, "path": "/plant"},
		map[string]any{"id": 98.0, "path": "/plant/line1"},
	}

	ordered := orderAssetsParentsFirst(items)

	seen := map[string]bool{}
	for _, it := range ordered {
		p := it.(map[string]any)["path"].(string)
		if parent := parentOf(p); parent != "" && !seen[parent] {
			t.Errorf("%q was imported before its parent %q", p, parent)
		}
		seen[p] = true
	}
	if len(ordered) != len(items) {
		t.Errorf("ordering changed the item count: %d -> %d", len(items), len(ordered))
	}
}

func parentOf(path string) string {
	for i := len(path) - 1; i > 0; i-- {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return ""
}

func TestAssetOrderingIsStableWithinADepth(t *testing.T) {
	// Siblings must keep their original relative order, so a restore is
	// reproducible rather than depending on map iteration.
	items := []any{
		map[string]any{"path": "/a/one"},
		map[string]any{"path": "/a/two"},
		map[string]any{"path": "/a/three"},
	}
	ordered := orderAssetsParentsFirst(items)
	want := []string{"/a/one", "/a/two", "/a/three"}
	for i, w := range want {
		if got := ordered[i].(map[string]any)["path"].(string); got != w {
			t.Errorf("position %d: got %q, want %q", i, got, w)
		}
	}
}

func TestAssetOrderingToleratesMissingPaths(t *testing.T) {
	// Must not panic or drop items when an entry has no usable path.
	items := []any{
		map[string]any{"path": "/a/b"},
		map[string]any{"name": "no path at all"},
		map[string]any{"path": ""},
		"not even an object",
		map[string]any{"path": "/a"},
	}
	ordered := orderAssetsParentsFirst(items)
	if len(ordered) != len(items) {
		t.Fatalf("items were lost: %d -> %d", len(items), len(ordered))
	}
	// The two real paths must still be parent-first.
	var order []string
	for _, it := range ordered {
		if o, ok := it.(map[string]any); ok {
			if p, ok := o["path"].(string); ok && p != "" {
				order = append(order, p)
			}
		}
	}
	if len(order) != 2 || order[0] != "/a" || order[1] != "/a/b" {
		t.Errorf("expected [/a /a/b], got %v", order)
	}
}

// FP_HOME is an absolute host path. compose.yml mounts ${FP_HOME}/nginx.conf
// into ui and ${FP_HOME}/auth-policy.json into copilot, so carrying the
// backup's value onto a host that installed elsewhere points both bind mounts
// at a path that does not exist — and Docker answers a missing bind source by
// creating a root-owned DIRECTORY where a file belongs.
func TestFPHomeIsTreatedAsMachineSpecific(t *testing.T) {
	for _, want := range []string{
		"FP_HOME",
		"FP_DATA_DIR", "FP_GATEWAY_DATA_DIR", "FP_ENGINE_DATA_DIR", "FP_COPILOT_DATA_DIR",
		"FP_GATEWAY_CONFIG", "FP_UID", "FP_GID",
	} {
		found := false
		for _, k := range machineSpecificEnvKeys {
			if k == want {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("%s must be preserved from the TARGET host, not restored from the backup", want)
		}
	}
}
