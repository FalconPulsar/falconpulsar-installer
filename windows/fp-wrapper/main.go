// Package main is the Windows-side `fp.exe` launcher.
//
// FalconPulsar's real `fp` CLI is a Linux binary that lives inside the user's
// WSL distro alongside the Core/UI/AI-gateway containers. A Windows-native
// Go build would look at `%USERPROFILE%\falconpulsar\` for state, which is
// the wrong filesystem — the stack is in WSL, owned by the WSL default user.
//
// This tiny wrapper ships as `fp.exe` on Windows. It:
//
//  1. Locates the installed WSL distro (sentinel file or `wsl -l -q`).
//  2. Locates the stack home path inside that distro (sentinel file written
//     by the installer at %TEMP%\falconpulsar-home.txt, e.g.
//     "/home/<user>/falconpulsar" where <user> is the distro's default user).
//  3. Execs `wsl.exe -d <distro> --cd <home> -e <home>/bin/fp [args...]`
//     with stdin/stdout/stderr passed through so the TUI, colours, and
//     credential prompts work verbatim. No `-u` flag: fp runs as the
//     distro's default user (the same human who owns the stack).
//  4. Propagates the Linux fp's exit code.
//
// Power users can also invoke the Linux `fp` directly from inside WSL —
// this wrapper is only for convenience when typing `fp` in PowerShell
// or cmd.exe.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Distros we recognise as likely FalconPulsar hosts, in priority order.
// `resolveDistro` prefers a sentinel written by the installer; this list
// is only the fallback if the sentinel is missing.
var fallbackDistros = []string{
	"Ubuntu-24.04",
	"Ubuntu-22.04",
	"Ubuntu",
	"Debian",
}

func main() {
	distro, err := resolveDistro()
	if err != nil {
		fmt.Fprintf(os.Stderr, "fp: %v\n", err)
		fmt.Fprintln(os.Stderr, "fp: is FalconPulsar installed? If the distro name is non-standard, set FP_WSL_DISTRO.")
		os.Exit(1)
	}

	home := resolveHome(distro)

	args := []string{
		"-d", distro,
		"--cd", home,
		"-e", home + "/bin/fp",
	}
	args = append(args, os.Args[1:]...)

	cmd := exec.Command("wsl.exe", args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "fp: wsl.exe failed: %v\n", err)
		os.Exit(1)
	}
}

// resolveHome returns the WSL stack directory. Resolution order:
//
//  1. FP_HOME env var (explicit override — useful for debugging).
//  2. %TEMP%\falconpulsar-home.txt sentinel (installer writes this).
//  3. Ask the distro what the default user's $HOME is and append
//     "/falconpulsar" — last-resort fallback matching the installer's
//     per-user layout.
func resolveHome(distro string) string {
	if h := strings.TrimSpace(os.Getenv("FP_HOME")); h != "" {
		return h
	}
	if tmp := os.Getenv("TEMP"); tmp != "" {
		sentinel := filepath.Join(tmp, "falconpulsar-home.txt")
		if data, err := os.ReadFile(sentinel); err == nil {
			if h := strings.TrimSpace(string(data)); h != "" {
				return h
			}
		}
	}
	// Query WSL for the default user's $HOME. This matches the installer
	// because the installer uses `whoami` against the same distro.
	out, err := exec.Command("wsl.exe", "-d", distro, "--", "sh", "-c", "printf %s \"$HOME\"").Output()
	if err == nil {
		h := strings.TrimSpace(strings.ReplaceAll(string(out), "\x00", ""))
		h = strings.TrimPrefix(h, "\ufeff")
		if h != "" && strings.HasPrefix(h, "/") {
			return h + "/falconpulsar"
		}
	}
	// Last-ditch: the legacy service-user path. If we ever get here and
	// this path isn't valid either, wsl -e will simply fail and the user
	// will see a clear "file not found" error.
	return "/home/falconpulsar"
}

func resolveDistro() (string, error) {
	// 1. Explicit override: FP_WSL_DISTRO env var.
	if d := strings.TrimSpace(os.Getenv("FP_WSL_DISTRO")); d != "" {
		return d, nil
	}

	// 2. Sentinel file written by the installer at %TEMP%\falconpulsar-distro.txt.
	if tmp := os.Getenv("TEMP"); tmp != "" {
		sentinel := filepath.Join(tmp, "falconpulsar-distro.txt")
		if data, err := os.ReadFile(sentinel); err == nil {
			if d := strings.TrimSpace(string(data)); d != "" {
				return d, nil
			}
		}
	}

	// 3. Probe each known distro with `wsl -l -q`.
	installed, err := listDistros()
	if err != nil {
		return "", fmt.Errorf("could not list WSL distros: %w", err)
	}
	for _, candidate := range fallbackDistros {
		for _, have := range installed {
			if strings.EqualFold(have, candidate) {
				return have, nil
			}
		}
	}
	if len(installed) == 1 {
		// Single distro — use it.
		return installed[0], nil
	}
	return "", fmt.Errorf("no FalconPulsar WSL distro found")
}

func listDistros() ([]string, error) {
	out, err := exec.Command("wsl.exe", "-l", "-q").Output()
	if err != nil {
		return nil, err
	}
	// wsl.exe emits UTF-16LE with BOM on some Windows versions. Strip BOM
	// and interpret as UTF-8/ASCII — distro names are always ASCII anyway.
	text := string(out)
	text = strings.TrimPrefix(text, "\ufeff")
	// Remove embedded null bytes that show up from UTF-16LE interpreted
	// as UTF-8 (every second byte is 0x00).
	text = strings.ReplaceAll(text, "\x00", "")

	var names []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			names = append(names, line)
		}
	}
	return names, nil
}
