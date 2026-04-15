// Package configbackup implements the .fpconfig file format — the cross-platform
// FalconPulsar configuration backup. File format (binary) is identical to the
// macOS Swift and Windows C# implementations. See ConfigBackup.swift /
// ConfigBackup.cs in the repo for the authoritative spec.
//
//	[0..3]   Magic = "FPCF"        (4 bytes)
//	[4]      Format version = 1    (1 byte)
//	[5..20]  PBKDF2 salt           (16 bytes)
//	[21..32] AES-GCM nonce         (12 bytes)
//	[33..]   AES-256-GCM ciphertext of the zip payload
//	[tail 16 bytes] GCM tag
//
// Key = PBKDF2-HMAC-SHA256("<user>:<pass>", salt, 100_000, 32)
// Payload = zip containing manifest.json, files/, api/
package configbackup

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
	"golang.org/x/crypto/pbkdf2"
)

const (
	FormatVersion = 1
	SaltLen       = 16
	NonceLen      = 12
	TagLen        = 16
	Iterations    = 100_000
	KeyLen        = 32
)

var Magic = []byte{0x46, 0x50, 0x43, 0x46} // "FPCF"

func deriveKey(user, pass string, salt []byte) []byte {
	return pbkdf2.Key([]byte(user+":"+pass), salt, Iterations, KeyLen, sha256.New)
}

func encrypt(plain []byte, user, pass string) ([]byte, error) {
	salt := make([]byte, SaltLen)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	nonce := make([]byte, NonceLen)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(deriveKey(user, pass, salt))
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	ct := gcm.Seal(nil, nonce, plain, nil)
	var out bytes.Buffer
	out.Write(Magic)
	out.WriteByte(FormatVersion)
	out.Write(salt)
	out.Write(nonce)
	out.Write(ct)
	return out.Bytes(), nil
}

func decrypt(data []byte, user, pass string) ([]byte, error) {
	head := 4 + 1 + SaltLen + NonceLen
	if len(data) < head+TagLen {
		return nil, errors.New("file too short")
	}
	if !bytes.Equal(data[:4], Magic) {
		return nil, errors.New("not a FalconPulsar backup file (magic mismatch)")
	}
	if data[4] != FormatVersion {
		return nil, fmt.Errorf("unsupported backup format version %d", data[4])
	}
	salt := data[5 : 5+SaltLen]
	nonce := data[5+SaltLen : head]
	ct := data[head:]

	block, err := aes.NewCipher(deriveKey(user, pass, salt))
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return nil, fmt.Errorf("decryption failed — wrong admin credentials or corrupted file")
	}
	return plain, nil
}

// HomeDir resolves the FalconPulsar stack directory (~/falconpulsar).
func HomeDir() string {
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, "falconpulsar")
	}
	return "/root/falconpulsar"
}

// Export reads config + API data, zips, encrypts, writes to output.
func Export(ctx context.Context, output string, cli *api.Client, user, pass string) error {
	var zipBuf bytes.Buffer
	zw := zip.NewWriter(&zipBuf)
	home := HomeDir()

	// manifest.json
	manifest := map[string]any{
		"format_version":       FormatVersion,
		"falconpulsar_version": "0.1.0",
		"exported_at":          time.Now().UTC().Format(time.RFC3339),
		"source_host":          hostname(),
		"source_platform":      runtime.GOOS,
	}
	mb, _ := json.MarshalIndent(manifest, "", "  ")
	if err := writeZipFile(zw, "manifest.json", mb); err != nil {
		return err
	}

	// config files
	for _, name := range []string{"compose.yml", ".env", "gateway.yaml"} {
		p := filepath.Join(home, name)
		if data, err := os.ReadFile(p); err == nil {
			if err := writeZipFile(zw, "files/"+name, data); err != nil {
				return err
			}
		}
	}

	// API endpoints
	for _, ep := range []struct{ name, path string }{
		{"users.json", "/api/v1/users"},
		{"datasources.json", "/api/v1/datasources"},
		{"mappings.json", "/api/v1/mappings"},
		{"assets.json", "/api/v1/assets"},
		{"roles.json", "/api/v1/roles"},
	} {
		if data, err := cli.GetRaw(ctx, ep.path); err == nil {
			_ = writeZipFile(zw, "api/"+ep.name, data)
		}
	}

	if err := zw.Close(); err != nil {
		return err
	}
	ct, err := encrypt(zipBuf.Bytes(), user, pass)
	if err != nil {
		return err
	}
	return os.WriteFile(output, ct, 0600)
}

// Import decrypts, unzips, and pushes config back.
func Import(ctx context.Context, input string, cli *api.Client, user, pass string) error {
	enc, err := os.ReadFile(input)
	if err != nil {
		return err
	}
	plain, err := decrypt(enc, user, pass)
	if err != nil {
		return err
	}
	zr, err := zip.NewReader(bytes.NewReader(plain), int64(len(plain)))
	if err != nil {
		return fmt.Errorf("invalid archive inside backup: %w", err)
	}
	home := HomeDir()
	_ = os.MkdirAll(home, 0755)

	// Index zip entries by path for easy lookup
	entries := map[string]*zip.File{}
	for _, f := range zr.File {
		entries[f.Name] = f
	}

	// Restore config files
	for _, name := range []string{"compose.yml", ".env", "gateway.yaml"} {
		if f, ok := entries["files/"+name]; ok {
			if err := extractTo(f, filepath.Join(home, name)); err != nil {
				return err
			}
		}
	}

	// Push API data (best-effort; some resources may not accept bulk upsert)
	for _, ep := range []struct{ name, path string }{
		{"roles.json", "/api/v1/roles"},
		{"users.json", "/api/v1/users"},
		{"datasources.json", "/api/v1/datasources"},
		{"assets.json", "/api/v1/assets"},
		{"mappings.json", "/api/v1/mappings"},
	} {
		f, ok := entries["api/"+ep.name]
		if !ok {
			continue
		}
		data, err := readZipFile(f)
		if err != nil {
			continue
		}
		var arr []any
		if err := json.Unmarshal(data, &arr); err != nil {
			// some endpoints return {items: [...]}
			var wrapped map[string]any
			if err := json.Unmarshal(data, &wrapped); err == nil {
				if items, ok := wrapped["items"].([]any); ok {
					arr = items
				}
			}
		}
		for _, item := range arr {
			_, _ = cli.PostJSON(ctx, ep.path, item)
		}
	}
	return nil
}

func writeZipFile(zw *zip.Writer, name string, data []byte) error {
	w, err := zw.Create(name)
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

func readZipFile(f *zip.File) ([]byte, error) {
	rc, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

func extractTo(f *zip.File, dst string) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, rc)
	return err
}

func hostname() string {
	if h, err := os.Hostname(); err == nil {
		return h
	}
	return "unknown"
}
