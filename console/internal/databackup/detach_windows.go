// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

//go:build windows

package databackup

import (
	"os/exec"
	"syscall"
)

// detach runs cmd in a process group of its own, where the console's Ctrl+C
// is disabled.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}
