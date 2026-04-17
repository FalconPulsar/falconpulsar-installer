// Package cli wires up cobra subcommands for `fp`.
package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/actions"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/auth"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/configbackup"
	"github.com/spf13/cobra"
)

const Version = "0.1.0"

// Root returns the top-level `fp` command (with all subcommands registered).
// If invoked with no subcommand or explicit `tui`, the caller should launch
// the TUI; this package exposes the subcommands but does not import tview,
// so the tview-backed UI is dispatched by main.go.
func Root(runTUI func() error) *cobra.Command {
	root := &cobra.Command{
		Use:           "fp",
		Short:         "FalconPulsar control CLI",
		Long:          "FalconPulsar control CLI — run without arguments for the interactive console.",
		Version:       Version,
		SilenceUsage:  true,
		SilenceErrors: false,
		RunE: func(cmd *cobra.Command, args []string) error {
			// No subcommand → launch TUI
			return runTUI()
		},
	}

	root.AddCommand(
		cmdTUI(runTUI),
		cmdStatus(),
		cmdStart(),
		cmdStop(),
		cmdRestart(),
		cmdLogs(),
		cmdOpen(),
		cmdConfig(),
		cmdAI(),
		cmdAbout(),
		cmdDocs(),
		cmdRequestFeature(),
		cmdUninstall(),
	)
	return root
}

// ── Commands ────────────────────────────────────────────────────────────────

func cmdTUI(runTUI func() error) *cobra.Command {
	return &cobra.Command{
		Use:   "tui",
		Short: "Launch the interactive console UI",
		RunE:  func(cmd *cobra.Command, args []string) error { return runTUI() },
	}
}

func cmdStatus() *cobra.Command {
	var asJSON bool
	c := &cobra.Command{
		Use:   "status",
		Short: "Show stack status (Core, UI, AI Capabilities, REST API)",
		RunE: func(cmd *cobra.Command, args []string) error {
			st := actions.Poll(context.Background())
			if asJSON {
				enc := json.NewEncoder(os.Stdout)
				enc.SetIndent("", "  ")
				return enc.Encode(map[string]any{
					"core":       st.Core,
					"ui":         st.UI,
					"gateway":    st.Gateway,
					"api":        st.APIHealthy,
					"aggregate":  st.Aggregate(),
				})
			}
			printRow := func(name string, ok bool, note string) {
				mark := colorText("✗", colorRed)
				state := colorText("stopped", colorRed)
				if ok {
					mark = colorText("✓", colorGreen)
					state = colorText("running", colorGreen)
				}
				fmt.Printf("  %s  %-12s %s  %s\n", mark, name, state, note)
			}
			fmt.Println("FalconPulsar status:")
			printRow("Core", st.Core, "")
			printRow("Web UI", st.UI, "http://localhost:8080")
			if actions.AIGatewayEnabled() {
				printRow("AI Capabilities", st.Gateway, "")
			} else {
				fmt.Printf("  %s  %-12s %s\n",
					colorText("–", colorYellow), "AI Capabilities",
					colorText("disabled", colorYellow))
			}
			printRow("REST API", st.APIHealthy, "http://localhost:7433")
			fmt.Printf("\nAggregate: %s\n", st.Aggregate())
			// Exit code tells scripts the overall state
			switch st.Aggregate() {
			case "running":
				os.Exit(0)
			case "partial":
				os.Exit(2)
			default:
				os.Exit(1)
			}
			return nil
		},
	}
	c.Flags().BoolVar(&asJSON, "json", false, "Emit machine-readable JSON")
	return c
}

func cmdStart() *cobra.Command {
	return &cobra.Command{
		Use:   "start",
		Short: "Start the FalconPulsar stack",
		RunE: func(cmd *cobra.Command, args []string) error {
			return actions.Compose(context.Background(), os.Stdout, os.Stderr, "up", "-d")
		},
	}
}

func cmdStop() *cobra.Command {
	return &cobra.Command{
		Use:   "stop",
		Short: "Stop the FalconPulsar stack",
		RunE: func(cmd *cobra.Command, args []string) error {
			return actions.Compose(context.Background(), os.Stdout, os.Stderr, "down")
		},
	}
}

func cmdRestart() *cobra.Command {
	return &cobra.Command{
		Use:   "restart",
		Short: "Restart the FalconPulsar stack",
		RunE: func(cmd *cobra.Command, args []string) error {
			return actions.Compose(context.Background(), os.Stdout, os.Stderr, "restart")
		},
	}
}

func cmdLogs() *cobra.Command {
	return &cobra.Command{
		Use:   "logs [service]",
		Short: "Tail logs for a service (or all services if unspecified)",
		RunE: func(cmd *cobra.Command, args []string) error {
			composeArgs := []string{"logs", "-f", "--tail", "200"}
			if len(args) > 0 {
				composeArgs = append(composeArgs, args[0])
			}
			return actions.Compose(context.Background(), os.Stdout, os.Stderr, composeArgs...)
		},
	}
}

func cmdOpen() *cobra.Command {
	return &cobra.Command{
		Use:   "open",
		Short: "Open the FalconPulsar Web UI in the default browser",
		RunE: func(cmd *cobra.Command, args []string) error {
			return actions.OpenURL("http://localhost:8080")
		},
	}
}

func cmdConfig() *cobra.Command {
	c := &cobra.Command{
		Use:   "config",
		Short: "Edit and back up FalconPulsar configuration",
	}
	c.AddCommand(
		&cobra.Command{
			Use:   "edit [core|gateway|compose]",
			Short: "Open a config file in $EDITOR",
			Args:  cobra.ExactArgs(1),
			RunE: func(cmd *cobra.Command, args []string) error {
				var name string
				switch args[0] {
				case "core":
					name = filepath.Join("data", "falconpulsar.toml")
				case "gateway":
					name = "gateway.yaml"
				case "compose":
					name = "compose.yml"
				default:
					return fmt.Errorf("unknown config: %s (want: core|gateway|compose)", args[0])
				}
				return actions.EditFile(filepath.Join(actions.HomeDir(), name))
			},
		},
		cmdConfigExport(),
		cmdConfigImport(),
	)
	return c
}

func cmdConfigExport() *cobra.Command {
	return &cobra.Command{
		Use:   "export <file>",
		Short: "Export configuration to an encrypted .fpconfig file (admin-only)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := context.Background()
			cli, user, pass, err := auth.PromptAdmin(ctx,
				"Export Configuration — admin credentials will encrypt the backup file.")
			if err != nil {
				return err
			}
			if err := configbackup.Export(ctx, args[0], cli, user, pass); err != nil {
				return err
			}
			fmt.Fprintf(os.Stderr, "Saved to %s\n", args[0])
			return nil
		},
	}
}

func cmdConfigImport() *cobra.Command {
	return &cobra.Command{
		Use:   "import <file>",
		Short: "Import an encrypted .fpconfig file (admin-only)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := context.Background()
			cli, user, pass, err := auth.PromptAdmin(ctx,
				"Import Configuration — enter the credentials used when the backup was exported.")
			if err != nil {
				return err
			}
			if err := configbackup.Import(ctx, args[0], cli, user, pass); err != nil {
				return err
			}
			fmt.Fprintln(os.Stderr, "Import complete. Restart the stack (fp restart) for all changes to take effect.")
			return nil
		},
	}
}

func cmdAI() *cobra.Command {
	c := &cobra.Command{
		Use:   "ai",
		Short: "Enable, disable, or check AI Capabilities status",
	}
	c.AddCommand(
		&cobra.Command{
			Use:   "status",
			Short: "Show whether AI Capabilities is enabled",
			RunE: func(cmd *cobra.Command, args []string) error {
				if actions.AIGatewayEnabled() {
					fmt.Println(colorText("AI Capabilities: enabled", colorGreen))
				} else {
					fmt.Println(colorText("AI Capabilities: disabled", colorYellow))
				}
				return nil
			},
		},
		&cobra.Command{
			Use:   "enable",
			Short: "Enable AI Capabilities and start the gateway container",
			RunE: func(cmd *cobra.Command, args []string) error {
				ctx := context.Background()
				// Bootstrap gateway service token if missing (first-time enable)
				if !actions.HasGatewayToken() {
					fmt.Fprintln(os.Stderr, "First-time AI enable — bootstrapping gateway service token…")
					cli, _, _, err := auth.PromptAdmin(ctx,
						"Admin credentials are needed to create the AI service token (one-time only).")
					if err != nil {
						return err
					}
					_ = cli // token bootstrap uses the auth'd client
				}
				actions.EnsureGatewayConfig()
				if err := actions.SetEnvValue("FP_AI_GATEWAY_ENABLED", "true"); err != nil {
					return err
				}
				fmt.Fprintln(os.Stderr, "Enabling AI Capabilities…")
				if err := actions.Compose(ctx, os.Stdout, os.Stderr, "up", "-d"); err != nil {
					return err
				}
				fmt.Fprintln(os.Stderr, "AI Capabilities enabled. Configure LLM providers in the Web UI (Settings > AI Configuration).")
				return nil
			},
		},
		&cobra.Command{
			Use:   "disable",
			Short: "Disable AI Capabilities (stops the container, hides AI features in the UI)",
			RunE: func(cmd *cobra.Command, args []string) error {
				if err := actions.SetEnvValue("FP_AI_GATEWAY_ENABLED", "false"); err != nil {
					return err
				}
				fmt.Fprintln(os.Stderr, "AI Capabilities disabled. Restarting stack…")
				ctx := context.Background()
				// Stop gateway explicitly first, then restart without profile
				_ = actions.Compose(ctx, nil, nil, "stop", "ai-gateway")
				return actions.Compose(ctx, os.Stdout, os.Stderr, "up", "-d")
			},
		},
	)
	return c
}

func cmdAbout() *cobra.Command {
	return &cobra.Command{
		Use:   "about",
		Short: "About FalconPulsar",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println(`FalconPulsar`)
			fmt.Printf("Version:  %s\n", Version)
			fmt.Println("Website:  https://falconpulsar.com")
			fmt.Println("Docs:     https://falconpulsar.com/docs")
			fmt.Println("Roadmap:  https://falconpulsar.com/roadmap")
			fmt.Println("(c) 2026 FalconPulsar Contributors — Apache 2.0")
			return nil
		},
	}
}

func cmdDocs() *cobra.Command {
	return &cobra.Command{
		Use:   "docs",
		Short: "Open the documentation site",
		RunE: func(cmd *cobra.Command, args []string) error {
			return actions.OpenURL("https://falconpulsar.com/docs")
		},
	}
}

func cmdRequestFeature() *cobra.Command {
	return &cobra.Command{
		Use:   "request-feature",
		Short: "Open the roadmap feature-request form",
		RunE: func(cmd *cobra.Command, args []string) error {
			return actions.OpenURL("https://falconpulsar.com/roadmap#request-form")
		},
	}
}

func cmdUninstall() *cobra.Command {
	return &cobra.Command{
		Use:   "uninstall",
		Short: "Run the FalconPulsar uninstaller",
		RunE: func(cmd *cobra.Command, args []string) error {
			// Look for uninstall.sh next to the stack; fall back to system path.
			candidates := []string{
				filepath.Join(actions.HomeDir(), "uninstall.sh"),
				"/usr/local/share/falconpulsar/uninstall.sh",
			}
			for _, p := range candidates {
				if _, err := os.Stat(p); err == nil {
					return actions.EditFile(p) // opens for review; user runs it manually
				}
			}
			fmt.Fprintln(os.Stderr, "Uninstaller not found. Re-run the installer and choose Uninstall there.")
			return nil
		},
	}
}

// ── small ANSI helpers ─────────────────────────────────────────────────────

const (
	colorReset  = "\033[0m"
	colorGreen  = "\033[32m"
	colorRed    = "\033[31m"
	colorYellow = "\033[33m"
	colorBlue   = "\033[34m"
	colorCyan   = "\033[36m"
)

func colorText(s, color string) string {
	if !isTTY() {
		return s
	}
	return color + s + colorReset
}

func isTTY() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}
