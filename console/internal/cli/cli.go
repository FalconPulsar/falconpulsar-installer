// Package cli wires up cobra subcommands for `fp`.
package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/actions"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/auth"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/configbackup"
	"github.com/spf13/cobra"
)

// Version is the human-visible release version of the fp binary,
// displayed by `fp --version`, `fp about`, and the TUI's About modal.
//
// Declared as a `var` (not `const`) so that build pipelines can inject
// the actual git tag at link time:
//
//   go build -ldflags="-X github.com/falconpulsar/falconpulsar-installer/console/internal/cli.Version=0.1.4-alpha.5" ...
//
// The literal default is kept in sync with the repo-root VERSION file
// by scripts/sync-version.sh (CI lint enforces no drift). CI release
// builds override this via ldflags so the published binary reports
// the actual git tag; unstamped local builds (`go run ./cmd/fp`) fall
// back to whatever this literal currently says — slightly stale but
// not misleading.
var Version = "0.1.3"

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
		cmdUpdate(),
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
		cmdConfigInspect(),
	)
	return c
}

func cmdConfigInspect() *cobra.Command {
	var asJSON bool
	cmd := &cobra.Command{
		Use:   "inspect <file>",
		Short: "Decrypt a .fpconfig file and show what's inside (read-only)",
		Long: `Inspect a .fpconfig backup without applying it.

The command decrypts the file using the admin credentials that were
used at export time, parses the embedded zip, and prints a per-section
summary: file size, format version, manifest fields, stack file sizes,
and item counts for each API section (roles, users, asset-types,
assets, datasources, series, mappings, relationships, annotations).

No network calls are made — this works on machines where FalconPulsar
Core is not running, as long as you have the original admin credentials
used to encrypt the backup.

Use this to verify a backup is well-formed and contains what you expect
before running 'fp config import'.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			user, pass, err := auth.PromptCredentials(
				"Inspect Configuration — enter the admin credentials used at export time.")
			if err != nil {
				return err
			}
			res, err := configbackup.Inspect(args[0], user, pass)
			if err != nil {
				return err
			}
			if asJSON {
				out, _ := json.MarshalIndent(res, "", "  ")
				fmt.Println(string(out))
				return nil
			}
			fmt.Print(res.HumanReadable())
			return nil
		},
	}
	cmd.Flags().BoolVar(&asJSON, "json", false,
		"Emit the inspect report as JSON (suitable for piping to jq).")
	return cmd
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
			summary, err := configbackup.Import(ctx, args[0], cli, user, pass)
			if err != nil {
				return err
			}
			// Show the per-section breakdown so the user can see whether
			// items were skipped (already present) or actually failed.
			fmt.Fprint(os.Stderr, summary.HumanReadable())
			if summary.TotalErrors > 0 {
				fmt.Fprintln(os.Stderr,
					"⚠ Some items failed to import (see counts above). "+
						"Re-run with the source's admin credentials, or "+
						"inspect the listed errors for details.")
			}
			fmt.Fprintln(os.Stderr,
				"Restart the stack (fp restart) for all changes to take effect.")
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

				// SEC-003: provider-key encryption secret (generated once;
				// never rotated implicitly).
				if err := actions.EnsureGatewaySecret(); err != nil {
					return err
				}

				actions.EnsureGatewayConfig()
				if err := actions.SetEnvValue("FP_AI_GATEWAY_ENABLED", "true"); err != nil {
					return err
				}
				fmt.Fprintln(os.Stderr, "Enabling the FalconPulsar Gateway…")
				// Snapshot image IDs before pull so any displaced AI Gateway
				// image gets removed afterward. Re-enabling after a previous
				// disable+upgrade cycle would otherwise leave the prior
				// gateway image as a dangling <none>. Same snapshot-then-
				// cleanup pattern used by ApplyUpdates — see update.go.
				prevImageIDs := actions.SnapshotComposeImageIDs(ctx)
				if err := actions.Compose(ctx, os.Stdout, os.Stderr, "--profile", "ai",
					"pull", "ai-gateway"); err != nil {
					return err
				}
				if err := actions.Compose(ctx, os.Stdout, os.Stderr, "--profile", "ai",
					"up", "-d", "ai-gateway"); err != nil {
					return err
				}
				// Best-effort: remove any captured ID that is now fully
				// untagged (= was displaced by the pull). Errors swallowed.
				_ = actions.RemoveOrphanedImages(ctx, prevImageIDs)
				// Wipe the gateway's self-seeded provider/model catalog so
				// the user lands on a clean AI configuration. See
				// actions.WipeGatewaySeedDefaults for the rationale.
				_ = actions.WipeGatewaySeedDefaults(ctx, os.Stderr)
				fmt.Fprintln(os.Stderr, "")
				fmt.Fprintln(os.Stderr, "AI Capabilities enabled.")
				fmt.Fprintln(os.Stderr, "Close any open FalconPulsar Web UI sessions and sign in again to see the AI features, then configure LLM providers in Settings > AI Configuration.")
				return nil
			},
		},
		&cobra.Command{
			Use:   "disable",
			Short: "Disable the FalconPulsar Gateway (removes container + image; watches, conversations, and AI configuration are preserved)",
			RunE: func(cmd *cobra.Command, args []string) error {
				ctx := context.Background()

				// Admin auth required every time (matches macOS / Windows).
				if _, _, _, err := auth.PromptAdminWithRetry(ctx,
					"Admin credentials are required to disable the FalconPulsar Gateway.", 3); err != nil {
					return err
				}

				if err := actions.SetEnvValue("FP_AI_GATEWAY_ENABLED", "false"); err != nil {
					return err
				}

				fmt.Fprintln(os.Stderr, "Disabling the FalconPulsar Gateway…")
				fmt.Fprintln(os.Stderr, "Note: this also turns off Workspace commands and standing watches.")
				// Non-destructive teardown: container + image only. Data,
				// gateway.yaml, and credentials are preserved (`fp ai purge`
				// is the destructive path). Core/UI untouched.
				if err := actions.SurgicalDisableAI(ctx, os.Stderr); err != nil {
					return err
				}
				fmt.Fprintln(os.Stderr, "")
				fmt.Fprintln(os.Stderr, "Gateway disabled. Your watches, conversations, and AI configuration were preserved and will return when re-enabled (fp ai enable).")
				return nil
			},
		},
		&cobra.Command{
			Use:   "purge",
			Short: "PERMANENTLY delete all gateway data (watches, conversations, AI configuration incl. encrypted provider keys)",
			RunE: func(cmd *cobra.Command, args []string) error {
				ctx := context.Background()

				fmt.Fprintln(os.Stderr, "This PERMANENTLY deletes:")
				fmt.Fprintln(os.Stderr, "  - all standing watches")
				fmt.Fprintln(os.Stderr, "  - all conversation history")
				fmt.Fprintln(os.Stderr, "  - AI configuration, including encrypted provider keys")
				fmt.Fprintln(os.Stderr, "  - gateway.yaml and the gateway service credential")
				fmt.Fprint(os.Stderr, "Type 'purge' to confirm: ")
				answer, _ := bufio.NewReader(os.Stdin).ReadString('\n')
				if strings.TrimSpace(answer) != "purge" {
					fmt.Fprintln(os.Stderr, "Aborted — nothing was deleted.")
					return nil
				}

				// Admin auth required (destructive).
				if _, _, _, err := auth.PromptAdminWithRetry(ctx,
					"Admin credentials are required to purge gateway data.", 3); err != nil {
					return err
				}

				if err := actions.SetEnvValue("FP_AI_GATEWAY_ENABLED", "false"); err != nil {
					return err
				}
				if err := actions.PurgeAIData(ctx, os.Stderr); err != nil {
					return err
				}
				fmt.Fprintln(os.Stderr, "")
				fmt.Fprintln(os.Stderr, "Gateway data purged.")
				return nil
			},
		},
	)
	return c
}

// cmdUpdate exposes the "Check for updates" / "Apply updates" workflow
// to scripts and tray apps. The tray apps shell out to `fp update --check
// --json` for a status snapshot and `fp update --apply` to perform the
// actual upgrade. CLI users can do the same without a tray.
//
// `update` (no flags) defaults to `--check` (read-only, no side effects).
// Adding `--apply` performs the upgrade in place via install.sh's
// fast-path (or an inline pull+recreate if the bundled installer isn't
// found beside `fp`).
//
// The `update-mode` subcommand reads/writes FP_UPDATE_MODE in .env so
// the operator can flip between "manual" (default — never auto-apply,
// just notify) and "auto" (tray applies on detection with a 30s
// cancellable countdown). Tray apps reflect this setting in their
// settings UI; the CLI command exists so headless / scripted setups
// can configure it too.
func cmdUpdate() *cobra.Command {
	var asJSON bool
	var apply bool

	c := &cobra.Command{
		Use:   "update",
		Short: "Check for component updates (or apply with --apply)",
		Long: "Check whether any FalconPulsar component image has a newer\n" +
			"version on the configured registry (FP_REGISTRY). When run with\n" +
			"--apply, performs the upgrade in place via install.sh's fast-path.\n" +
			"\n" +
			"Source of truth for 'is there an update?' is the same Docker\n" +
			"registry the operator already pulls from. No GitHub or external\n" +
			"endpoints are queried — air-gapped and private-registry deploys\n" +
			"work the same as public Docker Hub.",
		RunE: func(cmd *cobra.Command, args []string) error {
			if apply {
				return actions.ApplyUpdates(cmd.Context(), os.Stdout, os.Stderr)
			}
			res := actions.CheckUpdates(cmd.Context())
			if asJSON {
				enc := json.NewEncoder(os.Stdout)
				enc.SetIndent("", "  ")
				return enc.Encode(res)
			}
			fmt.Printf("Registry: %s   Tag: %s\n\n", res.Registry, res.Tag)
			for _, comp := range res.Components {
				switch {
				case comp.ErrorKind != "":
					fmt.Printf("  %s  %-18s registry error (%s)\n",
						colorText("?", colorYellow), comp.Name, comp.ErrorKind)
					if comp.Error != "" {
						fmt.Printf("       %s\n", truncate(comp.Error, 120))
					}
				case comp.UpdateAvailable:
					fmt.Printf("  %s  %-18s update available\n",
						colorText("↑", colorGreen), comp.Name)
					fmt.Printf("       local:  %s\n", shortDigest(comp.LocalDigest))
					fmt.Printf("       remote: %s\n", shortDigest(comp.RemoteDigest))
				case comp.LocalDigest == "":
					fmt.Printf("  %s  %-18s container not running\n",
						colorText("–", colorYellow), comp.Name)
				default:
					fmt.Printf("  %s  %-18s up to date\n",
						colorText("✓", colorGreen), comp.Name)
				}
			}
			fmt.Println()
			switch {
			case res.AnyError:
				fmt.Println("One or more registry probes failed. Check connectivity / credentials.")
				os.Exit(2)
			case res.Any:
				fmt.Println("Run `fp update --apply` to install the update.")
			default:
				fmt.Println("All components are up to date.")
			}
			return nil
		},
	}
	c.Flags().BoolVar(&asJSON, "json", false, "Emit machine-readable JSON (used by tray apps)")
	c.Flags().BoolVar(&apply, "apply", false, "Pull updated images and recreate containers")

	c.AddCommand(cmdUpdateMode())
	return c
}

// cmdUpdateMode: `fp update mode [manual|auto]` — read or set FP_UPDATE_MODE.
func cmdUpdateMode() *cobra.Command {
	return &cobra.Command{
		Use:   "mode [manual|auto]",
		Short: "Read or set the update mode (manual is default; auto applies on detection while the tray is open)",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 {
				fmt.Println(actions.UpdateMode())
				return nil
			}
			if err := actions.SetUpdateMode(args[0]); err != nil {
				return err
			}
			fmt.Printf("update mode set to: %s\n", actions.UpdateMode())
			return nil
		},
	}
}

// truncate returns s capped at n characters, with an ellipsis when shortened.
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

// shortDigest renders "sha256:abcd1234…" for human-readable output.
func shortDigest(d string) string {
	if d == "" {
		return "(none)"
	}
	if len(d) > 19 {
		return d[:19] + "…"
	}
	return d
}

func cmdAbout() *cobra.Command {
	return &cobra.Command{
		Use:   "about",
		Short: "About FalconPulsar",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := context.Background()

			fmt.Println(`FalconPulsar`)
			fmt.Println()
			fmt.Printf("Installer:        v%s\n", Version)
			fmt.Printf("Stack dir:        %s\n", actions.HomeDir())
			fmt.Println()

			// Per-component versions read from each container's OCI labels.
			// When a container is stopped (or the version label hasn't been
			// updated upstream) GetContainerInfo gracefully falls back --
			// see the function's docstring for the resolution order.
			fmt.Println("Components:")
			fmt.Printf("  Core Engine     %s\n", actions.GetContainerInfo(ctx, "falconpulsar-core").DisplayString())
			fmt.Printf("  Web UI          %s\n", actions.GetContainerInfo(ctx, "falconpulsar-ui").DisplayString())
			if actions.AIGatewayEnabled() {
				fmt.Printf("  AI Capabilities %s\n", actions.GetContainerInfo(ctx, "falconpulsar-ai-gateway").DisplayString())
			} else {
				fmt.Printf("  AI Capabilities %s\n", colorText("(disabled)", colorYellow))
			}
			fmt.Printf("  Compose         %s\n", actions.GetComposeVersion(ctx))
			fmt.Println()

			// Local endpoints -- duplicated in the TUI About modal and
			// useful here for shell pipelines (e.g. piping to grep to
			// extract a port number for a script).
			fmt.Println("Endpoints:")
			fmt.Println("  Web UI          http://localhost:8080")
			fmt.Println("  REST API        http://localhost:7433")
			fmt.Println("  AI Gateway      http://localhost:7436")
			fmt.Println()

			fmt.Println("Website:          https://falconpulsar.com")
			fmt.Println("Docs:             https://falconpulsar.com/docs")
			fmt.Println("Roadmap:          https://falconpulsar.com/roadmap")
			fmt.Println("(c) 2026 FalconPulsar Contributors — GNU AGPL v3")
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
			// On WSL the install has BOTH a Linux side (containers, /home
			// stack dir) AND a Windows side (Tray app, fp.exe wrapper,
			// Start Menu, Add/Remove Programs entry, HKCU Run key). The
			// bash uninstall.sh inside WSL can only touch the Linux half.
			// Hand off to the Inno Setup uninstaller on Windows -- it
			// removes its own files AND calls windows/helpers/uninstall.ps1
			// which cleans the WSL side. One entry point, both halves done.
			if isWSL() {
				return runWindowsUninstaller(purge, yes)
			}

			// Native Linux / macOS: run the bash uninstaller directly.
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

// isWSL returns true when this binary is running inside a WSL distro.
// Both markers are official: the binfmt entry is what lets us run .exe
// files via interop, and the kernel name carries "microsoft"/"WSL".
func isWSL() bool {
	if _, err := os.Stat("/proc/sys/fs/binfmt_misc/WSLInterop"); err == nil {
		return true
	}
	if data, err := os.ReadFile("/proc/version"); err == nil {
		s := strings.ToLower(string(data))
		if strings.Contains(s, "microsoft") || strings.Contains(s, "wsl") {
			return true
		}
	}
	return false
}

// runWindowsUninstaller execs the Inno Setup uninstaller (unins000.exe)
// via WSL->Windows interop. It's the only Windows-side tool that can
// clean Program Files, the Start Menu folder, the Add/Remove Programs
// entry, and the HKCU Run key. Inno Setup's CurUninstallStepChanged
// in turn calls our uninstall.ps1 for the WSL container/data cleanup.
//
// FP_UNINSTALL_MODE=purge|keep is forwarded via WSLENV so the Inno
// Setup [Code] block can skip its interactive Yes/No/Cancel MsgBox
// when the user already said --purge or default-keep on the fp CLI.
func runWindowsUninstaller(purge, yes bool) error {
	const uninst = "/mnt/c/Program Files/FalconPulsar/unins000.exe"
	if _, err := os.Stat(uninst); err != nil {
		return fmt.Errorf("Windows uninstaller not found at %s\n"+
			"Open 'Settings > Apps > FalconPulsar > Uninstall' instead, or run the bash\n"+
			"uninstaller directly: bash %s/uninstall.sh", uninst, actions.HomeDir())
	}

	mode := "keep"
	if purge {
		mode = "purge"
	}
	// WSLENV with /u tells WSL to forward this var from Linux env to the
	// spawned Windows process. Without it, env vars set in bash never
	// reach unins000.exe.
	prevWslEnv := os.Getenv("WSLENV")
	wslEnv := "FP_UNINSTALL_MODE/u"
	if prevWslEnv != "" && !strings.Contains(prevWslEnv, "FP_UNINSTALL_MODE") {
		wslEnv = prevWslEnv + ":" + wslEnv
	}

	args := []string{}
	if yes {
		// /VERYSILENT skips the Inno Setup progress UI; SUPPRESSMSGBOXES
		// hides the standard "are you sure?" prompt. Our custom MsgBox
		// is gated on FP_UNINSTALL_MODE so it auto-resolves too.
		args = append(args, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART")
	} else {
		// /SILENT keeps progress visible but skips the initial confirmation.
		args = append(args, "/SILENT", "/NORESTART")
	}

	fmt.Fprintln(os.Stderr, "Detected WSL install -- launching the Windows uninstaller (unins000.exe).")
	fmt.Fprintln(os.Stderr, "It will remove the Tray, fp.exe, Start Menu shortcuts, and the WSL stack.")
	fmt.Fprintln(os.Stderr, "")

	c := exec.Command(uninst, args...)
	c.Env = append(os.Environ(),
		"FP_UNINSTALL_MODE="+mode,
		"WSLENV="+wslEnv,
	)
	c.Stdin = os.Stdin
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	runErr := c.Run()

	// After the Windows uninstaller returns, surface the install log path
	// in the user's WSL terminal too. The Windows-side uninstall.ps1 opens
	// it in Notepad; we echo the path here so users invoking `fp uninstall`
	// from a WSL shell always see where the log lives, regardless of
	// whether Notepad actually popped. Best-effort path discovery via the
	// `cmd.exe /c echo %TEMP%` interop trick -- gives us the Windows temp
	// dir and we convert it to a /mnt/c path for WSL.
	fmt.Fprintln(os.Stderr, "")
	if winTemp := winTempDir(); winTemp != "" {
		logWin := winTemp + `\falconpulsar-install.log`
		logWsl := winPathToWslPath(logWin)
		fmt.Fprintln(os.Stderr, "Uninstall finished.")
		fmt.Fprintln(os.Stderr, "  Log (Windows): "+logWin)
		if logWsl != "" {
			fmt.Fprintln(os.Stderr, "  Log (WSL):     "+logWsl)
		}
	} else {
		fmt.Fprintln(os.Stderr, "Uninstall finished.")
		// Split the message so go vet doesn't flag %T as a printf verb.
		tempVar := "%" + "TEMP%"
		fmt.Fprintln(os.Stderr, "  Install log is at "+tempVar+`\falconpulsar-install.log on Windows.`)
	}
	return runErr
}

// winTempDir returns the Windows TEMP path, queried via cmd.exe interop.
// Empty string on failure.
func winTempDir() string {
	out, err := exec.Command("/mnt/c/Windows/System32/cmd.exe", "/c", "echo %TEMP%").Output()
	if err != nil {
		return ""
	}
	t := strings.TrimSpace(strings.ReplaceAll(string(out), "\r", ""))
	if t == "" || strings.HasPrefix(t, "%") {
		return ""
	}
	return t
}

// winPathToWslPath converts "C:\Users\foo\bar" to "/mnt/c/Users/foo/bar".
// Not bulletproof (doesn't handle UNC, non-c: drives it still handles); good
// enough for standard %TEMP% paths under C:\Users\.
func winPathToWslPath(p string) string {
	if len(p) < 3 || p[1] != ':' {
		return ""
	}
	drive := strings.ToLower(string(p[0]))
	rest := strings.ReplaceAll(p[2:], `\`, "/")
	return "/mnt/" + drive + rest
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
