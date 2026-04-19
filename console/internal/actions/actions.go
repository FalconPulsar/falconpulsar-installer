// Package actions wraps the docker compose operations and filesystem helpers
// that both the CLI subcommands and the TUI need.
package actions

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
)

// HomeDir resolves the stack directory.
//
// Resolution order:
//  1. FP_HOME env var (explicit override).
//  2. On Linux/WSL: if /home/falconpulsar/{compose.yml,.env} exists, use
//     /home/falconpulsar directly. This is required because the installer
//     creates a dedicated `falconpulsar` system user and drops the stack in
//     that user's HOME, so joining $HOME+"falconpulsar" would produce
//     /home/falconpulsar/falconpulsar (doubled).
//  3. Fallback: $HOME/falconpulsar (macOS path).
func HomeDir() string {
	if override := os.Getenv("FP_HOME"); override != "" {
		return override
	}
	if runtime.GOOS == "linux" {
		for _, candidate := range []string{
			"/home/falconpulsar/compose.yml",
			"/home/falconpulsar/.env",
		} {
			if _, err := os.Stat(candidate); err == nil {
				return "/home/falconpulsar"
			}
		}
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return "/home/falconpulsar"
	}
	return filepath.Join(h, "falconpulsar")
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
	return os.WriteFile(envPath, []byte(strings.Join(lines, "\n")), 0600)
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
	return os.WriteFile(envPath, []byte(strings.Join(kept, "\n")), 0600)
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
// config file. Replaces the file if it's a directory (Docker creates one
// when the bind-mount source is missing) OR if it contains the known-bad
// `providers: []` pattern from earlier installer versions.
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
		content := string(data)
		if strings.Contains(content, "providers: []") ||
			strings.Contains(content, "providers: {}") {
			needsWrite = true
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
