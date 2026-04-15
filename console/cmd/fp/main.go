// fp is the FalconPulsar control CLI.
//
//	fp                  Launch the Midnight-Commander-style TUI
//	fp status [--json]  Stack status (colored / JSON)
//	fp start | stop | restart
//	fp logs [service]
//	fp open             Open Web UI in default browser
//	fp config edit [core|gateway|compose]
//	fp config export <file>
//	fp config import <file>
//	fp about | docs | request-feature | uninstall
//	fp tui              Explicit TUI launch
//
// Sub-commands run in pure-CLI mode (line output, colors auto-detect TTY,
// machine-readable via --json). Running `fp` with no args launches the
// full-screen console UI.
package main

import (
	"fmt"
	"os"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/cli"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/tui"
)

func main() {
	root := cli.Root(func() error { return tui.Run() })
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "fp:", err)
		os.Exit(1)
	}
}
