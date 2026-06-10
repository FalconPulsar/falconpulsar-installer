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
	"fmt"
	"io"
	"os"
	"os/exec"
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

// localManifestDigest returns the manifest digest of the locally-cached
// image that the operator's stack would use. We need the *manifest*
// (a.k.a. index) digest — comparable to what `docker buildx imagetools
// inspect` returns for the remote ref. RepoDigests lives on the image
// object, not the container.
//
// Two lookup paths, tried in order:
//
//  1. **Container running** → use the container's actual image to
//     account for "container is running an older image even though
//     :latest has moved". We do `docker inspect <container>
//     --format '{{.Image}}'` to get the image SHA, then
//     `docker inspect --type=image <sha>` to get RepoDigests.
//
//  2. **Container stopped (or never started)** → fall back to looking
//     up the image by the resolved ref directly:
//     `docker inspect --type=image <expectedRef>`. This catches the
//     "operator stopped the stack, image still cached locally,
//     update is available" case. Without this, the check silently
//     reports "container not running" and misses the update.
//
// We then filter by the expected repo prefix so we don't pick a digest
// from an unrelated registry if the same image happens to have been
// pulled from multiple sources.
//
// Returns an empty string + nil error only when neither path yielded a
// digest matching the expected repo — that's the "image was built
// locally, never pulled, so we can't compare against a remote" case.
// The caller renders that as "image not pulled" rather than as a
// confident "up to date."
func localManifestDigest(ctx context.Context, containerName, expectedRef string) (string, error) {
	expectedRepo := strings.SplitN(expectedRef, ":", 2)[0]

	// Path 1: running container's actual image.
	if containerRunning(ctx, containerName) {
		cmd := dockerCmd(ctx, "inspect", containerName,
			"--format", "{{.Image}}")
		out, err := cmd.Output()
		if err == nil {
			imageSHA := strings.TrimSpace(string(out))
			if imageSHA != "" {
				if d := repoDigestFor(ctx, imageSHA, expectedRepo); d != "" {
					return d, nil
				}
			}
		}
	}

	// Path 2: locally-cached image at the resolved ref. Used when the
	// stack is stopped, or when path 1 didn't yield a usable digest
	// (e.g. the running container's image is from a different repo
	// than FP_REGISTRY would resolve to).
	if d := repoDigestFor(ctx, expectedRef, expectedRepo); d != "" {
		return d, nil
	}

	// No matching RepoDigest anywhere. Image hasn't been pulled, or
	// was built locally with no registry tag. Treat as "no local
	// digest known."
	return "", nil
}

// repoDigestFor inspects a Docker image (by SHA or ref) and returns
// the first RepoDigest whose repo matches `expectedRepo`. Returns "" on
// any failure or no match. Used by localManifestDigest's two lookup paths.
func repoDigestFor(ctx context.Context, imageRefOrSHA, expectedRepo string) string {
	cmd := dockerCmd(ctx, "inspect", "--type=image", imageRefOrSHA,
		"--format", "{{range .RepoDigests}}{{.}}\n{{end}}")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
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
			return parts[1] // "sha256:..."
		}
	}
	return ""
}

// remoteManifestDigest returns the digest of the image-or-manifest-list
// at the given ref. We compare this against the local RepoDigest, which
// is also the manifest-list digest (Docker stores the index digest, not
// per-arch sub-manifest digests, in RepoDigests when an image is pulled
// from a multi-arch reference).
//
// We use `docker buildx imagetools inspect --format '{{.Manifest.Digest}}'`
// because:
//   - It returns the manifest-list digest directly, which matches what
//     local RepoDigests stores (apples-to-apples comparison).
//   - `docker manifest inspect --verbose` instead returns per-arch
//     sub-manifest entries — useful for picking a platform but doesn't
//     match the local digest format, leading to false "update available"
//     reports on multi-arch images.
//   - It works with the operator's existing Docker auth state
//     (~/.docker/config.json), no need to reimplement registry HTTP.
//
// On failure returns ("", kind, raw-error). `kind` is one of:
//   - "auth"        — 401/403 from registry
//   - "unreachable" — DNS/connection/timeout
//   - "not_found"   — 404, image or tag missing
//   - "tls"         — certificate / TLS handshake failure
//   - "other"       — anything else
func remoteManifestDigest(ctx context.Context, ref string) (digest, kind, raw string) {
	cmd := dockerCmd(ctx, "buildx", "imagetools", "inspect",
		"--format", "{{.Manifest.Digest}}", ref)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", classifyRegistryError(string(output)), strings.TrimSpace(string(output))
	}
	// imagetools prints either a bare digest line (success) or a multi-line
	// error blob (failure already handled above). Trim and return.
	d := strings.TrimSpace(string(output))
	if !strings.HasPrefix(d, "sha256:") {
		return "", "other",
			fmt.Sprintf("unexpected output from imagetools inspect: %q", d)
	}
	return d, "", ""
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
		// Use dockerEnv() so install.sh's `docker compose pull` resolves
		// docker-credential-desktop even when /usr/local/bin's symlink is
		// stale (a common Docker Desktop upgrade artifact). Without this
		// the apply path fails with "executable file not found in $PATH"
		// at the pull step.
		cmd.Env = append(dockerEnv(),
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
	//
	// Snapshot the image IDs each compose service currently resolves to
	// BEFORE the pull. These IDs form the cleanup whitelist: after the
	// upgrade succeeds, any of these that are now fully untagged (the
	// pull displaced them with a newer version) will be removed. This
	// mirrors fp_try_upgrade_fastpath in shared/lib/existing.sh so both
	// the bundled-installer path and the inline fallback behave the same.
	//
	// Registry-agnostic by design: only image IDs that were "ours" before
	// the pull are candidates, and only when they end up untagged. Cannot
	// accidentally touch unrelated images, doesn't depend on labels being
	// preserved through mirrors, and respects any manual tags the operator
	// may have on the same image ID.
	prevImageIDs := SnapshotComposeImageIDs(ctx)

	fmt.Fprintln(stdout, "Pulling latest images…")
	if err := Compose(ctx, stdout, stderr, "pull"); err != nil {
		return fmt.Errorf("docker compose pull failed: %w", err)
	}
	fmt.Fprintln(stdout, "Recreating containers…")
	if err := Compose(ctx, stdout, stderr, "up", "-d"); err != nil {
		return fmt.Errorf("docker compose up -d failed: %w", err)
	}

	// Best-effort cleanup. Errors are not surfaced — the upgrade itself
	// succeeded; failing to clean up old images is cosmetic, not fatal.
	removed := RemoveOrphanedImages(ctx, prevImageIDs)
	if removed > 0 {
		fmt.Fprintf(stdout, "Removed %d previous image(s).\n", removed)
	}

	fmt.Fprintln(stdout, "Update complete.")

	// Legacy opt-out installs: the Workspace now ships commands and standing
	// watches that REQUIRE the gateway. Surface a one-screen offer here —
	// this output also streams through the macOS menu-bar and Windows tray
	// update panels, so every surface sees it.
	if !AIGatewayEnabled() {
		fmt.Fprintln(stdout, "")
		fmt.Fprintln(stdout, "NEW IN THIS RELEASE")
		fmt.Fprintln(stdout, "  Workspace commands and standing watches require the FalconPulsar")
		fmt.Fprintln(stdout, "  Gateway, which is currently disabled on this install.")
		fmt.Fprintln(stdout, "  Enable it with:  fp ai enable")
		fmt.Fprintln(stdout, "  (No API key needed — AI models stay optional in ConfigHub.)")
	}
	return nil
}

// SnapshotComposeImageIDs returns the image ID each compose service
// currently resolves to. Used by ApplyUpdates as the cleanup whitelist
// across the pull+recreate cycle. Errors return an empty slice so the
// upgrade itself isn't blocked by a cleanup-prep failure.
func SnapshotComposeImageIDs(ctx context.Context) []string {
	// `docker compose config --services` is the canonical way to list
	// services without parsing compose.yml ourselves.
	cmd := exec.CommandContext(ctx, dockerPath(),
		append(append([]string{"compose"}, composeProfileArgs()...), "config", "--services")...,
	)
	cmd.Dir = HomeDir()
	cmd.Env = dockerEnv()
	svcOut, err := cmd.Output()
	if err != nil {
		return nil
	}
	services := strings.Fields(strings.TrimSpace(string(svcOut)))

	ids := make([]string, 0, len(services))
	for _, svc := range services {
		// `docker compose images -q <svc>` returns the image ID (sha256:...)
		// of the service's current image, even if the service isn't running.
		imgCmd := exec.CommandContext(ctx, dockerPath(),
			append(append([]string{"compose"}, composeProfileArgs()...), "images", "-q", svc)...,
		)
		imgCmd.Dir = HomeDir()
		imgCmd.Env = dockerEnv()
		imgOut, err := imgCmd.Output()
		if err != nil {
			continue
		}
		// Take the first line — `docker compose images -q` emits one ID
		// per matching container; we just need the image reference.
		for _, line := range strings.Split(strings.TrimSpace(string(imgOut)), "\n") {
			id := strings.TrimSpace(line)
			if id != "" {
				ids = append(ids, id)
				break
			}
		}
	}
	return ids
}

// RemoveOrphanedImages removes any of the supplied image IDs that are now
// fully untagged (i.e. were displaced by a fresh pull). Images that still
// have any tag pointing to them are skipped — that protects both the
// "pull was a no-op" case (ID still tagged) and the "operator has a
// manual backup tag" case (other tag still references the same ID).
// Returns the count actually removed. All errors are swallowed: cleanup
// is best-effort.
func RemoveOrphanedImages(ctx context.Context, ids []string) int {
	seen := make(map[string]bool, len(ids))
	removed := 0
	for _, id := range ids {
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true

		// Check tag count via inspect. Output is just an integer.
		inspectCmd := exec.CommandContext(ctx, dockerPath(),
			"image", "inspect", id, "--format", "{{len .RepoTags}}",
		)
		inspectCmd.Env = dockerEnv()
		out, err := inspectCmd.Output()
		if err != nil {
			// Image already gone or otherwise unreadable — nothing to do.
			continue
		}
		if strings.TrimSpace(string(out)) != "0" {
			// Still has tags — either pull was a no-op or operator has
			// a manual tag. Leave it alone.
			continue
		}

		rmCmd := exec.CommandContext(ctx, dockerPath(), "image", "rm", id)
		rmCmd.Env = dockerEnv()
		if err := rmCmd.Run(); err == nil {
			removed++
		}
	}
	return removed
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
