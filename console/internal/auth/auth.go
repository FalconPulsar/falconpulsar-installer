// Package auth prompts for admin credentials and enforces role checks.
package auth

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"

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

	cli := api.New()
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
