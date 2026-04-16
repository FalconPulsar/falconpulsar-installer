// Package actions wraps the docker compose operations and filesystem helpers
// that both the CLI subcommands and the TUI need.
package actions

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
)

// HomeDir resolves the stack directory (~/falconpulsar).
func HomeDir() string {
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, "falconpulsar")
	}
	return "/root/falconpulsar"
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

// composeProfileArgs returns the --profile flags needed based on .env state.
func composeProfileArgs() []string {
	if AIGatewayEnabled() {
		return []string{"--profile", "ai"}
	}
	return nil
}

// Compose runs `docker compose <args...>` in the stack directory. Automatically
// adds --profile ai when FP_AI_GATEWAY_ENABLED=true in .env.
func Compose(ctx context.Context, stdout, stderr io.Writer, args ...string) error {
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
func (s Status) Aggregate() string {
	running := 0
	for _, b := range []bool{s.Core, s.UI, s.Gateway} {
		if b {
			running++
		}
	}
	if running == 3 && s.APIHealthy {
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
