// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

// Package cli wires up cobra subcommands for `fp`.
package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/actions"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/auth"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/configbackup"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/databackup"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

// Version is the human-visible release version of the fp binary,
// displayed by `fp --version`, `fp about`, and the TUI's About modal.
//
// Declared as a `var` (not `const`) so that build pipelines can inject
// the actual git tag at link time:
//
//	go build -ldflags="-X github.com/falconpulsar/falconpulsar-installer/console/internal/cli.Version=0.1.4-alpha.5" ...
//
// The literal default is kept in sync with the repo-root VERSION file
// by scripts/sync-version.sh (CI lint enforces no drift). CI release
// builds override this via ldflags so the published binary reports
// the actual git tag; unstamped local builds (`go run ./cmd/fp`) fall
// back to whatever this literal currently says — slightly stale but
// not misleading.
var Version = "0.1.4-alpha.110"

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
		cmdBackup(),
		cmdRestore(),
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
			aiIncomplete := actions.AISetupIncomplete()
			if asJSON {
				enc := json.NewEncoder(os.Stdout)
				enc.SetIndent("", "  ")
				payload := map[string]any{
					"core":                st.Core,
					"ui":                  st.UI,
					"gateway":             st.Gateway,
					"api":                 st.APIHealthy,
					"aggregate":           st.Aggregate(),
					"ai_setup_incomplete": aiIncomplete,
				}
				// Key only present on engine-enabled installs so existing
				// consumers see byte-identical output when disabled.
				if st.EngineEnabled {
					payload["engine"] = st.Engine
				}
				if st.CopilotEnabled {
					payload["copilot"] = st.Copilot
				}
				return enc.Encode(payload)
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
			printRow("Web UI", st.UI, actions.UIURL())
			printRow("AI Capabilities", st.Gateway, "")
			printRow("REST API", st.APIHealthy, actions.RestURL())
			if st.EngineEnabled {
				printRow("AI Engine", st.Engine, actions.EngineURL())
			}
			if st.CopilotEnabled {
				printRow("Command Center", st.Copilot, actions.CopilotURL())
			}
			fmt.Printf("\nAggregate: %s\n", st.Aggregate())
			if aiIncomplete {
				fmt.Printf("\n%s AI setup is incomplete: the AI gateway has no service token, so\n",
					colorText("⚠", colorYellow))
				fmt.Println("  AI features remain offline. Re-run the FalconPulsar installer with")
				fmt.Println("  FP_ADMIN_USER and FP_ADMIN_PASS set to finish AI setup.")
			}
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
		Use:   "open [ui|engine|copilot]",
		Short: "Open the FalconPulsar Web UI (or AI Engine / Command Center) in the default browser",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			target := "ui"
			if len(args) > 0 {
				target = strings.ToLower(args[0])
			}
			switch target {
			case "ui":
				return actions.OpenURL(actions.UIURL())
			case "engine", "ai": // "ai" kept as a familiar alias
				return actions.OpenURL(actions.EngineURL())
			case "copilot", "cc": // "cc" = Command Center alias
				return actions.OpenURL(actions.CopilotURL())
			default:
				return fmt.Errorf("unknown target: %s (want: ui|engine|copilot)", target)
			}
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
				// An incomplete export still wrote a usable file. Say exactly
				// what is missing and exit non-zero, so a script cannot mistake
				// a half-captured backup for a good one.
				var incomplete *configbackup.IncompleteExportError
				if errors.As(err, &incomplete) {
					fmt.Fprintf(os.Stderr, "Saved to %s\n", incomplete.Written)
					fmt.Fprintf(os.Stderr, "\n⚠ This backup is INCOMPLETE — do not rely on it to rebuild:\n")
					for _, p := range incomplete.Problems {
						fmt.Fprintf(os.Stderr, "    • %s\n", p)
					}
					return fmt.Errorf("export incomplete (%d section(s) missing)", len(incomplete.Problems))
				}
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

// ── Data backup / restore (DB consolidation phase 5) ────────────────────────
//
// `fp config export` carries CONFIGURATION (encrypted .fpconfig). These two
// carry the DATA: every service's SQLite stores (snapshotted point-in-time
// with VACUUM INTO inside the owning container — the stack keeps running),
// the Engine's file assets, TimeSeries Core's data directory, and the config
// trio. Core is copied live under a Core backup lease (consistent, ingest
// never refused); a Core without the lease is copied cold only when the
// operator agrees to stop it (--stop-core, or yes at the prompt), and is
// otherwise left out, named in the output and the manifest, with a non-zero
// exit. Restore sets everything it replaces aside — it never deletes.

func cmdBackup() *cobra.Command {
	var skipCore, stopCore bool
	c := &cobra.Command{
		Use:   "backup [file]",
		Short: "Back up all FalconPulsar data to one archive (the stack keeps running)",
		Long: `Back up all FalconPulsar data to one .tar.gz archive while the stack runs.

Core's data directory is copied live under a Core backup lease: Core keeps
ingesting, holds every deletion that could tear the copy, and snapshots its
catalog at the end, so the copy is consistent. The lease needs a backup key
(FP_BACKUP_KEY in the stack's .env): an API key that can run a backup and
nothing else. The installer creates it; otherwise the first fp backup run in a
terminal offers to create it with an admin login, once.

A Core without the lease (older than the release that adds it) cannot be
copied consistently while it runs. fp backup then leaves Core out, says so,
and exits non-zero, unless you agree to stop Core briefly: --stop-core (or
yes at the prompt) stops Core, copies its data directory on this disk, starts
Core again, and then compresses the copy.`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			// Ctrl-C, a closed terminal or a service manager's TERM cancel the
			// backup cleanly: the lease is released, a stopped Core is started
			// again, and the partial archive is deleted.
			ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
			defer stop()

			out := "falconpulsar-backup-" + time.Now().Format("20060102-150405") + ".tar.gz"
			if len(args) == 1 {
				out = args[0]
			}
			env := databackup.LoadEnv(actions.HomeDir())
			env.CoreURL = actions.RestURL()
			interactive := stdinIsTerminal()
			if !skipCore && interactive {
				ensureBackupKey(ctx, &env)
			}
			opts := databackup.BackupOptions{SkipCore: skipCore, StopCore: stopCore, Log: os.Stderr}
			if interactive && !stopCore {
				opts.ConfirmStop = confirmCoreStop
			}

			fmt.Printf("Backing up to %s …\n", out)
			man, err := databackup.Backup(ctx, env, out, opts)
			var notCaptured *databackup.CoreNotCapturedError
			var restart *databackup.CoreRestartError
			if err != nil && !errors.As(err, &notCaptured) && !errors.As(err, &restart) {
				return err
			}
			st, _ := os.Stat(out)
			size := 0.0
			if st != nil {
				size = float64(st.Size()) / 1e6
			}
			fmt.Printf("Done: %s (%.1f MB)\n", out, size)
			for _, s := range man.Services {
				if sem := man.Semantics[s]; sem != "" {
					fmt.Printf("  %-8s %s\n", s, sem)
				} else {
					fmt.Printf("  %-8s included\n", s)
				}
			}
			if notCaptured != nil {
				fmt.Printf("  %-8s %s\n", "core", colorText(man.Semantics["core"], colorRed))
				fmt.Fprintln(os.Stderr)
				fmt.Fprintf(os.Stderr, "%s Core's data is NOT in this archive.\n", colorText("⚠", colorYellow))
				for _, hint := range coreHints(man.Core) {
					fmt.Fprintln(os.Stderr, "    • "+hint)
				}
				return fmt.Errorf("Core was not backed up")
			}
			if restart != nil {
				return restart
			}
			return nil
		},
	}
	c.Flags().BoolVar(&skipCore, "skip-core", false, "exclude TimeSeries Core's data directory (it is usually the largest part)")
	c.Flags().BoolVar(&stopCore, "stop-core", false, "if Core cannot be copied live, stop it briefly for a cold copy instead of leaving it out")
	return c
}

// coreHints says what would get Core into the next archive.
func coreHints(c *databackup.CoreCapture) []string {
	stop := "fp backup --stop-core stops Core briefly for a cold copy instead (ingest pauses; polled tags get a gap)"
	if c == nil {
		return []string{stop}
	}
	switch c.Cause {
	case databackup.CauseNoKey:
		return []string{"run fp backup once in a terminal: it offers to create the backup key (an admin login, once)", stop}
	case databackup.CauseNoLease:
		return []string{"update Core (fp update --apply) to a release with the backup lease, which copies it live", stop}
	case databackup.CauseAnotherBackup:
		return []string{"another backup holds Core's backup lease: run fp backup again when it has finished (Core ends a forgotten lease itself at its TTL)"}
	case databackup.CauseUnreachable:
		return []string{"check that Core is running and answering: fp status", stop}
	case databackup.CauseCannotCopy:
		return []string{"no copy of Core's data directory can hold it as it is; see the reason above"}
	}
	return []string{stop}
}

// stdinIsTerminal reports whether a person can answer a prompt.
func stdinIsTerminal() bool { return term.IsTerminal(int(os.Stdin.Fd())) }

// askYesNo prints question and reads one line; def is the answer to Enter.
func askYesNo(question string, def bool) bool {
	fmt.Fprint(os.Stderr, question)
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && line == "" {
		return false
	}
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "":
		return def
	case "y", "yes":
		return true
	}
	return false
}

// confirmCoreStop asks whether Core may be stopped for a cold copy.
func confirmCoreStop(why string) bool {
	fmt.Fprintln(os.Stderr)
	fmt.Fprintf(os.Stderr, "%s Core cannot be copied live: %s.\n", colorText("⚠", colorYellow), why)
	fmt.Fprintln(os.Stderr, "  fp backup can stop Core briefly instead: Core is down while its data directory is")
	fmt.Fprintln(os.Stderr, "  copied on this disk (ingest pauses; polled tags get a gap), then starts again")
	fmt.Fprintln(os.Stderr, "  before the archive is compressed. Without it, Core is left out of this archive.")
	return askYesNo("Stop Core for a cold copy? [y/N]: ", false)
}

// ensureBackupKey offers, once, to create the backup key when .env has none
// (or Core refuses it) and Core can use one. Nothing here is fatal: without a
// key, Backup leaves Core out and says why.
func ensureBackupKey(ctx context.Context, env *databackup.Env) {
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	state, _ := databackup.CheckBackupKey(cctx, env.CoreURL, env.BackupKey)
	if state != databackup.KeyAbsent && state != databackup.KeyRefused {
		return // it works, or no key can help (older or unreachable Core)
	}
	if _, advertised, err := databackup.LeaseAdvertised(cctx, env.CoreURL); err != nil || !advertised {
		return // an older Core: a key would be a full admin key there, never mint one
	}
	envPath := filepath.Join(actions.HomeDir(), ".env")
	if f, err := os.OpenFile(envPath, os.O_WRONLY, 0); err != nil {
		fmt.Fprintf(os.Stderr, "%s fp backup needs a backup key in %s and cannot write that file (%v).\n",
			colorText("⚠", colorYellow), envPath, err)
		fmt.Fprintln(os.Stderr, "  Run fp backup once as the stack's owner, or re-run the installer, to create it.")
		return
	} else {
		f.Close()
	}
	fmt.Fprintln(os.Stderr)
	if state == databackup.KeyRefused {
		fmt.Fprintln(os.Stderr, "Core refused the backup key in .env (it was revoked, or minted on another Core).")
	}
	fmt.Fprintln(os.Stderr, "fp backup copies Core live with a backup key: an API key that can run a backup and")
	fmt.Fprintln(os.Stderr, "nothing else, kept in .env so scheduled backups work unattended. It is created once,")
	fmt.Fprintln(os.Stderr, "with an admin login; the password is not stored.")
	if !askYesNo("Create the backup key now? [Y/n]: ", true) {
		return
	}
	cli, _, _, err := auth.PromptAdmin(ctx, "Admin login, to create the backup key:")
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s backup key not created: %v\n", colorText("⚠", colorYellow), err)
		return
	}
	key, err := databackup.MintBackupKey(ctx, env.CoreURL, cli.Token)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s backup key not created: %v\n", colorText("⚠", colorYellow), err)
		return
	}
	env.BackupKey = key // this run uses it either way
	if err := actions.SetEnvValue(databackup.BackupKeyEnv, key); err != nil {
		fmt.Fprintf(os.Stderr, "%s the backup key could not be stored in .env (%v); this backup uses it, the next one will ask again\n",
			colorText("⚠", colorYellow), err)
		return
	}
	fmt.Fprintf(os.Stderr, "%s backup key created and stored in .env (%s)\n", colorText("✓", colorGreen), databackup.BackupKeyEnv)
}

func cmdRestore() *cobra.Command {
	var only []string
	var yes bool
	c := &cobra.Command{
		Use:   "restore <file>",
		Short: "Restore a data backup (stops the stack; replaced data is set aside, never deleted)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := context.Background()
			env := databackup.LoadEnv(actions.HomeDir())
			env.CoreURL = actions.RestURL()
			man, err := databackup.Peek(args[0])
			if err != nil {
				return err
			}
			services := man.Services
			if len(only) > 0 {
				services = only
			}
			restoringCore := false
			for _, s := range services {
				if s == "core" {
					restoringCore = true
				}
			}
			olderCore := restoringCore && man.CoreFromOlderBackup()
			leaseCore := restoringCore && man.Core != nil && man.Core.Mode == databackup.CoreLease

			fmt.Printf("Backup from %s (fp %s, host %s)\n", man.CreatedAt, man.FPVersion, man.Host)
			fmt.Printf("Will restore: %s\n", strings.Join(services, ", "))
			if restoringCore && man.Core != nil {
				fmt.Printf("Core in this archive: %s\n", man.Core.Semantics())
			}
			if man.Core != nil && man.Core.Mode == databackup.CoreNotCaptured {
				fmt.Printf("%s This archive does not hold Core's data: %s\n", colorText("⚠", colorYellow), man.Core.Reason)
			}
			if olderCore {
				fmt.Printf("%s This archive was made by an older fp backup, which copied Core live with no\n", colorText("⚠", colorYellow))
				fmt.Println("  consistent cut: its \"crash-consistent\" label was not true, and the copy may be torn")
				fmt.Println("  (a damaged catalog, an ignored journal, missing points or whole series). It is")
				fmt.Println("  restored as it is; Core's open state is reported after it starts. Keep the")
				fmt.Println("  pre-restore copy until you have checked it.")
			}
			if leaseCore {
				warnOlderCore(ctx, env.CoreURL, man)
			}
			fmt.Println("The stack will be STOPPED during the restore. Everything replaced is set aside as *.pre-restore-*, never deleted.")
			if !yes {
				fmt.Print("Type 'restore' to continue: ")
				var answer string
				fmt.Fscanln(os.Stdin, &answer)
				if answer != "restore" {
					return fmt.Errorf("aborted")
				}
			}
			// Core gets time to close: Docker's default 10 s SIGKILLs a long
			// final checkpoint (compose sets no stop_grace_period).
			if err := actions.Compose(ctx, os.Stdout, os.Stderr, "stop", "-t", "180"); err != nil {
				return fmt.Errorf("stopping stack: %w", err)
			}
			asides, err := databackup.Restore(ctx, env, args[0], databackup.RestoreOptions{
				Only: only,
				Warn: func(s string) { fmt.Fprintf(os.Stderr, "%s %s\n", colorText("⚠", colorYellow), s) },
			})
			if err != nil {
				return fmt.Errorf("restore: %w (already-replaced items are set aside as *.pre-restore-*)", err)
			}
			asideNote := "Set aside (delete when satisfied):"
			if olderCore {
				asideNote = "Set aside (keep until you have checked Core's open state, then delete):"
			}
			// Core must read the restored directory, not the one set aside:
			// Docker Desktop can keep its view of the renamed directory. A marker
			// goes in now and is looked for inside Core's container once it runs.
			marker, keepMarker := "", false
			if restoringCore {
				if m, err := databackup.MarkRestoredCore(env); err != nil {
					fmt.Fprintf(os.Stderr, "%s fp restore cannot check that Core reads the restored data: %v\n", colorText("⚠", colorYellow), err)
				} else {
					marker = m
					defer func() {
						if !keepMarker {
							databackup.UnmarkRestoredCore(env, marker)
						}
					}()
				}
			}
			if err := actions.Compose(ctx, os.Stdout, os.Stderr, "start"); err != nil {
				printAsides(asides, env.CoreDir, asideNote)
				return fmt.Errorf("stack restored but failed to start: %w", err)
			}
			if restoringCore && marker != "" {
				err := databackup.VerifyCoreReadsRestore(ctx, env, marker, os.Stdout)
				var stale *databackup.StaleCoreViewError
				switch {
				case errors.As(err, &stale):
					printAsides(asides, env.CoreDir, "Set aside (Core ran on it until it was stopped; keep it until Core reads the restored data):")
					return err
				case err != nil:
					keepMarker = true
					fmt.Printf("%s fp restore could not check that Core reads the restored data (%v).\n", colorText("⚠", colorYellow), err)
					fmt.Printf("  Check it: docker exec %s ls /data/%s must find that file (then delete %s).\n",
						"falconpulsar-core", marker, filepath.Join(env.CoreDir, marker))
					fmt.Println("  If it does not, Core runs on the data set aside: stop it (docker stop -t 180 falconpulsar-core),")
					fmt.Println("  quit Docker Desktop and open it again, then run fp start.")
				}
			}
			if restoringCore {
				fmt.Println("Waiting for Core to open the restored data …")
				if !databackup.WaitCoreHealthy(ctx, env.CoreURL, 5*time.Minute) {
					fmt.Printf("%s Core has not answered yet; check: docker logs falconpulsar-core\n", colorText("⚠", colorYellow))
				} else {
					if leaseCore {
						warnOlderCore(ctx, env.CoreURL, man)
					}
					if olderCore {
						reportCoreOpenState(ctx, env.CoreURL, yes)
					}
				}
			}
			printAsides(asides, env.CoreDir, asideNote)
			fmt.Println("Restore complete.")
			return nil
		},
	}
	c.Flags().StringSliceVar(&only, "only", nil, "restore only these services (gateway, engine, copilot, core, config)")
	c.Flags().BoolVar(&yes, "yes", false, "skip the confirmation prompt")
	return c
}

func printAsides(asides []string, coreDir string, note string) {
	if len(asides) == 0 {
		return
	}
	fmt.Println(note)
	for _, a := range asides {
		fmt.Println("  " + a)
		if filepath.Dir(a) == filepath.Clean(coreDir) {
			fmt.Println("    (inside Core's data directory, which is a mount point and cannot be renamed;")
			fmt.Println("     until it is deleted or moved, fp backup may copy it too)")
		}
	}
}

// warnOlderCore: an archive made under a lease restores only into a Core at
// least as new as the one that made it. An older Core lacks the blob
// reconciliation the copy relies on, and its string values written during
// the backup could read wrong. A Core with the lease has it.
func warnOlderCore(ctx context.Context, coreURL string, man databackup.Manifest) {
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	pc, advertised, err := databackup.LeaseAdvertised(cctx, coreURL)
	if err != nil || advertised {
		return // not reachable (checked again after start), or new enough
	}
	fmt.Printf("%s This Core (%s) is older than the one that made the archive (%s): it lacks the\n",
		colorText("⚠", colorYellow), orUnknown(pc.Version), orUnknown(man.Core.CoreVersion))
	fmt.Println("  backup lease and the repair of string-value files the copy relies on. Update Core")
	fmt.Println("  first (fp update --apply), or string values written during the backup may read wrong.")
}

func orUnknown(s string) string {
	if s == "" {
		return "version unknown"
	}
	return s
}

// reportCoreOpenState shows what Core's open found in a Core restored from
// an older fp backup's archive. It needs an admin login.
func reportCoreOpenState(ctx context.Context, coreURL string, unattended bool) {
	how := "As an admin, GET /api/v1/_system/catalog (open.damaged, open.journal_ignored, wal_held) and\n" +
		"  GET /api/v1/_system/database (series_count) show it."
	if unattended || !stdinIsTerminal() {
		fmt.Printf("%s Check Core's open state before deleting the pre-restore copy. %s\n", colorText("⚠", colorYellow), how)
		return
	}
	cli, _, _, err := auth.PromptAdmin(ctx, "Check Core's open state — admin login (of the RESTORED Core):")
	if err != nil {
		fmt.Printf("%s Core's open state was not read (%v). %s\n", colorText("⚠", colorYellow), err, how)
		return
	}
	st, err := databackup.ReadCoreOpenState(ctx, coreURL, cli.Token)
	if err != nil {
		fmt.Printf("%s Core's open state was not read (%v). %s\n", colorText("⚠", colorYellow), err, how)
		return
	}
	bad := false
	fmt.Println("Core's open state after the restore:")
	if !st.CatalogReported {
		fmt.Println("  catalog:  this Core does not report its catalog's open state")
	} else {
		switch {
		case st.Damaged:
			bad = true
			fmt.Printf("  catalog:  %s (%s)\n", colorText("DAMAGED", colorRed), st.FirstDamage)
		default:
			fmt.Println("  catalog:  not damaged")
		}
		switch {
		case st.JournalIgnored:
			bad = true
			fmt.Printf("  journal:  %s (%s)\n", colorText("IGNORED", colorRed), st.JournalNote)
		case st.JournalReplayed:
			fmt.Println("  journal:  replayed (it completed a commit the copy interrupted)")
		default:
			fmt.Println("  journal:  not needed")
		}
		if st.WALHeldPoints > 0 {
			bad = true
			fmt.Printf("  WAL held: %s\n", colorText(fmt.Sprintf("%d points of %d series could not be applied (kept in meta/wal-held)", st.WALHeldPoints, st.WALHeldSeries), colorRed))
		} else {
			fmt.Println("  WAL held: none")
		}
	}
	fmt.Printf("  series:   %d\n", st.SeriesCount)
	if bad {
		fmt.Printf("%s The restored Core copy is torn. Your previous data is in the pre-restore copy below.\n", colorText("⚠", colorYellow))
	} else {
		fmt.Println("  Nothing Core checks is wrong. It cannot see a series or points the copy never held:")
		fmt.Println("  compare the series count and recent history with what you expect before deleting the")
		fmt.Println("  pre-restore copy.")
	}
}

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
			"Source of truth for image updates is the same Docker registry you\n" +
			"already pull from — air-gapped and private-registry deploys\n" +
			"work the same as public Docker Hub. Host components (the\n" +
			"fp CLI, tray apps) are additionally checked against the published\n" +
			"installer release version; that probe is best-effort and reports\n" +
			"'unknown' when offline instead of failing the check.",
		RunE: func(cmd *cobra.Command, args []string) error {
			if apply {
				return actions.ApplyUpdates(cmd.Context(), os.Stdout, os.Stderr)
			}
			res := actions.CheckUpdates(cmd.Context(), Version)
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
			// Host components (fp CLI) are checked against the published
			// installer release version, not a registry digest — versions
			// are the meaningful diff for a binary the operator installed.
			fmt.Println()
			fmt.Println("Host components:")
			for _, host := range res.HostComponents {
				switch {
				case host.ErrorKind != "":
					fmt.Printf("  %s  %-18s %s\n",
						colorText("?", colorYellow), host.Name, host.Error)
				case host.UpdateAvailable:
					fmt.Printf("  %s  %-18s update available: v%s (installed v%s)\n",
						colorText("↑", colorGreen), host.Name, host.LatestVersion, host.InstalledVersion)
					fmt.Printf("       download: %s\n", res.InstallerReleaseURL)
					fmt.Println("       run the latest installer's Upgrade to update host components")
				default:
					fmt.Printf("  %s  %-18s up to date (v%s)\n",
						colorText("✓", colorGreen), host.Name, host.InstalledVersion)
				}
			}
			fmt.Println()
			switch {
			case res.AnyError:
				fmt.Println("One or more registry probes failed. Check connectivity / credentials.")
				os.Exit(2)
			case res.Any:
				fmt.Println("Run `fp update --apply` to install the update.")
			case res.HostAny:
				fmt.Println("Container images are up to date; a host component update is available (see above).")
			case res.HostProbeFailed:
				fmt.Println("Container images are up to date. Host component status unknown (no internet access).")
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
			fmt.Printf("  AI Capabilities %s\n", actions.GetContainerInfo(ctx, "falconpulsar-ai-gateway").DisplayString())
			fmt.Printf("  AI Engine       %s\n", actions.GetContainerInfo(ctx, "falconpulsar-ai-engine").DisplayString())
			if actions.CopilotEnabled() {
				fmt.Printf("  Command Center  %s\n", actions.GetContainerInfo(ctx, "falconpulsar-copilot").DisplayString())
			}
			fmt.Printf("  Compose         %s\n", actions.GetComposeVersion(ctx))
			fmt.Println()

			// Local endpoints -- duplicated in the TUI About modal and
			// useful here for shell pipelines (e.g. piping to grep to
			// extract a port number for a script). Ports honor any
			// FP_*_PORT remap in the stack's .env.
			fmt.Println("Endpoints:")
			fmt.Printf("  Web UI          %s\n", actions.UIURL())
			fmt.Printf("  REST API        %s\n", actions.RestURL())
			fmt.Printf("  AI Gateway      %s\n", actions.GatewayURL())
			fmt.Println()

			fmt.Println("Website:          https://falconpulsar.com")
			fmt.Println("Docs:             https://docs.falconpulsar.com/")
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
			return actions.OpenURL("https://docs.falconpulsar.com/")
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
			if IsWSL() {
				return RunWindowsUninstaller(purge, yes)
			}

			// Native Linux / macOS: run the bash uninstaller directly. The
			// installers plant it at ${FP_HOME}/uninstall.sh and nowhere else.
			home := actions.HomeDir()
			script := filepath.Join(home, "uninstall.sh")
			if _, err := os.Stat(script); err != nil {
				fmt.Fprintln(os.Stderr, "Uninstaller not found at ~/falconpulsar/uninstall.sh.")
				fmt.Fprintln(os.Stderr, "Re-run the installer to restore it, or run it directly from the installer source tree.")
				return nil
			}

			// Stage uninstall.sh (+ its sibling auth.sh) into a private temp
			// dir so bash keeps a valid source file when the script deletes
			// its own ${FP_HOME} parent mid-run, and so we never write through
			// predictable /tmp paths (TOCTOU symlink race). Remove the whole
			// staging dir afterwards — both files, not just the script.
			runPath, stageDir := stageUninstaller(script)
			if stageDir != "" {
				defer os.RemoveAll(stageDir)
			}

			// Run the uninstaller with the user's flags. --yes is required
			// when --purge is set so the interactive "are you sure?" block
			// doesn't fire, but the bash script still gates on admin auth
			// (prompts directly on stdin) unless --force is passed. --home
			// forwards the console-resolved stack dir so the script targets
			// exactly what we found (relocated / per-user stacks) instead of
			// re-inferring it.
			scriptArgs := []string{runPath}
			if purge {
				scriptArgs = append(scriptArgs, "--purge")
			} else {
				scriptArgs = append(scriptArgs, "--keep")
			}
			if yes {
				scriptArgs = append(scriptArgs, "--yes")
			}
			scriptArgs = append(scriptArgs, "--home", home)
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

// IsWSL returns true when this binary is running inside a WSL distro.
// Both markers are official: the binfmt entry is what lets us run .exe
// files via interop, and the kernel name carries "microsoft"/"WSL".
// Exported so the TUI can mirror the CLI's WSL uninstall handoff.
func IsWSL() bool {
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

// RunWindowsUninstaller execs the Inno Setup uninstaller (unins000.exe)
// via WSL->Windows interop. It's the only Windows-side tool that can
// clean Program Files, the Start Menu folder, the Add/Remove Programs
// entry, and the HKCU Run key. Inno Setup's CurUninstallStepChanged
// in turn calls our uninstall.ps1 for the WSL container/data cleanup.
//
// FP_UNINSTALL_MODE=purge|keep is forwarded via WSLENV so the Inno
// Setup [Code] block can skip its interactive Yes/No/Cancel MsgBox
// when the user already said --purge or default-keep on the fp CLI.
func RunWindowsUninstaller(purge, yes bool) error {
	uninst := resolveWindowsUninstaller()
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

// resolveWindowsUninstaller locates unins000.exe. The Inno Setup wizard has
// a standard installation-location page, so users may have installed
// somewhere other than C:\Program Files\FalconPulsar. The authoritative
// source is the uninstall registry key Inno Setup writes at install time
// (UninstallString), queried via reg.exe interop — HKLM, because the
// installer requires admin. Falls back to the default Program Files path
// when the query fails (e.g. reg.exe interop unavailable).
func resolveWindowsUninstaller() string {
	const defaultPath = "/mnt/c/Program Files/FalconPulsar/unins000.exe"
	// "<AppId>_is1" — the GUID must match AppId in windows/installer.iss.
	const uninstallKey = `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\` +
		`{8E0B7C2F-3F4D-4B9E-9C6A-1D5F8A2B9C71}_is1`

	out, err := exec.Command("/mnt/c/Windows/System32/reg.exe",
		"query", uninstallKey, "/v", "UninstallString").Output()
	if err != nil {
		return defaultPath
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(strings.TrimRight(line, "\r"))
		if !strings.Contains(line, "UninstallString") {
			continue
		}
		// Line shape: `UninstallString    REG_SZ    "C:\...\unins000.exe"`
		i := strings.Index(line, "REG_SZ")
		if i < 0 {
			continue
		}
		winPath := strings.Trim(strings.TrimSpace(line[i+len("REG_SZ"):]), `"`)
		if p := winPathToWslPath(winPath); p != "" {
			if _, err := os.Stat(p); err == nil {
				return p
			}
		}
	}
	return defaultPath
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

// stageUninstaller copies uninstall.sh (and its sibling auth.sh) into a
// private, unguessable MkdirTemp directory so bash keeps a valid source
// file even when the script deletes its own ${FP_HOME} parent mid-run.
//
// It returns the staged script path and the staging directory; the caller
// removes the whole directory (both files) when done. On any failure it
// falls back to running the original script in place and returns an empty
// stageDir so the caller skips cleanup (never deletes the real script).
//
// The random directory name (0700) closes the TOCTOU symlink race that the
// old fixed /tmp/fp-uninstall-<pid>.sh + /tmp/auth.sh paths were exposed to:
// a same-user attacker could pre-create those predictable paths as symlinks
// before our writes. uninstall.sh sources ${SCRIPT_DIR}/auth.sh, so both
// files must live in the same directory.
func stageUninstaller(src string) (script, stageDir string) {
	data, err := os.ReadFile(src)
	if err != nil {
		return src, ""
	}
	dir, err := os.MkdirTemp("", "fp-uninstall-")
	if err != nil {
		return src, ""
	}
	dst := filepath.Join(dir, "uninstall.sh")
	if err := os.WriteFile(dst, data, 0700); err != nil {
		_ = os.RemoveAll(dir)
		return src, ""
	}
	if auth, err := os.ReadFile(filepath.Join(filepath.Dir(src), "auth.sh")); err == nil {
		_ = os.WriteFile(filepath.Join(dir, "auth.sh"), auth, 0600)
	}
	return dst, dir
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
