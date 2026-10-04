// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

package databackup

// The client side of Core's backup lease (Core: docs/backup-lease.md,
// src/server/rest_backup.c). A lease is how fp backup copies Core's data
// directory while Core runs: Core holds every deletion and rewrite that could
// tear the copy, lists every file with the exact number of bytes to copy,
// and at the end snapshots its catalog under the catalog's own lock.
//
//	GET    /api/v1/_system/backup/capability   {"lease":1,...}
//	POST   /api/v1/_system/backup              begin: the files to copy
//	POST   /api/v1/_system/backup/{id}/catalog the catalog snapshot
//	GET    /api/v1/_system/backup/{id}         the lease's state
//	DELETE /api/v1/_system/backup/{id}         release (idempotent)
//
// Every route needs SYSTEM_BACKUP. fp backup uses an API key scoped to that
// permission alone (FP_BACKUP_KEY in the stack's .env), which Core confines to
// these routes.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path"
	"regexp"
	"strings"
	"time"
)

// BackupKeyPermission is the one permission the backup key carries.
const BackupKeyPermission = "SYSTEM_BACKUP"

// BackupKeyEnv is the .env key that holds the backup-scoped API key.
const BackupKeyEnv = "FP_BACKUP_KEY"

// ErrNoLease means this Core has no backup lease: it is older than the
// release that adds one.
var ErrNoLease = errors.New("this Core has no backup lease (it is older than the release that adds one)")

// APIError is a refusal from Core: the HTTP status and Core's own sentence.
type APIError struct {
	Method, Path string
	Status       int
	Message      string // Core's {"error": ...}, or the body's start
	State        string // the lease state, when Core gave one
}

func (e *APIError) Error() string {
	msg := e.Message
	if msg == "" {
		msg = http.StatusText(e.Status)
	}
	return fmt.Sprintf("%s %s: HTTP %d: %s", e.Method, e.Path, e.Status, msg)
}

// Capability is Core's answer to the capability probe.
type Capability struct {
	Lease            int `json:"lease"`
	MaxTTLSeconds    int `json:"max_ttl_s"`
	CatalogWaitCapMS int `json:"catalog_wait_cap_ms"`
	DefaultTTL       int `json:"default_ttl_s"`
	DefaultWALCapPct int `json:"default_wal_cap_pct"`
}

// LeaseFile is one file Core lists: copy exactly Length bytes of Path.
type LeaseFile struct {
	Path   string `json:"path"`
	Length int64  `json:"length"`
}

// Lease is Core's answer to begin.
type Lease struct {
	ID          string      `json:"id"`
	State       string      `json:"state"`
	DataDir     string      `json:"data_dir"`
	StartedAt   string      `json:"started_at"`
	ExpiresAt   string      `json:"expires_at"`
	TTLSeconds  int         `json:"ttl_s"`
	WALCapBytes int64       `json:"wal_cap_bytes"`
	FreeBytes   int64       `json:"free_bytes"`
	FileCount   int         `json:"file_count"`
	TotalBytes  int64       `json:"total_bytes"`
	Files       []LeaseFile `json:"files"`
	Exclude     []string    `json:"exclude"`
}

// SnapshotFile is one file of the catalog snapshot: copy Path whole and
// archive it as RestoreAs.
type SnapshotFile struct {
	Path      string `json:"path"`
	RestoreAs string `json:"restore_as"`
}

// Snapshot is Core's answer to the catalog call.
type Snapshot struct {
	ID              string         `json:"id"`
	Files           []SnapshotFile `json:"files"`
	CatalogSequence uint64         `json:"catalog_sequence"`
	CatalogWaitMS   uint64         `json:"catalog_wait_ms"`
}

// LeaseStatus is a lease's state.
type LeaseStatus struct {
	ID           string `json:"id"`
	State        string `json:"state"` // active | aborted | expired
	Since        string `json:"since"`
	ExpiresAt    string `json:"expires_at"`
	HeldWALBytes int64  `json:"held_wal_bytes"`
	WALCapBytes  int64  `json:"wal_cap_bytes"`
	Reason       string `json:"reason"`
}

// coreClient talks to Core's REST API with one bearer token.
type coreClient struct {
	base  string
	token string
	http  *http.Client
}

func newCoreClient(base, token string) *coreClient {
	// No overall timeout: begin walks the whole data directory and answers
	// with every file, which takes time on a large plant. Each call is bounded
	// by its context instead.
	return &coreClient{base: strings.TrimRight(base, "/"), token: token, http: &http.Client{}}
}

// do sends one request. A 2xx answer is decoded into out (when non-nil);
// anything else is an *APIError carrying Core's sentence.
func (c *coreClient) do(ctx context.Context, method, p string, body any, want int, out any) error {
	var rd io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+p, rd)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 || (want != 0 && resp.StatusCode != want) {
		e := &APIError{Method: method, Path: p, Status: resp.StatusCode}
		var refusal struct {
			Error   string `json:"error"`
			Message string `json:"message"`
			State   string `json:"state"`
		}
		if json.Unmarshal(data, &refusal) == nil {
			e.Message, e.State = refusal.Error, refusal.State
			if e.Message == "" {
				e.Message = refusal.Message
			}
		}
		if e.Message == "" {
			e.Message = strings.TrimSpace(string(data))
			if len(e.Message) > 200 {
				e.Message = e.Message[:200] + "…"
			}
		}
		return e
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("%s %s: unreadable answer: %w", method, p, err)
	}
	return nil
}

// Capability probes for the lease. Only an answer that says "lease":1 is
// lease support: an older Core matches this path to GET /api/v1/_system (Core
// routes by prefix) and answers an admin 200 with other JSON, and 404, 401 or
// 403 otherwise. Those all mean ErrNoLease when the token is an admin's; the
// caller tells a refused key apart by the *APIError.
func (c *coreClient) Capability(ctx context.Context) (Capability, error) {
	var capab Capability
	err := c.do(ctx, http.MethodGet, "/api/v1/_system/backup/capability", nil, 0, &capab)
	if err != nil {
		var ae *APIError
		if errors.As(err, &ae) && ae.Status == http.StatusNotFound {
			return capab, ErrNoLease
		}
		return capab, err
	}
	if capab.Lease != 1 {
		return capab, ErrNoLease
	}
	return capab, nil
}

// Begin starts a lease. ttl 0 lets Core choose (its default, 2 h); the WAL
// cap is left to Core's default (25% of the free space).
func (c *coreClient) Begin(ctx context.Context, ttl time.Duration) (Lease, error) {
	var l Lease
	body := map[string]any{}
	if ttl > 0 {
		body["ttl_s"] = int64(ttl / time.Second)
	}
	err := c.do(ctx, http.MethodPost, "/api/v1/_system/backup", body, http.StatusCreated, &l)
	return l, err
}

// CatalogSnapshot asks Core to snapshot its catalog for lease id.
func (c *coreClient) CatalogSnapshot(ctx context.Context, id string) (Snapshot, error) {
	var s Snapshot
	err := c.do(ctx, http.MethodPost, "/api/v1/_system/backup/"+id+"/catalog", nil, http.StatusOK, &s)
	return s, err
}

// Status reads a lease's state.
func (c *coreClient) Status(ctx context.Context, id string) (LeaseStatus, error) {
	var s LeaseStatus
	err := c.do(ctx, http.MethodGet, "/api/v1/_system/backup/"+id, nil, http.StatusOK, &s)
	return s, err
}

// Release ends a lease: Core releases its holds and deletes .fp-backup/<id>/.
// Idempotent.
func (c *coreClient) Release(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodDelete, "/api/v1/_system/backup/"+id, nil, http.StatusOK, nil)
}

// ── Lease answers are checked before anything is copied ──────────────────

var leaseIDRE = regexp.MustCompile(`^[0-9a-f]{32}$`)

// cleanRel reports whether p is a plain relative path inside the data
// directory: slash-separated, clean, no "..", not absolute.
func cleanRel(p string) bool {
	if p == "" || strings.HasPrefix(p, "/") || strings.ContainsAny(p, "\\\x00") || path.Clean(p) != p {
		return false
	}
	for _, part := range strings.Split(p, "/") {
		if part == ".." || part == "." || part == "" {
			return false
		}
	}
	return true
}

// underBackupDir reports whether rel lies in Core's .fp-backup/ area, which
// is never archived on its own and never restored.
func underBackupDir(rel string) bool {
	return rel == coreBackupDir || strings.HasPrefix(rel, coreBackupDir+"/")
}

const coreBackupDir = ".fp-backup"

func (l Lease) check() error {
	if !leaseIDRE.MatchString(l.ID) {
		return fmt.Errorf("Core answered begin with an unusable lease id %q", l.ID)
	}
	seen := make(map[string]bool, len(l.Files))
	for _, f := range l.Files {
		if !cleanRel(f.Path) || underBackupDir(f.Path) {
			return fmt.Errorf("Core listed an unusable path %q", f.Path)
		}
		if f.Length < 0 {
			return fmt.Errorf("Core listed %s with a negative length", f.Path)
		}
		if seen[f.Path] {
			return fmt.Errorf("Core listed %s twice", f.Path)
		}
		seen[f.Path] = true
	}
	return nil
}

func (s Snapshot) check(id string, listed map[string]bool) error {
	prefix := coreBackupDir + "/" + id + "/"
	seen := map[string]bool{}
	for _, f := range s.Files {
		if !cleanRel(f.Path) || !strings.HasPrefix(f.Path, prefix) {
			return fmt.Errorf("Core's catalog snapshot names an unusable path %q", f.Path)
		}
		if !cleanRel(f.RestoreAs) || underBackupDir(f.RestoreAs) {
			return fmt.Errorf("Core's catalog snapshot names an unusable restore path %q", f.RestoreAs)
		}
		if listed[f.RestoreAs] || seen[f.RestoreAs] {
			return fmt.Errorf("Core's catalog snapshot restores %s, which is already in the copy", f.RestoreAs)
		}
		seen[f.RestoreAs] = true
	}
	return nil
}

// ── The backup key ──────────────────────────────────────────────────────

// KeyState is what Core says about the backup key in .env.
type KeyState int

const (
	KeyOK          KeyState = iota // Core accepts it and has a lease
	KeyAbsent                      // .env holds none
	KeyRefused                     // Core answered 401/403: revoked, or minted on another Core
	KeyNoLease                     // Core has no backup lease
	KeyUnreachable                 // Core did not answer
)

// CheckBackupKey asks Core whether key works for a backup.
func CheckBackupKey(ctx context.Context, baseURL, key string) (KeyState, error) {
	if key == "" {
		return KeyAbsent, nil
	}
	_, err := newCoreClient(baseURL, key).Capability(ctx)
	var ae *APIError
	switch {
	case err == nil:
		return KeyOK, nil
	case errors.Is(err, ErrNoLease):
		return KeyNoLease, err
	case errors.As(err, &ae) && (ae.Status == http.StatusUnauthorized || ae.Status == http.StatusForbidden):
		return KeyRefused, err
	default:
		return KeyUnreachable, err
	}
}

// PublicCapabilities is the part of Core's public GET /api/v1/capabilities
// fp backup reads without credentials.
type PublicCapabilities struct {
	Version     string `json:"version"`
	BackupLease *struct {
		Lease int `json:"lease"`
	} `json:"backup_lease"`
}

// LeaseAdvertised reports whether Core's public capability document offers
// the backup lease. It needs no credentials, so fp backup asks for an admin
// login (to mint the backup key) only on a Core that can use one. It is a
// hint: the authenticated probe is what decides.
func LeaseAdvertised(ctx context.Context, baseURL string) (PublicCapabilities, bool, error) {
	var pc PublicCapabilities
	err := newCoreClient(baseURL, "").do(ctx, http.MethodGet, "/api/v1/capabilities", nil, 0, &pc)
	return pc, err == nil && pc.BackupLease != nil && pc.BackupLease.Lease == 1, err
}

// MintBackupKey makes the backup-scoped API key with an admin's token.
//
// It mints only after the capability probe answered "lease":1, and checks
// that Core's answer lists exactly SYSTEM_BACKUP: an older Core ignores a
// permission name it does not know, and a key minted with no known
// permission inherits ALL of its owner's, which would put an admin key in
// .env. A key minted with anything else is revoked at once.
func MintBackupKey(ctx context.Context, baseURL, adminToken string) (string, error) {
	c := newCoreClient(baseURL, adminToken)
	if _, err := c.Capability(ctx); err != nil {
		return "", err
	}
	var minted struct {
		Token       string   `json:"token"`
		ID          string   `json:"id"`
		Permissions []string `json:"permissions"`
	}
	err := c.do(ctx, http.MethodPost, "/api/v1/tokens", map[string]any{
		"name":         "fp-backup",
		"expires_days": 0,
		"permissions":  []string{BackupKeyPermission},
	}, http.StatusCreated, &minted)
	if err != nil {
		return "", err
	}
	if len(minted.Permissions) != 1 || minted.Permissions[0] != BackupKeyPermission || minted.Token == "" {
		revoked := "it was revoked"
		if minted.ID == "" {
			revoked = "Core gave no id to revoke it by: revoke it in Settings › API tokens"
		} else if err := c.do(ctx, http.MethodDelete, "/api/v1/tokens/"+minted.ID, nil, 0, nil); err != nil {
			revoked = fmt.Sprintf("revoking it failed (%v): revoke the key named fp-backup in Settings › API tokens", err)
		}
		return "", fmt.Errorf("Core minted a key with permissions %v instead of %s alone; %s", minted.Permissions, BackupKeyPermission, revoked)
	}
	return minted.Token, nil
}
