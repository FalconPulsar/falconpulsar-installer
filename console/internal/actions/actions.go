// Package actions wraps the docker compose operations and filesystem helpers
// that both the CLI subcommands and the TUI need.
package actions

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
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

// AIGatewayEnabled reads FP_AI_GATEWAY_ENABLED from ~/falconpulsar/.env.
func AIGatewayEnabled() bool {
	data, err := os.ReadFile(filepath.Join(HomeDir(), ".env"))
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "FP_AI_GATEWAY_ENABLED=") {
			val := strings.TrimPrefix(line, "FP_AI_GATEWAY_ENABLED=")
			return val == "true" || val == "1" || val == "yes"
		}
	}
	return true // default: enabled if flag is absent (backward compat)
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

// RemoveEnvValue strips the given key's line from ~/falconpulsar/.env.
func RemoveEnvValue(key string) error {
	envPath := filepath.Join(HomeDir(), ".env")
	data, err := os.ReadFile(envPath)
	if err != nil {
		return err
	}
	var kept []string
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), key+"=") {
			kept = append(kept, line)
		}
	}
	return os.WriteFile(envPath, []byte(strings.Join(kept, "\n")), envFileMode(envPath))
}

// parseEnvFile reads .env into a map. Doesn't interpret quoting — good enough
// for the few keys we care about in AI gateway teardown (FP_REGISTRY,
// FP_VERSION, FP_DATA_DIR, FP_GATEWAY_DATA_DIR).
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

// SurgicalDisableAI removes only the AI gateway service + its host bind-mount
// data dir, gateway.yaml, image, and FP_API_KEY from .env. NEVER runs
// `compose down -v` because that would stop core + ui too.
//
// Matches the macOS menu-bar and Windows tray surgical flow exactly.
func SurgicalDisableAI(ctx context.Context, out io.Writer) error {
	env := parseEnvFile()

	write := func(s string) {
		if out != nil {
			_, _ = io.WriteString(out, s)
		}
	}

	write("[disable-ai] stopping and removing ai-gateway container (core/ui untouched)…\n")
	cmd := exec.CommandContext(ctx, dockerPath(), "compose", "--profile", "ai",
		"rm", "-f", "-s", "-v", "ai-gateway")
	cmd.Dir = HomeDir()
	cmd.Stdout = out
	cmd.Stderr = out
	_ = cmd.Run()

	// Bind-mount data directory — respect .env overrides.
	dataDir := env["FP_GATEWAY_DATA_DIR"]
	if dataDir == "" {
		base := env["FP_DATA_DIR"]
		if base == "" {
			base = filepath.Join(HomeDir(), "data")
		}
		dataDir = filepath.Join(base, "..", "ai-gateway-data")
	}
	if dataDir != "" && dataDir != "/" {
		if st, err := os.Stat(dataDir); err == nil && st.IsDir() {
			write(fmt.Sprintf("[disable-ai] removing AI gateway data directory: %s\n", dataDir))
			_ = os.RemoveAll(dataDir)
		}
	}

	// gateway.yaml
	write("[disable-ai] removing gateway.yaml…\n")
	_ = os.Remove(filepath.Join(HomeDir(), "gateway.yaml"))

	// FP_API_KEY from .env
	write("[disable-ai] clearing FP_API_KEY from .env…\n")
	_ = RemoveEnvValue("FP_API_KEY")

	// Image
	registry := env["FP_REGISTRY"]
	if registry == "" {
		registry = "falconpulsar"
	}
	version := env["FP_VERSION"]
	if version == "" {
		version = "latest"
	}
	imageRef := fmt.Sprintf("%s/ai-gateway:%s", registry, version)
	write(fmt.Sprintf("[disable-ai] removing AI gateway image: %s\n", imageRef))
	rmi := exec.CommandContext(ctx, dockerPath(), "rmi", "-f", imageRef)
	rmi.Stdout = out
	rmi.Stderr = out
	_ = rmi.Run()

	write("[disable-ai] cleanup complete. Core and UI were not touched.\n")
	return nil
}

// WipeGatewaySeedDefaults removes the AI Gateway image's self-seeded
// provider + model rows so the user lands on a clean AI configuration.
//
// The gateway image (built from the separate falconpulsar/ai-gateway repo)
// inserts 3 default providers (Anthropic, Grok, Ollama) and 6 default
// models (Claude Opus 4.6 / Sonnet 4.5, Grok 4, Llama 3.1 8B, Mistral 7B,
// Gemma 2 9B) into its SQLite on first boot. On a fresh install where no
// LLM provider is configured, those entries are misleading: the toolbar
// shows "Llama 3.1 8B" as the active model, the Models page lists 6
// "Offline" entries, and users reasonably assume FalconPulsar shipped them.
//
// Until falconpulsar/ai-gateway gates seeding (or stops doing it), this
// helper runs after every "enable AI" action — install-time, fp ai
// enable, TUI Enable, tray Enable — and DELETEs the seeded rows.
//
// Mirrors fp_wipe_gateway_seed_defaults in shared/lib/bootstrap.sh; both
// implementations must do exactly the same SQL so the post-install state
// is identical regardless of which surface enabled AI.
//
// Non-fatal: any failure logs to `out` and returns nil. We never fail an
// otherwise-successful enable just because the cosmetic cleanup didn't
// take.
//
// TODO(falconpulsar/ai-gateway): land the upstream fix and remove this
// function plus its call sites in cli.go and tui.go.
func WipeGatewaySeedDefaults(ctx context.Context, out io.Writer) error {
	write := func(s string) {
		if out != nil {
			_, _ = io.WriteString(out, s)
		}
	}

	port := parseEnvFile()["FP_GATEWAY_PORT"]
	if port == "" {
		port = "7436"
	}
	healthURL := fmt.Sprintf("http://127.0.0.1:%s/health", port)
	container := "falconpulsar-ai-gateway"

	waitHealthy := func(maxSeconds int) bool {
		deadline := time.Now().Add(time.Duration(maxSeconds) * time.Second)
		client := &http.Client{Timeout: 3 * time.Second}
		for time.Now().Before(deadline) {
			req, _ := http.NewRequestWithContext(ctx, "GET", healthURL, nil)
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

	write("[wipe-seed] waiting for AI Gateway to finish init…\n")
	if !waitHealthy(90) {
		write("[wipe-seed] WARN: gateway not healthy in 90s — leaving seed defaults in place\n")
		return nil
	}

	write("[wipe-seed] removing self-seeded providers and models…\n")
	cmd := exec.CommandContext(ctx, dockerPath(), "exec", container,
		"sqlite3", "/app/data/ai_config.db",
		"DELETE FROM model_definitions; DELETE FROM provider_configs;")
	if err := cmd.Run(); err != nil {
		write(fmt.Sprintf("[wipe-seed] WARN: docker exec sqlite3 failed (%v) — install continues\n", err))
		return nil
	}

	write("[wipe-seed] restarting AI Gateway so in-memory state matches DB…\n")
	restart := exec.CommandContext(ctx, dockerPath(), "restart", container)
	_ = restart.Run()

	if waitHealthy(60) {
		write("[wipe-seed] AI Gateway clean: 0 providers, 0 models\n")
	} else {
		write("[wipe-seed] WARN: gateway slow to come back after wipe — UI may show stale models for a moment\n")
	}
	return nil
}

// composeProfileArgs returns the --profile flags needed based on .env state.
func composeProfileArgs() []string {
	if AIGatewayEnabled() {
		return []string{"--profile", "ai"}
	}
	return nil
}

// Compose runs `docker compose <args...>` in the stack directory. Automatically
// adds --profile ai when FP_AI_GATEWAY_ENABLED=true in .env. Also ensures
// gateway.yaml exists as a file before any compose up to prevent Docker from
// creating a directory at that path.
func Compose(ctx context.Context, stdout, stderr io.Writer, args ...string) error {
	if AIGatewayEnabled() {
		EnsureGatewayConfig()
	}
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

// Status struct describes the live state of the four services.
type Status struct {
	Core       bool
	UI         bool
	Gateway    bool
	APIHealthy bool
}

// Aggregate returns a single word describing overall status.
// When AI Gateway is disabled, it's excluded from the tally —
// Core + UI running = "running" (green), not "partial" (yellow).
func (s Status) Aggregate() string {
	aiEnabled := AIGatewayEnabled()
	expected := 2 // core + ui
	running := 0
	if s.Core { running++ }
	if s.UI { running++ }
	if aiEnabled {
		expected++
		if s.Gateway { running++ }
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
	cli := api.New()
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

const defaultGatewayYAML = `# FalconPulsar AI Gateway — default configuration.
# Providers, API keys, and models are managed via the Web UI
# (Settings > AI Configuration), not this file.
server:
  host: "0.0.0.0"
  port: 7436
falconpulsar:
  url: "http://localhost:7433"
  timeout: 30
context:
  schema_cache_ttl: 300
  max_conversation_tokens: 100000
  include_fpq_examples: true
knowledge:
  enabled: true
  path: "./knowledge"
memory:
  enabled: true
  db_path: "./data/conversations.db"
  max_messages: 100
user_memory:
  enabled: true
  db_path: "./data/user_memory.db"
logging:
  level: "INFO"
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
