// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

//go:build !windows

package databackup

import (
	"context"
	"testing"
)

func TestDockerRunsOutsideTheTerminalsProcessGroup(t *testing.T) {
	// A terminal's Ctrl-C goes to its whole foreground group. A docker stop in
	// that group dies midway while the daemon goes on closing Core.
	cmd := dockerCommand(context.Background(), "stop", "-t", "180", coreContainer)
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.Setpgid {
		t.Fatal("docker must run in a process group of its own")
	}
}
