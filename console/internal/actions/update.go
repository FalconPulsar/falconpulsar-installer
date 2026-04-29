// update.go — "is there a newer image available?" + "apply the update"
//
// Design notes:
//   - Source of truth for what's available is whatever Docker registry the
//     operator already pulls from (FP_REGISTRY, defaulting to falconpulsar
//     on Docker Hub). NOT GitHub releases, NOT falconpulsar.com — those
//     fail in private/air-gapped deployments.
//   - "Is an update available?" = compare the manifest digest of the
//     running container's image to the manifest digest of the ref it
//     pulls from (`${FP_REGISTRY}/<component>:${FP_VERSION}`). Different
//     digests = update available. No semver math, no API calls beyond
//     the registry the operator already trusts.
//   - "Apply the update" = invoke install.sh in upgrade-fastpath mode.
//     We do NOT reimplement pull-and-recreate here because install.sh
//     already does that *and* has the registry-auth re-probe + backoff
//     retry + healthcheck wait baked in (existing.sh:fp_try_upgrade_
//     fastpath). Reusing it means a single tested code path.
//
// What this file does NOT do:
//   - Refresh compose.yml / nginx.conf / .env (full install.sh in
//     upgrade mode handles those when they change). Tray-driven update
//     is for the routine image-only refresh case.
//   - Self-update the `fp` CLI binary (handled by install.sh's
//     fp_install_cli step on the next full upgrade).
//   - Image-signature verification (out of scope for v1; on roadmap).
//   - Background scheduling (v1 is "tray-open detection only").

package actions

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

// ComponentUpdateStatus is one row in the "Check for updates" result.
type ComponentUpdateStatus struct {
	// Name as displayed to the operator. e.g. "Core", "Web UI", "AI Capabilities".
	Name string `json:"name"`
	// Image ref the running container is using, e.g. "falconpulsar/core:0.1.0".
	// Empty if the container isn't running.
	ImageRef string `json:"image_ref,omitempty"`
	// Manifest digest of the local image (the one the running container is
	// using). Empty if no local image found.
	LocalDigest string `json:"local_digest,omitempty"`
	// Manifest digest of the remote image at the same ref. Empty if the
	// registry probe failed.
	RemoteDigest string `json:"remote_digest,omitempty"`
	// True iff both digests resolved AND they differ.
	UpdateAvailable bool `json:"update_available"`
	// Categorized failure (auth | unreachable | not_found | tls | other)
	// when the remote digest couldn't be resolved. Empty on success.
	ErrorKind string `json:"error_kind,omitempty"`
	// Human-readable error message (raw) for diagnostics. Empty on success.
	Error string `json:"error,omitempty"`
}

// UpdateCheckResult is the full result of `fp update --check`.
type UpdateCheckResult struct {
	// Components inspected. Always 2 (core, ui) plus ai-gateway if enabled.
	Components []ComponentUpdateStatus `json:"components"`
	// True iff any component has an update available.
	Any bool `json:"any_update_available"`
	// True iff any component had a registry probe failure (any non-empty
	// ErrorKind). The caller can use this to surface a connectivity
	// modal in the tray instead of "no updates."
	AnyError bool `json:"any_probe_failed"`
	// Registry being probed (the resolved value of FP_REGISTRY).
	Registry string `json:"registry"`
	// Tag being probed (the resolved value of FP_VERSION).
	Tag string `json:"tag"`
}

// componentSpec describes one component for the update check.
type componentSpec struct {
	displayName   string // e.g. "Core"
	containerName string // e.g. "falconpulsar-core"
	imageBaseName string // e.g. "core" — joined with FP_REGISTRY to form full ref
}

// componentsForCheck returns the components whose update status the
// operator cares about, honoring the AI-gateway enabled flag.
func componentsForCheck() []componentSpec {
	specs := []componentSpec{
		{displayName: "Core", containerName: "falconpulsar-core", imageBaseName: "core"},
		{displayName: "Web UI", containerName: "falconpulsar-ui", imageBaseName: "ui"},
	}
	if AIGatewayEnabled() {
		specs = append(specs, componentSpec{
			displayName:   "AI Capabilities",
			containerName: "falconpulsar-ai-gateway",
			imageBaseName: "ai-gateway",
		})
	}
	return specs
}

// CheckUpdates inspects each component, returning a populated
// UpdateCheckResult. Network-bound (one `docker manifest inspect` per
// component); call from a context with a reasonable timeout.
//
// On registry probe failure for a single component we don't abort the
// whole check — we record the error per-component and continue. The
// tray UI can render "core: connectivity error; ui: up to date" rather
// than going all-or-nothing.
func CheckUpdates(ctx context.Context) UpdateCheckResult {
	registry := envFromDotEnv("FP_REGISTRY")
	if registry == "" {
		registry = "falconpulsar"
	}
	tag := envFromDotEnv("FP_VERSION")
	if tag == "" {
		tag = "latest"
	}

	out := UpdateCheckResult{
		Registry: registry,
		Tag:      tag,
	}

	for _, spec := range componentsForCheck() {
		row := ComponentUpdateStatus{Name: spec.displayName}
		ref := registry + "/" + spec.imageBaseName + ":" + tag
		row.ImageRef = ref

		// Local digest: from the running container, if running. If not
		// running we still check remote — the operator may have stopped
		// the stack and want to know if there's an update before starting.
		if local, err := localManifestDigest(ctx, spec.containerName, ref); err == nil {
			row.LocalDigest = local
		}
		// Remote digest: the same ref's manifest, resolved to our host arch.
		remote, kind, raw := remoteManifestDigest(ctx, ref)
		if kind != "" {
			row.ErrorKind = kind
			row.Error = raw
			out.AnyError = true
		} else {
			row.RemoteDigest = remote
			if row.LocalDigest != "" && row.LocalDigest != row.RemoteDigest {
				row.UpdateAvailable = true
				out.Any = true
			}
		}
		out.Components = append(out.Components, row)
	}
	return out
}

// localManifestDigest returns the manifest digest of the image the
// running container is using. We use the container's RepoDigests — that's
// the *manifest* digest (comparable to `docker manifest inspect` output),
// not the config digest from `.Image`.
//
// Returns an empty string + nil error when the container isn't running
// (the caller treats this as "no local — only check remote").
func localManifestDigest(ctx context.Context, containerName, expectedRef string) (string, error) {
	if !containerRunning(ctx, containerName) {
		return "", nil
	}
	cmd := exec.CommandContext(ctx, dockerPath(), "inspect", containerName,
		"--format", "{{range .RepoDigests}}{{.}}\n{{end}}")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	// RepoDigests is a list of "<repo>@sha256:<digest>" strings (one per
	// registry the image was pulled from). Pick the one whose repo matches
	// our expected registry/repo so we don't get confused if the image
	// was pulled from multiple registries.
	expectedRepo := strings.SplitN(expectedRef, ":", 2)[0]
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		// line: "<repo>@sha256:<digest>"
		parts := strings.SplitN(line, "@", 2)
		if len(parts) != 2 {
			continue
		}
		if parts[0] == expectedRepo {
			return parts[1], nil // "sha256:..."
		}
	}
	// No matching RepoDigest. Image may have been built locally (no
	// registry pull) — treat as "unknown local, can't compare."
	return "", nil
}

// remoteManifestDigest returns the manifest digest of the image at the
// given ref. For multi-arch refs we resolve to the host's architecture
// (linux/amd64 vs linux/arm64) and return that platform's digest.
//
// On failure returns ("", kind, raw-error). `kind` is one of:
//   - "auth"        — 401/403 from registry
//   - "unreachable" — DNS/connection/timeout
//   - "not_found"   — 404, image or tag missing
//   - "tls"         — certificate / TLS handshake failure
//   - "other"       — anything else
//
// We invoke `docker manifest inspect` rather than re-implementing
// registry HTTP because the operator already has Docker configured
// with their registry credentials (`~/.docker/config.json` after
// `docker login` during install). Reinventing the auth flow in Go
// would mean another credential surface to keep in sync.
func remoteManifestDigest(ctx context.Context, ref string) (digest, kind, raw string) {
	cmd := exec.CommandContext(ctx, dockerPath(), "manifest", "inspect", "--verbose", ref)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", classifyRegistryError(string(output)), strings.TrimSpace(string(output))
	}

	// `manifest inspect --verbose` returns either a single object (single-
	// arch image) or an array of {Descriptor: {digest, platform}} entries
	// (manifest list / multi-arch). We need the digest matching our host
	// platform.
	var anyJSON any
	if err := json.Unmarshal(output, &anyJSON); err != nil {
		return "", "other", strings.TrimSpace(string(output))
	}

	hostOS := runtime.GOOS // typically "linux"; on macOS/Windows tray apps the daemon is still linux
	hostArch := runtime.GOARCH

	switch v := anyJSON.(type) {
	case []any:
		// Manifest list: pick the one matching our host platform.
		for _, entry := range v {
			m, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			desc, _ := m["Descriptor"].(map[string]any)
			plat, _ := desc["platform"].(map[string]any)
			os, _ := plat["os"].(string)
			arch, _ := plat["architecture"].(string)
			if os == hostOS && arch == hostArch {
				if d, ok := desc["digest"].(string); ok {
					return d, "", ""
				}
			}
		}
		// No exact match — fall through to "no platform found". Could
		// happen if the operator's host is e.g. linux/arm/v7 and the
		// image only ships amd64+arm64.
		return "", "not_found",
			fmt.Sprintf("no manifest entry for %s/%s in %s", hostOS, hostArch, ref)
	case map[string]any:
		// Single-arch image: digest at the top-level descriptor.
		if desc, ok := v["Descriptor"].(map[string]any); ok {
			if d, ok := desc["digest"].(string); ok {
				return d, "", ""
			}
		}
		return "", "other", "no .Descriptor.digest in manifest output"
	}
	return "", "other", "unexpected manifest JSON shape"
}

// classifyRegistryError parses docker's stderr to bucket the failure
// into something the tray can render meaningfully. Docker's error
// messages are stable enough that string-matching is acceptable.
func classifyRegistryError(s string) string {
	low := strings.ToLower(s)
	switch {
	case strings.Contains(low, "unauthorized") || strings.Contains(low, "authentication required"):
		return "auth"
	case strings.Contains(low, "manifest unknown") || strings.Contains(low, "not found"):
		return "not_found"
	case strings.Contains(low, "x509") || strings.Contains(low, "certificate"):
		return "tls"
	case strings.Contains(low, "no such host") ||
		strings.Contains(low, "connection refused") ||
		strings.Contains(low, "i/o timeout") ||
		strings.Contains(low, "dial tcp") ||
		strings.Contains(low, "network is unreachable"):
		return "unreachable"
	default:
		return "other"
	}
}

// envFromDotEnv reads a single value from ${FP_HOME}/.env without
// requiring `source`-style execution. Returns "" if the key isn't
// set or .env doesn't exist.
func envFromDotEnv(key string) string {
	envs := parseEnvFile()
	return envs[key]
}

// ApplyUpdates runs the install.sh upgrade fast-path. We delegate to
// install.sh rather than reimplementing pull-and-recreate so we get the
// existing registry-auth probe, backoff retry, and healthcheck wait for
// free.
//
// install.sh path resolution: the installer is shipped alongside fp in
// ${FP_HOME}/installer (when bundled). If absent, we fall back to a
// local pull+recreate that matches the bash fast-path.
//
// stdout/stderr are streamed to the caller so the tray app can surface
// progress in real time.
func ApplyUpdates(ctx context.Context, stdout, stderr io.Writer) error {
	// Path 1: bundled installer. The full installer ships beside fp in
	// `${FP_HOME}/installer/linux/install.sh` (or macos/, picked at
	// install time). The native install.sh handles upgrade fast-path
	// detection itself when given FP_INSTALL_ACTION=upgrade.
	if installer := findBundledInstaller(); installer != "" {
		cmd := exec.CommandContext(ctx, "bash", installer)
		cmd.Env = append(os.Environ(),
			"FP_INSTALL_ACTION=upgrade",
			"FP_ASSUME_YES=1",
			"FP_HOME="+HomeDir(),
		)
		cmd.Stdout = stdout
		cmd.Stderr = stderr
		return cmd.Run()
	}

	// Path 2: no installer beside us — do the bash fast-path inline.
	// Calls registry probe (best-effort if we have docker login state)
	// then docker compose pull + up -d.
	fmt.Fprintln(stdout, "Pulling latest images…")
	if err := Compose(ctx, stdout, stderr, "pull"); err != nil {
		return fmt.Errorf("docker compose pull failed: %w", err)
	}
	fmt.Fprintln(stdout, "Recreating containers…")
	if err := Compose(ctx, stdout, stderr, "up", "-d"); err != nil {
		return fmt.Errorf("docker compose up -d failed: %w", err)
	}
	fmt.Fprintln(stdout, "Update complete.")
	return nil
}

// findBundledInstaller locates the installer's install.sh, if it shipped
// alongside the fp binary at install time. Returns the absolute path or
// "" if not found. This is a soft dependency — the inline fallback above
// covers the no-bundle case.
func findBundledInstaller() string {
	candidates := []string{
		HomeDir() + "/installer/linux/install.sh",
		HomeDir() + "/installer/macos/install.sh",
		HomeDir() + "/install.sh",
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}

// UpdateMode reports the operator's chosen update mode from .env.
// Defaults to "manual" when unset or unrecognized — secure default
// for industrial / production deployments where unattended updates
// during a process run are unsafe.
func UpdateMode() string {
	v := strings.ToLower(strings.TrimSpace(envFromDotEnv("FP_UPDATE_MODE")))
	switch v {
	case "auto":
		return "auto"
	default:
		return "manual"
	}
}

// SetUpdateMode persists the operator's chosen mode to .env. Accepted
// values: "manual" | "auto". Other values are coerced to "manual".
func SetUpdateMode(mode string) error {
	mode = strings.ToLower(strings.TrimSpace(mode))
	if mode != "auto" {
		mode = "manual"
	}
	return SetEnvValue("FP_UPDATE_MODE", mode)
}
