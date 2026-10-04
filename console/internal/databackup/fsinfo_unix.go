// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

//go:build !windows

package databackup

import (
	"os"
	"path/filepath"
	"syscall"
)

// freeBytes is the space an unprivileged writer may still use on the
// filesystem holding p.
func freeBytes(p string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(p, &st); err != nil {
		return 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), nil //nolint:unconvert // field types differ by platform
}

// mountPoint reports whether dir is the root of a filesystem: its device
// differs from its parent's (a dedicated data volume, linux/install.sh
// --data-dir). A mount point cannot be renamed aside.
func mountPoint(dir string) bool {
	st, err := os.Lstat(dir)
	if err != nil || !st.IsDir() {
		return false
	}
	parent, err := os.Lstat(filepath.Dir(filepath.Clean(dir)))
	if err != nil {
		return false
	}
	a, ok1 := st.Sys().(*syscall.Stat_t)
	b, ok2 := parent.Sys().(*syscall.Stat_t)
	if !ok1 || !ok2 {
		return false
	}
	return a.Dev != b.Dev || a.Ino == b.Ino // the second: "/" is its own parent
}

// ownerOf returns a path's owning uid and gid, or -1, -1.
func ownerOf(p string) (int, int) {
	st, err := os.Lstat(p)
	if err != nil {
		return -1, -1
	}
	if s, ok := st.Sys().(*syscall.Stat_t); ok {
		return int(s.Uid), int(s.Gid)
	}
	return -1, -1
}

// syncDir makes a directory's entries durable (new names, renames).
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
