// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

// Package main is the Windows-side `fp.exe` launcher.
//
// FalconPulsar's real `fp` CLI is a Linux binary that lives inside the user's
// WSL distro alongside the Core/UI/AI-gateway containers. A Windows-native
// Go build would look at `%USERPROFILE%\falconpulsar\` for state, which is
// the wrong filesystem — the stack is in WSL, owned by the WSL default user.
//
// This tiny wrapper ships as `fp.exe` on Windows. It:
//
//  1. Locates the installed WSL distro ({app}\tray-config.txt, then a
//     %TEMP% sentinel, then by reading each registered distro's os-release).
//  2. Locates the stack home path inside that distro ({app}\tray-home.txt,
//     e.g. "/home/<user>/falconpulsar" where <user> is the distro's default
//     user; a %TEMP% sentinel and a live WSL probe are the fallbacks).
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

// osReleaseIDs the bash installer supports, from check_os() in
// shared/lib/checks.sh. Matched against a distro's /etc/os-release ID —
// what the system IS — rather than its WSL registration name, which is a
// label the user picked and says nothing about the contents.
//
// No version floors here: this is only picking which registered distro to
// forward `fp` into, and check_os() has already gated the install itself.
var supportedOSReleaseIDs = map[string]bool{
	"ubuntu": true, "debian": true,
	"rhel": true, "rocky": true, "almalinux": true,
	"fedora": true, "opensuse-leap": true,
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

// durableState reads one of the state files the installer writes into {app}
// (tray-config.txt, tray-home.txt), returning "" when it isn't there.
//
// fp.exe installs to %LOCALAPPDATA%\falconpulsar\bin, not into {app}, so it
// cannot look beside itself the way the tray does — it checks the default
// install locations instead. A non-default install dir falls through to the
// WSL probe below, which is fine here: unlike the tray (which starts at
// login, before WSL is up), fp.exe runs on demand with WSL already running.
func durableState(filename string) string {
	for _, env := range []string{"ProgramFiles", "ProgramFiles(x86)"} {
		dir := os.Getenv(env)
		if dir == "" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, "FalconPulsar", filename))
		if err != nil {
			continue
		}
		if s := strings.TrimSpace(string(data)); s != "" {
			return s
		}
	}
	return ""
}

// resolveHome returns the WSL stack directory. Resolution order:
//
//  1. FP_HOME env var (explicit override — useful for debugging).
//  2. The durable {app}\tray-home.txt the installer writes.
//  3. %TEMP%\falconpulsar-home.txt sentinel. Only a fallback: the installer
//     runs ELEVATED, so this is the admin's %TEMP% rather than the calling
//     user's, and Storage Sense empties it anyway.
//  4. Ask the distro what the default user's $HOME is and append
//     "/falconpulsar" — last-resort fallback matching the installer's
//     per-user layout.
func resolveHome(distro string) string {
	if h := strings.TrimSpace(os.Getenv("FP_HOME")); h != "" {
		return h
	}
	if h := durableState("tray-home.txt"); strings.HasPrefix(h, "/") {
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

// osReleaseID returns a distro's /etc/os-release ID (lowercased), or "" if
// it can't be read — an unregistered name, a distro that won't start, or a
// rootfs with no os-release at all.
func osReleaseID(distro string) string {
	out, err := exec.Command("wsl.exe", "-d", distro, "--", "sh", "-c",
		`. /etc/os-release 2>/dev/null && printf %s "$ID"`).Output()
	if err != nil {
		return ""
	}
	id := strings.ReplaceAll(string(out), "\x00", "")
	id = strings.TrimPrefix(strings.TrimSpace(id), "\ufeff")
	return strings.ToLower(strings.Trim(id, `"`))
}

func resolveDistro() (string, error) {
	// 1. Explicit override: FP_WSL_DISTRO env var.
	if d := strings.TrimSpace(os.Getenv("FP_WSL_DISTRO")); d != "" {
		return d, nil
	}

	// 2. The durable {app}\tray-config.txt the installer writes.
	if d := durableState("tray-config.txt"); d != "" {
		return d, nil
	}

	// 3. Sentinel file written by the installer at %TEMP%\falconpulsar-distro.txt.
	if tmp := os.Getenv("TEMP"); tmp != "" {
		sentinel := filepath.Join(tmp, "falconpulsar-distro.txt")
		if data, err := os.ReadFile(sentinel); err == nil {
			if d := strings.TrimSpace(string(data)); d != "" {
				return d, nil
			}
		}
	}

	// 4. Enumerate what is registered and ask each one what it IS.
	installed, err := listDistros()
	if err != nil {
		return "", fmt.Errorf("could not list WSL distros: %w", err)
	}
	for _, have := range installed {
		if supportedOSReleaseIDs[osReleaseID(have)] {
			return have, nil
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
