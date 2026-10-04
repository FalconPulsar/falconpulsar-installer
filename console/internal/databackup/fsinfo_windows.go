// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

//go:build windows

package databackup

import "errors"

// The stack runs inside WSL and the Windows fp.exe only forwards to the Linux
// fp there, so these are never reached on Windows. They exist so the package
// builds for every target the release builds.

func freeBytes(string) (int64, error) { return 0, errors.New("free space is not measured on Windows") }

func mountPoint(string) bool { return false }

func ownerOf(string) (int, int) { return -1, -1 }

func syncDir(string) error { return nil }
