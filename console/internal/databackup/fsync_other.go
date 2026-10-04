// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

//go:build !linux

package databackup

// Elsewhere there is no syncfs: each restored file and directory is
// fsynced on its own.
const syncEachFile = true

func syncFilesystem(string) error { return nil }
