// Package cli wires up cobra subcommands for `fp`.
package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
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

				// Admin auth required every time (matches macOS menu bar
				// and Windows tray behaviour). On first enable this call
				// also provides the JWT needed to bootstrap the gateway
				// service token.
				reason := "Admin credentials are required to enable AI Capabilities."
				if !actions.HasGatewayToken() {
					reason = "First-time setup: admin credentials are needed to create the AI service token."
				}
				cli, _, _, err := auth.PromptAdminWithRetry(ctx, reason, 3)
				if err != nil {
					return err
				}

				if !actions.HasGatewayToken() {
					token, err := cli.CreateGatewayToken(ctx)
					if err != nil {
						return fmt.Errorf("create gateway service token: %w", err)
					}
					if err := actions.SetEnvValue("FP_API_KEY", token); err != nil {
						return fmt.Errorf("write FP_API_KEY: %w", err)
					}
				}

				actions.EnsureGatewayConfig()
				if err := actions.SetEnvValue("FP_AI_GATEWAY_ENABLED", "true"); err != nil {
					return err
				}
				fmt.Fprintln(os.Stderr, "Enabling AI Capabilities…")
				if err := actions.Compose(ctx, os.Stdout, os.Stderr, "--profile", "ai",
					"pull", "ai-gateway"); err != nil {
					return err
				}
				if err := actions.Compose(ctx, os.Stdout, os.Stderr, "--profile", "ai",
					"up", "-d", "ai-gateway"); err != nil {
					return err
				}
				fmt.Fprintln(os.Stderr, "")
				fmt.Fprintln(os.Stderr, "AI Capabilities enabled.")
				fmt.Fprintln(os.Stderr, "Close any open FalconPulsar Web UI sessions and sign in again to see the AI features, then configure LLM providers in Settings > AI Configuration.")
				return nil
			},
		},
		&cobra.Command{
			Use:   "disable",
			Short: "Disable AI Capabilities (surgical: removes container, data dir, gateway.yaml, FP_API_KEY, and image)",
			RunE: func(cmd *cobra.Command, args []string) error {
				ctx := context.Background()

				// Admin auth required every time (matches macOS / Windows).
				if _, _, _, err := auth.PromptAdminWithRetry(ctx,
					"Admin credentials are required to disable AI Capabilities.", 3); err != nil {
					return err
				}

				if err := actions.SetEnvValue("FP_AI_GATEWAY_ENABLED", "false"); err != nil {
					return err
				}

				fmt.Fprintln(os.Stderr, "Disabling AI Capabilities…")
				// Surgical teardown: container + bind-mount data dir +
				// gateway.yaml + FP_API_KEY + image. Core/UI untouched.
				if err := actions.SurgicalDisableAI(ctx, os.Stderr); err != nil {
					return err
				}
				fmt.Fprintln(os.Stderr, "")
				fmt.Fprintln(os.Stderr, "AI Capabilities disabled and removed.")
				return nil
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
	var purge bool
	var yes bool
	cmd := &cobra.Command{
		Use:   "uninstall",
		Short: "Run the FalconPulsar uninstaller (interactive by default)",
		RunE: func(cmd *cobra.Command, args []string) error {
			// Look for uninstall.sh next to the stack; fall back to system path.
			candidates := []string{
				filepath.Join(actions.HomeDir(), "uninstall.sh"),
				"/usr/local/share/falconpulsar/uninstall.sh",
			}
			var script string
			for _, p := range candidates {
				if _, err := os.Stat(p); err == nil {
					script = p
					break
				}
			}
			if script == "" {
				fmt.Fprintln(os.Stderr, "Uninstaller not found at ~/falconpulsar/uninstall.sh.")
				fmt.Fprintln(os.Stderr, "Re-run the installer to restore it, or run it directly from the installer source tree.")
				return nil
			}

			// Run the uninstaller with the user's flags. --yes is required
			// when --purge is set so the interactive "are you sure?" block
			// doesn't fire, but the bash script still gates on admin auth
			// (prompts directly on stdin) unless --force is passed.
			script = copyToTemp(script)
			defer os.Remove(script)

			scriptArgs := []string{script}
			if purge {
				scriptArgs = append(scriptArgs, "--purge")
			} else {
				scriptArgs = append(scriptArgs, "--keep")
			}
			if yes {
				scriptArgs = append(scriptArgs, "--yes")
			}
			fmt.Fprintln(os.Stderr, "Launching uninstaller…")
			fmt.Fprintln(os.Stderr, "")

			sh := exec.Command("bash", scriptArgs...)
			sh.Dir = "/"
			sh.Stdin = os.Stdin
			sh.Stdout = os.Stdout
			sh.Stderr = os.Stderr
			return sh.Run()
		},
	}
	cmd.Flags().BoolVar(&purge, "purge", false, "Remove database and all data (not just the application)")
	cmd.Flags().BoolVar(&yes, "yes", false, "Non-interactive; assume yes to confirmation prompts")
	return cmd
}

// copyToTemp duplicates the uninstall script to /tmp so bash doesn't die when
// the script's parent directory gets wiped mid-execution.
func copyToTemp(src string) string {
	dst := filepath.Join("/tmp", fmt.Sprintf("fp-uninstall-%d.sh", os.Getpid()))
	if data, err := os.ReadFile(src); err == nil {
		_ = os.WriteFile(dst, data, 0700)
		// Also copy auth.sh alongside if present, so the standalone
		// uninstaller can still require admin credentials.
		if auth, err := os.ReadFile(filepath.Join(filepath.Dir(src), "auth.sh")); err == nil {
			_ = os.WriteFile(filepath.Join("/tmp", "auth.sh"), auth, 0600)
		}
		return dst
	}
	return src
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
