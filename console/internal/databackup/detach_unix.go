// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

//go:build !windows

package databackup

import (
	"os/exec"
	"syscall"
)

// detach runs cmd in a process group of its own: the SIGINT a terminal sends
// to its foreground group on Ctrl-C does not reach it.
func detach(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} }
