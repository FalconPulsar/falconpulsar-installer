// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

// Package actions wraps the docker compose operations and filesystem helpers
// that both the CLI subcommands and the TUI need.
package actions

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
	"unicode/utf8"
)

// HomeDir resolves the stack directory.
//
// Resolution order, in priority:
//  1. FP_HOME env var (explicit override -- useful for debugging).
//  2. $HOME/falconpulsar if it contains a real install (compose.yml or .env).
//     This is the macOS model AND the new Linux/WSL per-user model.
//  3. On Linux only: /home/falconpulsar if it contains a real install.
//     That's the legacy service-user path. We probe it so `fp` still works
//     for users upgrading from a pre-refactor install.
//  4. Otherwise: $HOME/falconpulsar (unconditional default). Writes that
//     happen here will fail cleanly if the directory doesn't exist, which
//     is the right signal ("no install here").
func HomeDir() string {
	if override := os.Getenv("FP_HOME"); override != "" {
		return override
	}

	hasInstall := func(dir string) bool {
		for _, marker := range []string{"compose.yml", ".env"} {
			if _, err := os.Stat(filepath.Join(dir, marker)); err == nil {
				return true
			}
		}
		return false
	}

	if h, err := os.UserHomeDir(); err == nil {
		userStack := filepath.Join(h, "falconpulsar")
		if hasInstall(userStack) {
			return userStack
		}
	}

	if runtime.GOOS == "linux" && hasInstall("/home/falconpulsar") {
		return "/home/falconpulsar"
	}

	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, "falconpulsar")
	}
	return "/home/falconpulsar"
}

func dockerPath() string {
	for _, p := range []string{
		"/usr/local/bin/docker",
		"/opt/homebrew/bin/docker",
		"/Applications/Docker.app/Contents/Resources/bin/docker",
		"/usr/bin/docker",
	} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	if p, err := exec.LookPath("docker"); err == nil {
		return p
	}
	return "docker"
}

// dockerEnv returns os.Environ() with PATH augmented to find Docker
// Desktop's bundled credential helpers on macOS, working around a common
// trip-hazard: Docker Desktop's installer drops a symlink in
// /usr/local/bin/docker-credential-desktop that frequently goes stale
// across upgrades (e.g., points to /Volumes/Docker/... after Docker.app
// has been moved to /Applications). When the symlink is dangling,
// every docker call that needs registry credentials —
// `buildx imagetools inspect`, `compose pull`, `pull` — fails with
// "executable file not found in $PATH". We pre-pend Docker.app's bundled
// bin dir to PATH so helpers resolve to the canonical binary regardless
// of symlink state.
//
// On non-darwin hosts, or when /Applications/Docker.app isn't present,
// returns os.Environ() unchanged. Use this anywhere we spawn a docker
// process or a process that itself spawns docker (e.g. install.sh).
func dockerEnv() []string {
	env := os.Environ()
	if runtime.GOOS != "darwin" {
		return env
	}
	const dockerBin = "/Applications/Docker.app/Contents/Resources/bin"
	if _, err := os.Stat(dockerBin); err != nil {
		return env
	}
	for i, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			env[i] = "PATH=" + dockerBin + ":" + strings.TrimPrefix(kv, "PATH=")
			return env
		}
	}
	return append(env, "PATH="+dockerBin)
}

// dockerCmd returns an exec.Cmd configured to run the docker CLI with
// the augmented PATH from dockerEnv(). See dockerEnv for rationale.
func dockerCmd(ctx context.Context, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, dockerPath(), args...)
	cmd.Env = dockerEnv()
	return cmd
}

// HasGatewayToken checks if FP_API_KEY is already present in .env (meaning
// the gateway token was bootstrapped previously — no need to re-auth).
func HasGatewayToken() bool {
	data, err := os.ReadFile(filepath.Join(HomeDir(), ".env"))
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "FP_API_KEY=") {
			val := strings.TrimPrefix(line, "FP_API_KEY=")
			return val != ""
		}
	}
	return false
}

// EnsureGatewaySecret makes sure FP_GATEWAY_SECRET exists in .env (SEC-003:
// the key the gateway uses to encrypt LLM provider API keys at rest). It is
// generated once and NEVER rotated implicitly — rotating would orphan
// previously-encrypted provider keys. Returns nil if already present.
func EnsureGatewaySecret() error {
	data, err := os.ReadFile(filepath.Join(HomeDir(), ".env"))
	if err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "FP_GATEWAY_SECRET=") &&
				strings.TrimPrefix(line, "FP_GATEWAY_SECRET=") != "" {
				return nil // present — never overwrite
			}
		}
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return fmt.Errorf("generate gateway secret: %w", err)
	}
	return SetEnvValue("FP_GATEWAY_SECRET", hex.EncodeToString(buf))
}

// envFileMode returns the existing .env file mode, or 0600 if the file
// doesn't exist / can't be stat'd. We preserve whatever the installer set
// (Linux: 0640 falconpulsar:docker, macOS: 0600 user:staff) rather than
// clobbering it on every write.
func envFileMode(path string) os.FileMode {
	info, err := os.Stat(path)
	if err != nil {
		return 0600
	}
	return info.Mode().Perm()
}

// SetEnvValue writes or updates a key=value line in ~/falconpulsar/.env.
func SetEnvValue(key, value string) error {
	envPath := filepath.Join(HomeDir(), ".env")
	data, err := os.ReadFile(envPath)
	if err != nil {
		return err
	}
	lines := strings.Split(string(data), "\n")
	found := false
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), key+"=") {
			lines[i] = key + "=" + value
			found = true
			break
		}
	}
	if !found {
		lines = append(lines, key+"="+value)
	}
	return os.WriteFile(envPath, []byte(strings.Join(lines, "\n")), envFileMode(envPath))
}

// parseEnvFile reads .env into a map. Doesn't interpret quoting — good enough
// for the few keys we care about (registry/version pins, FP_*_PORT remaps,
// FP_UPDATE_MODE).
func parseEnvFile() map[string]string {
	result := make(map[string]string)
	data, err := os.ReadFile(filepath.Join(HomeDir(), ".env"))
	if err != nil {
		return result
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if i := strings.Index(line, "="); i > 0 {
			key := strings.TrimSpace(line[:i])
			val := strings.TrimSpace(line[i+1:])
			val = strings.TrimPrefix(val, `"`)
			val = strings.TrimSuffix(val, `"`)
			val = strings.TrimPrefix(val, `'`)
			val = strings.TrimSuffix(val, `'`)
			result[key] = val
		}
	}
	return result
}

// ContainerInfo is per-container metadata read from OCI image labels via
// `docker inspect`. Used by `fp about` (and mirrored by the macOS menu-bar
// and Windows tray About panels) to show real per-component versions
// instead of meaningless "latest" image tags.
//
// Version comes from org.opencontainers.image.version. When that label is
// missing or carries a non-semver placeholder ("main", "master", "develop",
// "latest", "HEAD") -- a common bug on upstream image builds where the
// label is set to the source branch instead of the release tag -- we fall
// back to a 7-char prefix of the image digest. Always available,
// cryptographically meaningful, unambiguous.
//
// Revision is the first 7 chars of org.opencontainers.image.revision (the
// upstream git SHA). Empty if the label is missing.
type ContainerInfo struct {
	Version  string // "0.3.7" or "a03db27" (digest fallback)
	Revision string // "0d8f4a2" (short SHA) or empty
}

// DisplayString formats the info for human consumption:
//
//	"0.3.7 (a03db27)" - both label and revision present
//	"0.3.7"           - only label resolved
//	"a03db27"         - digest fallback (no useful version label)
//	"n/a"             - container not running / not found
func (c ContainerInfo) DisplayString() string {
	if c.Version == "n/a" {
		return "n/a"
	}
	if c.Revision == "" {
		return c.Version
	}
	if c.Version == c.Revision {
		// Don't print the rev twice when version IS the digest fallback.
		return c.Version
	}
	return fmt.Sprintf("%s (%s)", c.Version, c.Revision)
}

// GetContainerInfo runs `docker inspect` against a container name and
// returns the parsed OCI metadata. See ContainerInfo for the fallback
// semantics. Returns Version="n/a" when the container isn't running.
func GetContainerInfo(ctx context.Context, name string) ContainerInfo {
	// One inspect call returns all 4 fields tab-separated. The 'index'
	// template function returns "" for missing keys, so older or
	// upstream-mislabelled images don't error -- they just route into
	// the digest-fallback branch.
	const fmtTpl = `{{ index .Config.Labels "org.opencontainers.image.version" }}` + "\t" +
		`{{ index .Config.Labels "org.opencontainers.image.revision" }}` + "\t" +
		`{{ index .Config.Labels "org.opencontainers.image.created" }}` + "\t" +
		`{{ .Image }}`

	cmd := dockerCmd(ctx, "inspect", "--format", fmtTpl, name)
	out, err := cmd.Output()
	if err != nil {
		return ContainerInfo{Version: "n/a"}
	}
	// Trim ONLY trailing newlines, NOT all whitespace. Containers without
	// any OCI labels emit "\t\t\t<imageId>" — strings.TrimSpace would
	// strip those leading tabs, collapsing 4 fields into 1 and putting
	// the image digest where labelVer is supposed to be. Subtle.
	output := strings.TrimRight(string(out), "\n\r")
	if output == "" {
		return ContainerInfo{Version: "n/a"}
	}

	parts := strings.Split(output, "\t")
	get := func(i int) string {
		if i < len(parts) {
			return parts[i]
		}
		return ""
	}
	labelVer := get(0)
	labelRev := get(1)
	imageId := get(3)

	placeholders := map[string]bool{
		"":        true,
		"main":    true,
		"master":  true,
		"develop": true,
		"latest":  true,
		"HEAD":    true,
	}

	var version string
	if placeholders[labelVer] {
		id := strings.TrimPrefix(imageId, "sha256:")
		if id == "" {
			version = "n/a"
		} else {
			n := 7
			if len(id) < n {
				n = len(id)
			}
			version = id[:n]
		}
	} else {
		version = labelVer
	}

	revision := ""
	if labelRev != "" {
		n := 7
		if len(labelRev) < n {
			n = len(labelRev)
		}
		revision = labelRev[:n]
	}

	return ContainerInfo{Version: version, Revision: revision}
}

// GetComposeVersion returns the Docker Compose plugin version (e.g.
// "v2.21.0"). Falls back to "v2" if the lookup fails.
func GetComposeVersion(ctx context.Context) string {
	out, err := dockerCmd(ctx, "compose", "version", "--short").Output()
	if err != nil {
		return "v2"
	}
	v := strings.TrimSpace(string(out))
	if v == "" {
		return "v2"
	}
	if strings.HasPrefix(v, "v") {
		return v
	}
	return "v" + v
}

// composeProfileArgs returns the --profile flags for every compose call.
// Legacy compose compat (pre-mandatory-gateway installs): fp runs against
// the *installed* compose.yml, which on older stacks still gates ai-gateway
// behind the "ai" profile. Unknown profile names are a no-op in Compose v2,
// so passing the flag unconditionally is harmless on current stacks.
//
// When the optional AI Engine is enabled we must ALSO pass its "engine"
// profile: a --profile flag on the CLI *overrides* COMPOSE_PROFILES from
// .env, so without re-asserting it here every compose call (start/stop/
// restart/logs/uninstall) would silently skip falconpulsar-ai-engine.
func composeProfileArgs() []string {
	args := []string{"--profile", "ai"}
	if EngineEnabled() {
		args = append(args, "--profile", "engine")
	}
	if CopilotEnabled() {
		args = append(args, "--profile", "copilot")
	}
	return args
}

// Compose runs `docker compose <args...>` in the stack directory. Also ensures
// gateway.yaml exists as a file before any compose command to prevent Docker
// from creating a directory at that path.
func Compose(ctx context.Context, stdout, stderr io.Writer, args ...string) error {
	EnsureGatewayConfig()
	base := []string{"compose"}
	base = append(base, composeProfileArgs()...)
	base = append(base, args...)
	cmd := exec.CommandContext(ctx, dockerPath(), base...)
	cmd.Dir = HomeDir()
	cmd.Env = dockerEnv()
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if stdout != nil && stderr != nil {
		cmd.Stdin = os.Stdin
	}
	return cmd.Run()
}

// Status struct describes the live state of the four services (plus the
// optional AI Engine when the install enables it).
type Status struct {
	Core       bool
	UI         bool
	Gateway    bool
	APIHealthy bool
	// Engine is the falconpulsar-ai-engine container state. Only
	// meaningful when EngineEnabled is true — disabled installs never
	// probe it and it stays false.
	Engine bool
	// EngineEnabled mirrors FP_AI_ENGINE_ENABLED at poll time so the
	// aggregate and the status renderers agree on whether the engine
	// participates.
	EngineEnabled bool
	// Copilot is the falconpulsar-copilot (Command Center) container
	// state. Only meaningful when CopilotEnabled is true — disabled
	// installs never probe it and it stays false.
	Copilot bool
	// CopilotEnabled mirrors FP_COPILOT_ENABLED at poll time so the
	// aggregate and the status renderers agree on whether Command Center
	// participates.
	CopilotEnabled bool
}

// Aggregate returns a single word describing overall status. All three
// services (core, ui, ai-gateway) plus a healthy REST API are required
// for "running" — a stopped gateway yields "partial". When the optional
// AI Engine is enabled it participates too — a stopped engine likewise
// yields "partial".
func (s Status) Aggregate() string {
	expected := 3 // core + ui + ai-gateway
	running := 0
	if s.Core {
		running++
	}
	if s.UI {
		running++
	}
	if s.Gateway {
		running++
	}
	if s.EngineEnabled {
		expected++ // optional ai-engine counts only when enabled
		if s.Engine {
			running++
		}
	}
	if s.CopilotEnabled {
		expected++ // optional Command Center counts only when enabled
		if s.Copilot {
			running++
		}
	}
	if running == expected && s.APIHealthy {
		return "running"
	}
	if running == 0 {
		return "stopped"
	}
	return "partial"
}

// Poll checks container + API health. Non-blocking for each individual call.
func Poll(ctx context.Context) Status {
	var st Status
	st.Core = containerRunning(ctx, "falconpulsar-core")
	st.UI = containerRunning(ctx, "falconpulsar-ui")
	st.Gateway = containerRunning(ctx, "falconpulsar-ai-gateway")
	// Re-read the flag on every poll so an .env edit shows up without a
	// console restart. Disabled installs skip the docker probe entirely.
	st.EngineEnabled = EngineEnabled()
	if st.EngineEnabled {
		st.Engine = containerRunning(ctx, "falconpulsar-ai-engine")
	}
	st.CopilotEnabled = CopilotEnabled()
	if st.CopilotEnabled {
		st.Copilot = containerRunning(ctx, "falconpulsar-copilot")
	}
	cli := NewAPIClient()
	cli.HTTP.Timeout = 2 * time.Second
	if ok, err := cli.Health(ctx); err == nil && ok {
		st.APIHealthy = true
	}
	return st
}

func containerRunning(ctx context.Context, name string) bool {
	cmd := exec.CommandContext(ctx, dockerPath(), "ps", "--filter", "name="+name, "--filter", "status=running", "-q")
	out, err := cmd.Output()
	return err == nil && len(strings.TrimSpace(string(out))) > 0
}

// reservedContainerNames are the fixed container_name values the stack's
// compose.yml claims. Mirrors FP_RESERVED_CONTAINER_NAMES in
// shared/lib/existing.sh — keep the two lists in step.
var reservedContainerNames = []string{
	"falconpulsar-core",
	"falconpulsar-ui",
	"falconpulsar-ai-gateway",
	"falconpulsar-ai-engine",
	"falconpulsar-copilot",
}

// DiagnoseNameConflicts explains a `docker compose up` failure caused by
// another container already holding one of our fixed container_names.
//
// Docker container names are GLOBAL, not per-compose-project, so a container
// from an unrelated project (a developer running the app's own compose file,
// say) silently blocks the stack — and Compose reports only an opaque
// "container name is already in use by container <id>" with no hint as to
// who owns it or what to do.
//
// Returns "" when no conflict is found, so the caller can fall back to the
// raw error. Deliberately DIAGNOSES ONLY: a squatter that belongs to another
// compose project may be someone's working environment, and force-removing it
// would destroy their state. (The bash installer removes only *label-less*
// containers, which is a different, genuinely-orphaned case.)
func DiagnoseNameConflicts(ctx context.Context) string {
	ours := composeProjectName(ctx)
	var b strings.Builder
	for _, name := range reservedContainerNames {
		project, configFile, ok := containerOwner(ctx, name)
		if !ok || project == ours {
			continue
		}
		if b.Len() == 0 {
			b.WriteString("\nA container is already using a name this stack needs:\n")
		}
		if project == "" {
			fmt.Fprintf(&b, "\n  %s — not managed by any compose project (started with `docker run`?)\n", name)
			fmt.Fprintf(&b, "      Remove it, then retry:  docker rm -f %s\n", name)
			continue
		}
		fmt.Fprintf(&b, "\n  %s — owned by compose project %q\n", name, project)
		if configFile != "" {
			fmt.Fprintf(&b, "      defined in: %s\n", configFile)
		}
		fmt.Fprintf(&b, "      That is a different stack, so it is NOT removed automatically.\n")
		fmt.Fprintf(&b, "      Free the name (keeps the container):  docker stop %s && docker rename %s %s-old\n", name, name, name)
		fmt.Fprintf(&b, "      Or discard it entirely:               docker rm -f %s\n", name)
	}
	if b.Len() > 0 {
		b.WriteString("\nThen re-run the update.\n")
	}
	return b.String()
}

// containerOwner returns the compose project and config file that own a
// container. ok is false when no such container exists.
func containerOwner(ctx context.Context, name string) (project, configFile string, ok bool) {
	out, err := exec.CommandContext(ctx, dockerPath(), "inspect", "-f",
		`{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}`,
		name).Output()
	if err != nil {
		return "", "", false // no such container
	}
	parts := strings.SplitN(strings.TrimSpace(string(out)), "|", 2)
	project = strings.TrimSpace(parts[0])
	// `docker inspect` renders a missing label as "<no value>".
	if project == "<no value>" {
		project = ""
	}
	if len(parts) > 1 {
		configFile = strings.TrimSpace(parts[1])
		if configFile == "<no value>" {
			configFile = ""
		}
	}
	return project, configFile, true
}

// composeProjectName is the project this stack's containers belong to. Read
// from a container we know we own rather than guessed, so a COMPOSE_PROJECT_NAME
// override or a renamed stack directory doesn't produce false conflicts.
// Falls back to compose's default (the stack directory name).
func composeProjectName(ctx context.Context) string {
	for _, probe := range []string{"falconpulsar-core", "falconpulsar-ui", "falconpulsar-ai-gateway"} {
		if project, _, ok := containerOwner(ctx, probe); ok && project != "" {
			return project
		}
	}
	if v := strings.TrimSpace(os.Getenv("COMPOSE_PROJECT_NAME")); v != "" {
		return v
	}
	return filepath.Base(HomeDir())
}

// EnsureGatewayConfig makes sure ~/falconpulsar/gateway.yaml is a valid
// config file. Replaces the file if:
//  1. It's a directory (Docker creates one when the bind-mount source is
//     missing).
//  2. It contains the known-bad `providers: []` pattern from earlier
//     installer versions.
//  3. It's not valid UTF-8. This catches the CP1252-encoded em-dash
//     (single byte 0x97) that older Windows tray builds wrote via a
//     C#->stdin->bash pipeline — Python's yaml.safe_load crashes on
//     that byte and the ai-gateway container crash-loops on startup.
//     Detecting invalid UTF-8 is a cheap superset of "contains 0x97".
func EnsureGatewayConfig() {
	p := filepath.Join(HomeDir(), "gateway.yaml")
	fi, err := os.Stat(p)
	if err == nil && fi.IsDir() {
		_ = os.RemoveAll(p)
	}
	needsWrite := false
	if _, err := os.Stat(p); os.IsNotExist(err) {
		needsWrite = true
	} else if data, err := os.ReadFile(p); err == nil {
		if !utf8.Valid(data) {
			needsWrite = true
		} else {
			content := string(data)
			if strings.Contains(content, "providers: []") ||
				strings.Contains(content, "providers: {}") {
				needsWrite = true
			}
		}
	}
	if needsWrite {
		_ = os.MkdirAll(HomeDir(), 0755)
		// Try to copy the real shared/gateway.yaml from the installer tree
		for _, candidate := range []string{
			filepath.Join(HomeDir(), "..", "shared", "gateway.yaml"),
			"/opt/falconpulsar-installer/shared/gateway.yaml",
		} {
			if data, err := os.ReadFile(candidate); err == nil {
				_ = os.WriteFile(p, data, 0644)
				return
			}
		}
		_ = os.WriteFile(p, []byte(defaultGatewayYAML), 0644)
	}
}

// defaultGatewayYAML is the embedded fallback written when no on-disk
// shared/gateway.yaml candidate resolves. It MUST track
// shared/gateway.yaml verbatim (go:embed can't reach outside the console
// module, so the copy is manual) — update both together.
const defaultGatewayYAML = `# FalconPulsar AI Gateway — Standard Configuration
#
# This is the in-tree default configuration shipped with the gateway.
# Server-level settings only. Environment variables override these
# settings. Providers, API keys, models, and tuning are managed via
# the UI (stored in SQLite).
#
# *** NEVER PUT REAL CREDENTIALS IN THIS FILE. ***
# Credentials are read exclusively from environment variables at
# startup, via the Settings/EnvOverrides mechanism in
# fp_ai_gateway/config.py. The fields below intentionally have no
# defaults — if neither FP_API_KEY nor (FP_USERNAME + FP_PASSWORD)
# is set in the environment, the gateway will fail to authenticate
# against Core on its first request. (A startup-time precondition
# check would be a sensible follow-up; not added here to keep this
# change scoped to credential removal.)

server:
  host: "0.0.0.0"
  port: 7436

falconpulsar:
  # Core's DNS name on the compose network. Note: the standard install
  # also injects FALCONPULSAR_URL via compose.yml, and that environment
  # variable takes precedence over this field — repoint Core there (or
  # in the environment), not here.
  url: "http://core:7433"
  # Authentication is provided exclusively via environment variables:
  #   FP_API_KEY                   — bearer/API token (preferred)
  #   FP_USERNAME + FP_PASSWORD    — username/password fallback
  # Do not add literal credentials to this file. See the gateway
  # startup script or your container/orchestration secrets store.
  timeout: 30

# Context configuration
context:
  schema_cache_ttl: 300  # Cache schema for 5 minutes
  max_conversation_tokens: 100000
  include_fpq_examples: true

# Knowledge base (RAG)
knowledge:
  path: "./knowledge"
  embedding_model: "snowflake/snowflake-arctic-embed-l"
  vector_store: "chroma"
  data_path: "./data/chromadb"

# Conversation memory
memory:
  db_path: "./data/conversations.db"
  max_messages: 100

# User adaptive memory (per-user learning)
user_memory:
  db_path: "./data/user_memory.db"
  score_half_life_hours: 168
  max_context_series: 8
  max_context_assets: 5
  max_context_tools: 5
  decay_interval_minutes: 60

# Logging
logging:
  level: "INFO"
  format: "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
`

// OpenFolder opens a local directory in the platform file manager.
func OpenFolder(path string) error {
	return OpenURL(path)
}

// OpenURL launches the platform-appropriate browser opener.
func OpenURL(url string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	return cmd.Start()
}

// Editor returns the preferred editor, falling back sensibly.
func Editor() string {
	if v := os.Getenv("VISUAL"); v != "" {
		return v
	}
	if v := os.Getenv("EDITOR"); v != "" {
		return v
	}
	for _, e := range []string{"nano", "vi", "vim"} {
		if p, err := exec.LookPath(e); err == nil {
			return p
		}
	}
	return "nano"
}

// EditFile opens the given path in $EDITOR, blocking until it closes.
func EditFile(path string) error {
	cmd := exec.Command(Editor(), path)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
