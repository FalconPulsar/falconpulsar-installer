// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

//go:build e2e

package databackup

// End-to-end tests against a REAL Core (built from source, running in Docker
// with its data directory bind-mounted from this host, as in production),
// under load. They drive the real Backup and Restore. A harness outside the
// repo starts Core and a load writer first, and afterwards opens the restored
// copy with a second Core and checks every acknowledged point:
//
//	FP_E2E_CORE_URL    Core's REST API, e.g. http://127.0.0.1:17633
//	FP_E2E_CORE_DIR    the host side of Core's data directory
//	FP_E2E_ADMIN_USER  an admin login on that Core
//	FP_E2E_ADMIN_PASS
//	FP_E2E_OUT         a directory for the archive, the restored copy and t0
//	FP_E2E_SPREAD      how long the lease copy is spread over (default 90s)
//	FP_E2E_STOP_CMD    (cold test) a shell command that stops Core
//	FP_E2E_START_CMD   (cold test) a shell command that starts it again
//
// The recipe (2026-10-04, Core branch fix/backup-consistency at fdd8929; any
// image with cmake, a C compiler and python3 builds and runs Core — Core's own
// docker/Dockerfile builder stage has them):
//
//	E=<an empty host directory>
//	docker run -d --name fp-backup-e2e -p 127.0.0.1:17633:7433 \
//	    -v <core source>:/srcro:ro -v "$E":/e2e <build image> sleep infinity
//	docker exec -w / fp-backup-e2e bash -c 'rm -rf /src && cp -a /srcro /src && cmake -S /src -B /build \
//	    -DCMAKE_BUILD_TYPE=Release -DFP_BUILD_SERVER=ON -DFP_BUILD_SHARED=OFF -DFP_BUILD_STATIC=ON \
//	    -DFP_BUILD_TOOLS=OFF -DFP_BUILD_TESTS=OFF -DFP_BUILD_EXAMPLES=OFF -DFP_ENABLE_LTO=OFF \
//	    && cmake --build /build -j8 --target fpd'
//	cp testdata/e2e/* "$E"/
//	docker exec -w /e2e fp-backup-e2e bash -c 'FP_ADMIN_USER=admin FP_ADMIN_PASS=Adm1n-pass-e2e-test \
//	    FP_COOKIE_SECURE=false nohup /build/falconpulsar-server --init-auto -V -d /e2e/core --bind 0.0.0.0 \
//	    -p 7433 --ws-port 7434 --metrics-port 7435 > /e2e/core.log 2>&1 & echo $! > /e2e/core.pid'
//	docker exec -w /e2e fp-backup-e2e bash -c 'nohup python3 /e2e/writer.py --port 7433 --dir /e2e/w \
//	    --series 40 --pts-threads 2 --cat-threads 1 --cat-rate 5 --rate 20000 --str-series 4 > /e2e/writer.log 2>&1 &'
//	# a few minutes of load, then (the lease copy is spread over FP_E2E_SPREAD):
//	FP_E2E_CORE_URL=http://127.0.0.1:17633 FP_E2E_CORE_DIR="$E"/core FP_E2E_ADMIN_USER=admin \
//	    FP_E2E_ADMIN_PASS=Adm1n-pass-e2e-test FP_E2E_OUT="$E" FP_E2E_SPREAD=180s \
//	    FP_E2E_STOP_CMD="docker exec fp-backup-e2e /e2e/stop-core.sh" \
//	    FP_E2E_START_CMD="docker exec fp-backup-e2e /e2e/start-core.sh" \
//	    go test -tags e2e -run TestE2E -v -timeout 30m ./internal/databackup/
//	# stop the writer, then open each restored copy with a second Core and
//	# check every acknowledgement before t0 (in lease.json / cold.json):
//	docker exec fp-backup-e2e python3 /e2e/verify.py --data /e2e/restored-lease/data \
//	    --acks /e2e/w/acks --t0 <lease.json t0> --port 7733
//	docker exec fp-backup-e2e python3 /e2e/verify.py --data /e2e/restored-cold/data \
//	    --acks /e2e/w/acks --t0 <cold.json t0> --port 7833
//
// verify.py prints "PASS": true when every point and string acknowledged
// before t0 is there once with its value, every acknowledged series exists,
// and the catalog opened undamaged. Points a client re-sent after losing an
// answer (a batch in flight when Core stopped) are duplicates in the source
// itself; check the source with --live before blaming the copy.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type e2eConf struct {
	url, coreDir, user, pass, out string
	spread                        time.Duration
}

func e2eEnv(t *testing.T) e2eConf {
	t.Helper()
	c := e2eConf{
		url: os.Getenv("FP_E2E_CORE_URL"), coreDir: os.Getenv("FP_E2E_CORE_DIR"),
		user: os.Getenv("FP_E2E_ADMIN_USER"), pass: os.Getenv("FP_E2E_ADMIN_PASS"),
		out: os.Getenv("FP_E2E_OUT"), spread: 90 * time.Second,
	}
	if c.url == "" || c.coreDir == "" || c.user == "" || c.pass == "" || c.out == "" {
		t.Skip("FP_E2E_* not set: this test needs a running Core")
	}
	if d, err := time.ParseDuration(os.Getenv("FP_E2E_SPREAD")); err == nil {
		c.spread = d
	}
	return c
}

func e2eLogin(t *testing.T, c e2eConf) string {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"username": c.user, "password": c.pass})
	resp, err := http.Post(c.url+"/api/v1/auth/login", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var r struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil || r.Token == "" {
		t.Fatalf("login: HTTP %d %v", resp.StatusCode, err)
	}
	return r.Token
}

func e2eStatus(t *testing.T, c e2eConf, token, method, path string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, c.url+path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var buf bytes.Buffer
	_, _ = buf.ReadFrom(resp.Body)
	return resp.StatusCode, buf.String()
}

// e2eStack is a stack with Core only: the other services' directories do not
// exist, so Backup archives Core and the config files.
func e2eStack(t *testing.T, c e2eConf, key string) Env {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".env"), []byte("FP_VERSION=e2e\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(home, "absent")
	return Env{
		Home: home, CoreDir: c.coreDir, GatewayDir: missing, EngineDir: missing, CopilotDir: missing,
		FPVersion: "e2e", CoreURL: c.url, BackupKey: key,
		ContainerRunning: func(_ context.Context, name string) bool { return name == coreContainer },
		DockerExec: func(context.Context, string, []string) error {
			t.Fatal("no SQLite service in this stack")
			return nil
		},
		StopCore:  func(context.Context) error { t.Fatal("a live copy must not stop Core"); return nil },
		StartCore: func(context.Context) error { t.Fatal("a live copy must not start Core"); return nil },
	}
}

func writeJSON(t *testing.T, p string, v any) {
	b, _ := json.MarshalIndent(v, "", "  ")
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

type testLog struct{ t *testing.T }

func (l testLog) Write(p []byte) (int, error) {
	l.t.Log(strings.TrimRight(string(p), "\n"))
	return len(p), nil
}

func TestE2ELeaseBackupUnderLoad(t *testing.T) {
	c := e2eEnv(t)
	ctx := context.Background()
	admin := e2eLogin(t, c)

	// The key, through the real path, and what it may do.
	key, err := MintBackupKey(ctx, c.url, admin)
	if err != nil {
		t.Fatalf("mint: %v", err)
	}
	if st, err := CheckBackupKey(ctx, c.url, key); st != KeyOK {
		t.Fatalf("the minted key does not work: %v %v", st, err)
	}
	for _, p := range []string{"/api/v1/series", "/api/v1/_system", "/api/v1/_system/storage", "/api/v1/tokens", "/api/v1/users"} {
		if code, _ := e2eStatus(t, c, key, http.MethodGet, p); code != http.StatusForbidden && code != http.StatusUnauthorized {
			t.Errorf("the backup key reached %s: HTTP %d", p, code)
		}
	}

	e := e2eStack(t, c, key)
	archive := filepath.Join(c.out, "lease.tar.gz")
	_ = os.Remove(archive)
	var files int
	t0 := time.Now().UnixNano()
	man, err := Backup(ctx, e, archive, BackupOptions{
		Log: testLog{t},
		afterCoreFile: func(i, n int, path string) {
			if files == 0 {
				// The list is in hand: spread the copy so ingest, flushes and
				// Core's own checkpoints run while it is made.
				code, body := e2eStatus(t, c, admin, http.MethodGet, "/api/v1/_system/backup")
				var cur struct {
					Backup *LeaseStatus `json:"backup"`
				}
				_ = json.Unmarshal([]byte(body), &cur)
				if code != 200 || cur.Backup == nil {
					t.Errorf("no active lease during the copy: %d %s", code, body)
				} else {
					files = 1
				}
			}
			time.Sleep(c.spread / time.Duration(n))
		},
	})
	t1 := time.Now().UnixNano()
	if err != nil {
		t.Fatalf("backup: %v", err)
	}
	if man.Core == nil || man.Core.Mode != CoreLease {
		t.Fatalf("capture %+v", man.Core)
	}
	t.Logf("core: %s; %d files, %d bytes, Core %s", man.Semantics["core"], man.Core.Files, man.Core.Bytes, man.Core.CoreVersion)

	// Released, and its snapshot area deleted.
	code, body := e2eStatus(t, c, admin, http.MethodGet, "/api/v1/_system/backup")
	if code != 200 || !strings.Contains(body, `"backup":null`) {
		t.Errorf("lease not released: %d %s", code, body)
	}
	if _, err := os.Stat(filepath.Join(c.coreDir, ".fp-backup", man.Core.LeaseID)); !os.IsNotExist(err) {
		t.Errorf(".fp-backup/%s left behind", man.Core.LeaseID)
	}

	restored := filepath.Join(c.out, "restored-lease")
	_ = os.RemoveAll(restored)
	re := Env{Home: filepath.Join(restored, "home"), CoreDir: filepath.Join(restored, "data"),
		GatewayDir: filepath.Join(restored, "g"), EngineDir: filepath.Join(restored, "e"), CopilotDir: filepath.Join(restored, "c")}
	if err := os.MkdirAll(re.Home, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(ctx, re, archive, RestoreOptions{Only: []string{"core"}}); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if _, err := os.Stat(filepath.Join(re.CoreDir, ".fp-backup")); !os.IsNotExist(err) {
		t.Errorf(".fp-backup restored")
	}
	writeJSON(t, filepath.Join(c.out, "lease.json"), map[string]any{
		"t0": t0, "t1": t1, "lease_id": man.Core.LeaseID, "catalog_sequence": man.Core.CatalogSequence,
		"files": man.Core.Files, "bytes": man.Core.Bytes, "restored": re.CoreDir, "semantics": man.Semantics["core"],
	})
}

func TestE2EColdCopyStopsAndStartsCore(t *testing.T) {
	c := e2eEnv(t)
	stopCmd, startCmd := os.Getenv("FP_E2E_STOP_CMD"), os.Getenv("FP_E2E_START_CMD")
	if stopCmd == "" || startCmd == "" {
		t.Skip("FP_E2E_STOP_CMD / FP_E2E_START_CMD not set")
	}
	ctx := context.Background()
	run := func(cmd string) func(context.Context) error {
		return func(ctx context.Context) error {
			out, err := exec.CommandContext(ctx, "sh", "-c", cmd).CombinedOutput()
			if err != nil {
				return fmt.Errorf("%s: %v: %s", cmd, err, out)
			}
			return nil
		}
	}
	running := true
	e := e2eStack(t, c, "") // no key: the live copy is unavailable, the operator consented to a stop
	e.ContainerRunning = func(_ context.Context, name string) bool { return name == coreContainer && running }
	stop := run(stopCmd)
	start := run(startCmd)
	var t0 int64
	e.StopCore = func(ctx context.Context) error {
		t0 = time.Now().UnixNano() // acknowledged before the stop = must be in the copy
		err := stop(ctx)
		if err == nil {
			running = false
		}
		return err
	}
	e.StartCore = func(ctx context.Context) error {
		err := start(ctx)
		if err == nil {
			running = true
		}
		return err
	}
	archive := filepath.Join(c.out, "cold.tar.gz")
	_ = os.Remove(archive)
	man, err := Backup(ctx, e, archive, BackupOptions{StopCore: true, Log: testLog{t}})
	if err != nil {
		t.Fatalf("backup: %v", err)
	}
	if man.Core.Mode != CoreCold || man.Core.StoppedSeconds < 1 {
		t.Fatalf("capture %+v", man.Core)
	}
	if !WaitCoreHealthy(ctx, c.url, time.Minute) {
		t.Fatalf("Core did not come back after the cold copy")
	}
	t.Logf("core: %s; %d files, %d bytes", man.Semantics["core"], man.Core.Files, man.Core.Bytes)
	restored := filepath.Join(c.out, "restored-cold")
	_ = os.RemoveAll(restored)
	re := Env{Home: filepath.Join(restored, "home"), CoreDir: filepath.Join(restored, "data"),
		GatewayDir: filepath.Join(restored, "g"), EngineDir: filepath.Join(restored, "e"), CopilotDir: filepath.Join(restored, "c")}
	if err := os.MkdirAll(re.Home, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(ctx, re, archive, RestoreOptions{Only: []string{"core"}}); err != nil {
		t.Fatalf("restore: %v", err)
	}
	writeJSON(t, filepath.Join(c.out, "cold.json"), map[string]any{
		"t0": t0, "stopped_seconds": man.Core.StoppedSeconds, "files": man.Core.Files, "bytes": man.Core.Bytes,
		"restored": re.CoreDir, "semantics": man.Semantics["core"],
	})
}
