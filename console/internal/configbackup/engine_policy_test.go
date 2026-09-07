package configbackup

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Exercise the actual release bundler without executing an installation. A
// valid Compose file still fails at startup if its seccomp payload is missing.
func TestReleaseBundlesCarryEnginePolicy(t *testing.T) {
	root := repoRoot(t)
	for _, platform := range []string{"linux", "macos"} {
		t.Run(platform, func(t *testing.T) {
			cmd := exec.Command("bash", filepath.Join(root, ".github/scripts/bundle.sh"), platform)
			bundle, err := cmd.Output()
			if err != nil {
				t.Fatal(err)
			}
			for _, name := range []string{"engine-seccomp.json", "engine-seccomp.LICENSE", "engine-seccomp.source"} {
				want, err := os.ReadFile(filepath.Join(root, "shared", name))
				if err != nil {
					t.Fatal(err)
				}
				prefix := "cat >\"${__FP_BUNDLE_DIR}/shared/" + name + "\" <<'__FP_EOF_SECCOMP__'\n"
				_, rest, found := strings.Cut(string(bundle), prefix)
				got, _, terminated := strings.Cut(rest, "\n__FP_EOF_SECCOMP__\n")
				if !found || !terminated || !bytes.Equal([]byte(got), want) {
					t.Errorf("%s policy payload missing or changed", name)
				}
			}
		})
	}
	// Sibling repositories are optional in CI; when present, deployment copies
	// must agree with the policy verified against the Engine image.
	canonical := filepath.Join(root, "..", "falconpulsar-ai-engine", "docker", "engine-seccomp.json")
	if want, err := os.ReadFile(canonical); err == nil {
		got, err := os.ReadFile(filepath.Join(root, "shared", "engine-seccomp.json"))
		if err != nil || !bytes.Equal(got, want) {
			t.Fatal("installer seccomp policy differs from Engine")
		}
	}
}
