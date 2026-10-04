// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

package databackup

// Is the Core that fp restore started reading the restored data directory?
//
// Restore renames Core's data directory aside (<dir>.pre-restore-<stamp>) and
// builds the restored one at the same path. Core's container opens that path
// when it starts. On Linux that is the restored directory. Docker Desktop
// shares host directories with its VM through a file-sharing layer that can
// keep its view of a name renamed on the host: Core then starts on the data
// set aside, writes into <dir>.pre-restore-*, which the operator is told to
// delete, and answers /health as if nothing were wrong. That happened four
// times in a row on macOS on 2026-10-04, then in none of nine later runs.
//
// The check: before the stack starts, a marker file with a name never used
// before goes into the restored directory; after Core starts, /data is listed
// inside Core's container. A container whose /data is the directory set aside
// (what was seen) does not list the marker. It is stopped at once, so it
// writes nothing more into the set-aside data, and started again after a
// pause; if it still does not list the marker, Core is left stopped and the
// operator is told to restart Docker Desktop, which drops the VM's view.
//
// What the check cannot see: a view that is current for the directory but
// stale for some names inside it (a minimal repro once listed old and new
// names together). The marker is new, so it is listed either way. The same
// holds when Core's data directory is a mount point: Restore then sets its
// contents aside inside it, and the directory itself is not new.

import (
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// coreContainerDataDir is where compose mounts FP_DATA_DIR in Core's container.
const coreContainerDataDir = "/data"

// coreViewRetries are the pauses before Core is started again when it does not
// read the restored directory; one start per pause. A var for tests.
var coreViewRetries = []time.Duration{3 * time.Second, 10 * time.Second}

// MarkRestoredCore writes the marker into Core's restored data directory,
// durably and owned like the restored files, and returns its name.
func MarkRestoredCore(e Env) (string, error) {
	var rnd [8]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		return "", err
	}
	name := fmt.Sprintf(".fp-restored-%s-%x", time.Now().UTC().Format("20060102T150405Z"), rnd)
	p := filepath.Join(e.CoreDir, name)
	f, err := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return "", err
	}
	_, err = io.WriteString(f, "fp restore checks that Core reads this directory; it deletes this file afterwards\n")
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(p)
		return "", err
	}
	if e.Owner != nil && os.Geteuid() == 0 {
		_ = os.Lchown(p, e.Owner.UID, e.Owner.GID)
	}
	_ = syncDir(e.CoreDir)
	return name, nil
}

// UnmarkRestoredCore removes the marker.
func UnmarkRestoredCore(e Env, name string) {
	if name != "" {
		_ = os.Remove(filepath.Join(e.CoreDir, name))
	}
}

// StaleCoreViewError: Core's container does not read the restored data
// directory but, through a stale view, the one set aside. Core was stopped.
type StaleCoreViewError struct {
	Dir     string
	StopErr error // Core could not be stopped: it may still be running there
	Err     error // why it could not be started again for another look
}

func (e *StaleCoreViewError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "Core is not reading the restored data in %s: inside its container, %s is still the directory that was set aside "+
		"(Docker Desktop's file sharing kept its view of the renamed directory). ", e.Dir, coreContainerDataDir)
	if e.StopErr != nil {
		fmt.Fprintf(&b, "Stopping Core failed (%v): stop it NOW (docker stop -t 180 %s), or it keeps writing into the set-aside data. ", e.StopErr, coreContainer)
	} else {
		b.WriteString("Core is stopped, so it writes nothing more into the set-aside data. ")
		if e.Err != nil {
			fmt.Fprintf(&b, "(Starting it again for another look failed: %v.) ", e.Err)
		}
	}
	b.WriteString("The restored data is in place. Quit Docker Desktop and open it again, then run fp start")
	return b.String()
}

// VerifyCoreReadsRestore checks, inside Core's running container, that Core
// reads the restored data directory: /data lists marker. When it does not,
// Core is stopped at once and started again after each pause in
// coreViewRetries; if it still does not, Core is left stopped and the answer
// is a *StaleCoreViewError. Any other error means the check could not be
// made, and Core was left as it was.
func VerifyCoreReadsRestore(ctx context.Context, e Env, marker string, log io.Writer) error {
	if e.DockerOutput == nil {
		e.DockerOutput = realDockerOutput
	}
	if e.StopCore == nil {
		e.StopCore = realStopCore
	}
	if e.StartCore == nil {
		e.StartCore = realStartCore
	}
	if log == nil {
		log = io.Discard
	}
	for attempt := 0; ; attempt++ {
		seen, err := coreLists(ctx, e, marker)
		if err != nil {
			return fmt.Errorf("listing %s inside %s: %w", coreContainerDataDir, coreContainer, err)
		}
		if seen {
			if attempt > 0 {
				fmt.Fprintln(log, "Core now reads the restored data directory.")
			}
			return nil
		}
		// Core runs on the data set aside: stop it before it writes more there.
		// Not tied to ctx: a Core left running there is the harm being undone.
		sctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), coreStopTimeout+time.Minute)
		stopErr := e.StopCore(sctx)
		cancel()
		if stopErr != nil || attempt == len(coreViewRetries) {
			return &StaleCoreViewError{Dir: e.CoreDir, StopErr: stopErr}
		}
		pause := coreViewRetries[attempt]
		fmt.Fprintf(log, "Core is not reading the restored data directory (Docker Desktop's file sharing kept its view of the directory set aside); "+
			"it was stopped and starts again in %s …\n", pause)
		select {
		case <-time.After(pause):
		case <-ctx.Done():
			return &StaleCoreViewError{Dir: e.CoreDir, Err: ctx.Err()}
		}
		if err := e.StartCore(ctx); err != nil {
			return &StaleCoreViewError{Dir: e.CoreDir, Err: err}
		}
	}
}

// coreLists reports whether /data inside Core's container lists name.
func coreLists(ctx context.Context, e Env, name string) (bool, error) {
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out, err := e.DockerOutput(cctx, coreContainer, []string{"ls", "-a", coreContainerDataDir})
	if err != nil {
		return false, err
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == name {
			return true, nil
		}
	}
	return false, nil
}

func realDockerOutput(ctx context.Context, container string, argv []string) (string, error) {
	cmd := exec.CommandContext(ctx, "docker", append([]string{"exec", container}, argv...)...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("docker exec %s: %v — %s", container, err, strings.TrimSpace(stderr.String()))
	}
	return string(out), nil
}
