// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

//go:build linux

package databackup

import (
	"os"

	"golang.org/x/sys/unix"
)

// On Linux a restore makes what it wrote durable with one syncfs(2) per
// filesystem instead of an fsync per file: a Core data directory can hold
// millions of partition files, and one fsync each would be one journal
// commit each. syncfs writes back every file and directory on the
// filesystem and commits once, which is the same guarantee before Core
// starts.
const syncEachFile = false

func syncFilesystem(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer f.Close()
	return unix.Syncfs(int(f.Fd()))
}
