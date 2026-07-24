// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

// Package auth prompts for admin credentials and enforces role checks.
package auth

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/actions"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
	"golang.org/x/term"
)

// ErrNotAdmin is returned when the authenticated user isn't admin.
var ErrNotAdmin = errors.New("only administrator accounts can perform this operation")

// PromptAdmin reads username + password from the TTY and authenticates.
// The returned client has its token set on success.
func PromptAdmin(ctx context.Context, reason string) (*api.Client, string, string, error) {
	fmt.Fprintln(os.Stderr, reason)
	fmt.Fprint(os.Stderr, "Admin username [admin]: ")
	reader := bufio.NewReader(os.Stdin)
	user, _ := reader.ReadString('\n')
	for len(user) > 0 && (user[len(user)-1] == '\n' || user[len(user)-1] == '\r') {
		user = user[:len(user)-1]
	}
	if user == "" {
		user = "admin"
	}

	fmt.Fprint(os.Stderr, "Admin password: ")
	passBytes, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return nil, "", "", err
	}
	pass := string(passBytes)

	cli := actions.NewAPIClient()
	if err := cli.Login(ctx, user, pass); err != nil {
		return nil, "", "", err
	}
	isAdmin, err := cli.IsAdmin(ctx)
	if err != nil {
		return nil, "", "", err
	}
	if !isAdmin {
		return nil, "", "", ErrNotAdmin
	}
	return cli, user, pass, nil
}

// PromptCredentials reads username + password from the TTY without making
// any network calls — useful when a command needs the credentials for
// purely local work (e.g. decrypting a .fpconfig backup file with no
// Core server present). The returned values are unverified.
func PromptCredentials(reason string) (string, string, error) {
	fmt.Fprintln(os.Stderr, reason)
	fmt.Fprint(os.Stderr, "Admin username [admin]: ")
	reader := bufio.NewReader(os.Stdin)
	user, _ := reader.ReadString('\n')
	for len(user) > 0 && (user[len(user)-1] == '\n' || user[len(user)-1] == '\r') {
		user = user[:len(user)-1]
	}
	if user == "" {
		user = "admin"
	}
	fmt.Fprint(os.Stderr, "Admin password: ")
	passBytes, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", "", err
	}
	return user, string(passBytes), nil
}

// PromptAdminWithRetry wraps PromptAdmin with an inline-error retry loop. On
// each failed attempt it prints the error to stderr and re-prompts, up to
// maxAttempts. After exhaustion it returns the last error along with a final
// "too many attempts" message. Mirrors the macOS authenticateWithRetry and
// Windows AuthenticateWithRetryAsync helpers.
func PromptAdminWithRetry(ctx context.Context, reason string, maxAttempts int) (*api.Client, string, string, error) {
	if maxAttempts < 1 {
		maxAttempts = 3
	}
	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		cli, user, pass, err := PromptAdmin(ctx, reason)
		if err == nil {
			return cli, user, pass, nil
		}
		lastErr = err
		if attempt < maxAttempts {
			fmt.Fprintf(os.Stderr, "[error] %s\n\n", err.Error())
		}
	}
	fmt.Fprintf(os.Stderr, "\n[error] Too many failed attempts — aborting.\n")
	return nil, "", "", lastErr
}
