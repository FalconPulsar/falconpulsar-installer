// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

// update.go — "is there a newer image available?" + "apply the update"
//
// Design notes:
//   - Source of truth for what's available is whatever Docker registry the
//     operator already pulls from (FP_REGISTRY, defaulting to falconpulsar
//     on Docker Hub). NOT GitHub releases, NOT falconpulsar.com — those
//     fail in private/air-gapped deployments.
//   - Host components (the fp CLI here; each tray app appends its own row
//     client-side) are NOT Docker images, so their "latest" comes from the
//     published installer release version — a shields-endpoint gist kept
//     current by the release pipeline. That probe is best-effort and
//     NON-FATAL by design: air-gapped deployments get an explicit
//     "unknown — no internet access" row instead of a failed check, and
//     the registry-based image comparison above is unaffected.
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
//   - Refresh compose.yml / nginx.conf (full install.sh in upgrade
//     mode handles those when they change). Tray-driven update is
//     for the routine image-only refresh case.
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
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
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

// HostComponentStatus is one row in the "host components" section of the
// update-check result. Host components are binaries installed on the host
// itself (the fp CLI; each tray app appends its own row client-side since
// it knows its own version natively) rather than container images, so
// their update check compares release *versions*, not image digests.
//
// All fields are always present in the JSON (no omitempty): the tray apps
// consume this shape verbatim and an explicit empty string is clearer than
// a missing key.
type HostComponentStatus struct {
	// Name as displayed to the operator. e.g. "fp CLI".
	Name string `json:"name"`
	// Version of the installed binary, e.g. "0.1.4-alpha.28" (no leading "v").
	InstalledVersion string `json:"installed_version"`
	// Latest published installer release version, normalized (leading "v"
	// stripped). Empty when the probe failed; may be "none" when no
	// release has been published yet.
	LatestVersion string `json:"latest_version"`
	// True iff LatestVersion is a real version (non-empty, not "none")
	// AND it differs from the normalized InstalledVersion.
	UpdateAvailable bool `json:"update_available"`
	// Categorized failure: "" on success, "unreachable" when the release
	// version couldn't be fetched (offline / air-gapped / timeout).
	ErrorKind string `json:"error_kind"`
	// Human-readable error message. Empty on success.
	Error string `json:"error"`
}

// UpdateCheckResult is the full result of `fp update --check`.
type UpdateCheckResult struct {
	// Container-image components inspected: core, ui, ai-gateway — plus
	// ai-engine when the stack has the engine enabled (see engineInStack).
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
	// Host binaries checked against the published installer release
	// version. The Go side emits exactly one row ("fp CLI"); each tray
	// app appends its own row client-side from LatestVersion + its own
	// compiled-in version.
	HostComponents []HostComponentStatus `json:"host_components"`
	// True iff any host component has an update available.
	HostAny bool `json:"host_any_update_available"`
	// True iff the installer-release-version probe failed (offline /
	// air-gapped). Non-fatal: the image check above still ran.
	HostProbeFailed bool `json:"host_probe_failed"`
	// Where the operator downloads the installer that updates host
	// components. Constant; included so tray apps don't hardcode it.
	InstallerReleaseURL string `json:"installer_release_url"`
}

// componentSpec describes one component for the update check.
type componentSpec struct {
	displayName   string // e.g. "Core"
	containerName string // e.g. "falconpulsar-core"
	imageBaseName string // e.g. "core" — joined with FP_REGISTRY to form full ref
}

// componentsForCheck returns the components whose update status the
// operator cares about. The three mandatory images are always included;
// the optional AI Engine image is included only when the stack actually
// runs it (see engineInStack) — probing an image the operator never
// enabled would just render a permanent, meaningless "not running" row.
func componentsForCheck() []componentSpec {
	specs := []componentSpec{
		{displayName: "Core", containerName: "falconpulsar-core", imageBaseName: "core"},
		{displayName: "Web UI", containerName: "falconpulsar-ui", imageBaseName: "ui"},
		{displayName: "AI Capabilities", containerName: "falconpulsar-ai-gateway", imageBaseName: "ai-gateway"},
	}
	if engineInStack() {
		specs = append(specs,
			componentSpec{displayName: "AI Engine", containerName: "falconpulsar-ai-engine", imageBaseName: "ai-engine"})
	}
	if copilotInStack() {
		specs = append(specs,
			componentSpec{displayName: "Command Center", containerName: "falconpulsar-copilot", imageBaseName: "copilot"})
	}
	return specs
}

// engineInStack reports whether the optional AI Engine service is part of
// this install's stack: FP_AI_ENGINE_ENABLED=true in .env (the flag the
// installer writes — EngineEnabled covers this), OR "engine" appears in
// the .env's COMPOSE_PROFILES list (comma-separated). The second check
// matters for installs where the profile was enabled by hand without the
// convenience flag — compose runs the engine either way, so the update
// check must cover it either way.
func engineInStack() bool {
	if EngineEnabled() {
		return true
	}
	for _, p := range strings.Split(envFromDotEnv("COMPOSE_PROFILES"), ",") {
		if strings.EqualFold(strings.TrimSpace(p), "engine") {
			return true
		}
	}
	return false
}

// copilotInStack reports whether the optional Command Center service is
// part of this install's stack: FP_COPILOT_ENABLED=true in .env (the flag
// the installer writes — CopilotEnabled covers this), OR "copilot" appears
// in the .env's COMPOSE_PROFILES list. Mirrors engineInStack — see its note.
func copilotInStack() bool {
	if CopilotEnabled() {
		return true
	}
	for _, p := range strings.Split(envFromDotEnv("COMPOSE_PROFILES"), ",") {
		if strings.EqualFold(strings.TrimSpace(p), "copilot") {
			return true
		}
	}
	return false
}

// CheckUpdates inspects each component, returning a populated
// UpdateCheckResult. Network-bound (one `docker manifest inspect` per
// component, plus one HTTPS GET for the installer release version);
// call from a context with a reasonable timeout.
//
// fpVersion is the compiled-in version of the running fp binary
// (cli.Version). It's plumbed in as a parameter because the cli package
// imports this one — importing it back for the constant would be a cycle,
// and duplicating the value here would drift from scripts/sync-version.sh.
//
// On registry probe failure for a single component we don't abort the
// whole check — we record the error per-component and continue. The
// tray UI can render "core: connectivity error; ui: up to date" rather
// than going all-or-nothing. The host-component probe is equally
// non-fatal (see checkHostComponents).
func CheckUpdates(ctx context.Context, fpVersion string) UpdateCheckResult {
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

	checkHostComponents(ctx, fpVersion, &out)
	return out
}

// installerVersionURL is the shields-endpoint gist the release pipeline
// keeps pointed at the newest installer release. Payload shape:
//
//	{"schemaVersion":1,"label":"release","message":"v0.1.4-alpha.28","color":"blue"}
//
// The version is .message — possibly "v"-prefixed, possibly "none" when
// no release has been published yet.
const installerVersionURL = "https://gist.githubusercontent.com/icterusicterus/894cadcfc17cc70a488bdfe8917f5df2/raw/release-installer.json"

// installerReleaseURL is where the operator downloads the installer that
// updates host components (fp CLI, tray apps).
const installerReleaseURL = "https://github.com/FalconPulsar/falconpulsar-installer/releases"

// checkHostComponents fills the host-component fields of an
// UpdateCheckResult: exactly one row for the fp CLI, compared against the
// published installer release version. Tray apps append their own rows
// client-side using LatestVersion from the JSON.
//
// Air-gap contract: on any fetch failure the row is still emitted, with
// ErrorKind "unreachable" and a human-readable message, and
// HostProbeFailed is set — the check as a whole NEVER fails because the
// host has no internet access.
func checkHostComponents(ctx context.Context, fpVersion string, out *UpdateCheckResult) {
	out.InstallerReleaseURL = installerReleaseURL

	row := HostComponentStatus{
		Name:             "fp CLI",
		InstalledVersion: fpVersion,
	}
	latest, err := fetchLatestInstallerVersion(ctx)
	if err != nil {
		row.ErrorKind = "unreachable"
		row.Error = "unknown — no internet access"
		out.HostProbeFailed = true
	} else {
		row.LatestVersion = normalizeVersion(latest)
		if isRealVersion(latest) && normalizeVersion(fpVersion) != normalizeVersion(latest) {
			row.UpdateAvailable = true
			out.HostAny = true
		}
	}
	out.HostComponents = append(out.HostComponents, row)
}

// fetchLatestInstallerVersion GETs the shields-endpoint gist and returns
// its .message field, trimmed but otherwise raw (callers normalize).
// Plain net/http on purpose — no Docker dependency, works even when the
// daemon is down. Hard 5-second budget so a flaky network can't stall
// the whole update check.
func fetchLatestInstallerVersion(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, "GET", installerVersionURL, nil)
	if err != nil {
		return "", err
	}
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("installer version endpoint returned HTTP %d", resp.StatusCode)
	}
	// The payload is ~100 bytes; the limit is pure paranoia against a
	// captive portal serving us an HTML login page.
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return "", err
	}
	var payload struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return "", fmt.Errorf("parse installer version payload: %w", err)
	}
	msg := strings.TrimSpace(payload.Message)
	if msg == "" {
		return "", fmt.Errorf("installer version payload has empty message")
	}
	return msg, nil
}

// normalizeVersion strips whitespace and a leading "v" so that
// "v0.1.4-alpha.28" and "0.1.4-alpha.28" compare equal. The gist's
// .message carries the "v" (it mirrors the git tag); the compiled-in
// cli.Version does not.
func normalizeVersion(v string) string {
	return strings.TrimPrefix(strings.TrimSpace(v), "v")
}

// isRealVersion reports whether a fetched version string names an actual
// release: non-empty after normalization and not the "none" placeholder
// the badge shows before the first published release. A non-real latest
// never counts as an available update.
func isRealVersion(v string) bool {
	n := normalizeVersion(v)
	return n != "" && !strings.EqualFold(n, "none")
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
			// Waive install.sh's admin-auth gate: FP_ASSUME_YES does NOT
			// cover it (only the Core-unreachable branch), so a headless
			// apply would die at the interactive password prompt. Upgrades
			// don't require re-auth anywhere else (tray Apply Now, the GUI
			// installers as of alpha.47/48) — keep this path consistent.
			"FP_FORCE=1",
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

	// Gateway prerequisites (mandatory component). FP_GATEWAY_SECRET and
	// gateway.yaml are created only when missing — the secret is NEVER
	// regenerated, since rotating it would orphan provider keys encrypted
	// under the old value.
	if err := EnsureGatewaySecret(); err != nil {
		return err
	}
	EnsureGatewayConfig()
	if err := ensureGatewayDataDir(); err != nil {
		return err
	}
	// Legacy .env compat (pre-mandatory-gateway installs): nothing reads
	// FP_AI_GATEWAY_ENABLED anymore, but older fp/tray binaries do — force
	// it true so they never see the stack as AI-disabled.
	_ = SetEnvValue("FP_AI_GATEWAY_ENABLED", "true")
	// Anchor the gateway.yaml mount to the stack dir — compose's default
	// resolves relative to FP_DATA_DIR, which breaks with a custom
	// --data-dir (Docker would create a directory at the missing source).
	// Only set when absent so an operator-pinned value is preserved.
	if envFromDotEnv("FP_GATEWAY_CONFIG") == "" {
		_ = SetEnvValue("FP_GATEWAY_CONFIG", filepath.Join(HomeDir(), "gateway.yaml"))
	}

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

	// Health-gate the gateway like the platform installers do. Runs
	// unconditionally: gateway liveness does not require FP_API_KEY
	// (compose passes `FP_API_KEY: ${FP_API_KEY:-}`), and a crash-looping
	// gateway must fail the update rather than pass silently. 180s matches
	// fp_wait_for_gateway_ready's contract in shared/lib/bootstrap.sh.
	fmt.Fprintln(stdout, "Waiting for the AI gateway to become healthy…")
	if !waitGatewayHealthy(ctx, 180) {
		return fmt.Errorf("AI gateway did not report healthy — check `docker logs falconpulsar-ai-gateway`")
	}
	if !HasGatewayToken() {
		// Minting the service credential needs admin credentials, which
		// this non-interactive path cannot prompt for — the platform
		// installer owns that bootstrap.
		fmt.Fprintln(stdout, "")
		fmt.Fprintln(stdout, "The AI gateway service credential (FP_API_KEY) is missing from this")
		fmt.Fprintln(stdout, "install's .env. Re-run the FalconPulsar installer for your platform")
		fmt.Fprintln(stdout, "to complete the AI setup.")
	}

	fmt.Fprintln(stdout, "Update complete.")
	return nil
}

// ensureGatewayDataDir makes sure the gateway's bind-mounted data directory
// exists before `docker compose up -d`. When the mount source is missing the
// Docker engine auto-creates it root-owned, and the gateway (running as
// FP_UID:FP_GID) cannot write its databases and crash-loops. Mirrors the
// data-dir provisioning in fp_try_upgrade_fastpath (shared/lib/existing.sh):
// resolve compose.yml's default when .env has no explicit
// FP_GATEWAY_DATA_DIR, create the directory when missing, and best-effort
// chown it to FP_UID:FP_GID from .env.
func ensureGatewayDataDir() error {
	env := parseEnvFile()
	dir := env["FP_GATEWAY_DATA_DIR"]
	if dir == "" {
		if dataDir := env["FP_DATA_DIR"]; dataDir != "" {
			dir = filepath.Join(dataDir, "..", "ai-gateway-data")
		}
	}
	if dir == "" {
		return nil
	}
	if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
		return nil
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("create AI gateway data directory %s: %w", dir, err)
	}
	if uid, err := strconv.Atoi(env["FP_UID"]); err == nil {
		if gid, err := strconv.Atoi(env["FP_GID"]); err == nil {
			_ = os.Chown(dir, uid, gid)
		}
	}
	return nil
}

// waitGatewayHealthy polls the AI gateway's /health endpoint at
// FP_GATEWAY_BIND:FP_GATEWAY_PORT (defaults 127.0.0.1:7436, honoring .env
// overrides) until it answers 200 or maxSeconds elapse. Mirrors
// fp_wait_for_gateway_ready in shared/lib/bootstrap.sh so `fp update
// --apply` gates on the same signal as the platform installers.
func waitGatewayHealthy(ctx context.Context, maxSeconds int) bool {
	port := strings.TrimSpace(envFromDotEnv("FP_GATEWAY_PORT"))
	if _, err := strconv.Atoi(port); err != nil {
		port = "7436"
	}
	// Compose publishes on ${FP_GATEWAY_BIND:-127.0.0.1}; a wildcard bind
	// is still reachable via loopback, so probe it there.
	host := strings.TrimSpace(envFromDotEnv("FP_GATEWAY_BIND"))
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	healthURL := fmt.Sprintf("http://%s/health", net.JoinHostPort(host, port))
	deadline := time.Now().Add(time.Duration(maxSeconds) * time.Second)
	client := &http.Client{Timeout: 3 * time.Second}
	for time.Now().Before(deadline) {
		req, err := http.NewRequestWithContext(ctx, "GET", healthURL, nil)
		if err != nil {
			return false
		}
		if resp, err := client.Do(req); err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == 200 {
				return true
			}
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(2 * time.Second):
		}
	}
	return false
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
