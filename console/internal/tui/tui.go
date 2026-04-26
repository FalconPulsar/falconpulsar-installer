// Package tui implements the Midnight-Commander-style interactive console.
package tui

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/actions"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/auth"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/cli"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/configbackup"
	"github.com/falconpulsar/falconpulsar-installer/console/internal/theme"
	"github.com/gdamore/tcell/v2"
	"github.com/rivo/tview"
)

// ─── Menu structure ─────────────────────────────────────────────────────────

type menuItem struct {
	label  string
	accel  string // displayed on the right, e.g. "F2"
	action func(*App)
	sep    bool
}

type menuSection struct {
	title string
	items []menuItem
}

func buildSections() []menuSection {
	return []menuSection{
		{"Stack", []menuItem{
			{label: "Start", accel: "F2", action: func(a *App) { a.runAction("Starting stack…", "start") }},
			{label: "Stop", accel: "F3", action: func(a *App) { a.runAction("Stopping stack…", "stop") }},
			{label: "Restart", accel: "F4", action: func(a *App) { a.runAction("Restarting stack…", "restart") }},
			{sep: true},
			{label: "Refresh status", action: func(a *App) {
				a.status = actions.Poll(context.Background())
				a.refreshServices()
			}},
		}},
		{"Logs", []menuItem{
			{label: "View all logs", accel: "F5", action: func(a *App) { a.showLogsPickerExec("") }},
			{label: "Core only", action: func(a *App) { a.showLogsPickerExec("core") }},
			{label: "Web UI only", action: func(a *App) { a.showLogsPickerExec("ui") }},
			{label: "AI Capabilities only", action: func(a *App) { a.showLogsPickerExec("ai-gateway") }},
			{sep: true},
			{label: "Open install log", action: func(a *App) { a.openInstallLog() }},
		}},
		{"Config", []menuItem{
			{label: "Edit core (falconpulsar.toml)", action: func(a *App) {
				a.editConfig(filepath.Join("data", "falconpulsar.toml"))
			}},
			{label: "Edit AI Capabilities (gateway.yaml)", action: func(a *App) {
				a.editConfig("gateway.yaml")
			}},
			{label: "Edit Docker Compose (compose.yml)", action: func(a *App) {
				a.editConfig("compose.yml")
			}},
			{sep: true},
			{label: "Open data folder", action: func(a *App) {
				_ = actions.OpenFolder(filepath.Join(actions.HomeDir(), "data"))
			}},
			{label: "Open stack folder", action: func(a *App) {
				_ = actions.OpenFolder(actions.HomeDir())
			}},
		}},
		{"Backup", []menuItem{
			{label: "Export configuration…", accel: "F7", action: func(a *App) { a.doExport() }},
			{label: "Import configuration…", accel: "F8", action: func(a *App) { a.doImport() }},
		}},
		{"AI", []menuItem{
			{label: aiToggleLabel(), action: func(a *App) {
				if actions.AIGatewayEnabled() {
					a.disableAIGateway()
				} else {
					a.enableAIGateway()
				}
			}},
		}},
		{"Help", []menuItem{
			{label: "Keyboard shortcuts", accel: "F1", action: func(a *App) { a.showHelp() }},
			{label: "About FalconPulsar", action: func(a *App) { a.showAbout() }},
			{label: "Documentation", action: func(a *App) {
				_ = actions.OpenURL("https://falconpulsar.com/docs")
			}},
			{label: "Request a feature", action: func(a *App) {
				_ = actions.OpenURL("https://falconpulsar.com/roadmap#request-form")
			}},
			{sep: true},
			{label: "Uninstall FalconPulsar…", action: func(a *App) { a.confirmUninstall() }},
			{label: "Quit", accel: "F10", action: func(a *App) { a.tv.Stop() }},
		}},
	}
}

// ─── App ────────────────────────────────────────────────────────────────────

type App struct {
	tv       *tview.Application
	pages    *tview.Pages
	menuBar  *tview.TextView
	services *tview.Table
	details  *tview.TextView
	fkeys    *tview.TextView
	status   actions.Status
	sections []menuSection
	stopPoll chan struct{}
}

func Run() error {
	a := &App{
		tv:       tview.NewApplication(),
		sections: buildSections(),
		stopPoll: make(chan struct{}),
	}
	a.build()
	a.startPolling()
	defer close(a.stopPoll)
	return a.tv.Run()
}

func (a *App) build() {
	a.menuBar = tview.NewTextView().
		SetDynamicColors(true).
		SetWrap(false)
	a.menuBar.SetBackgroundColor(theme.Surface)
	a.menuBar.SetText(a.renderMenuBar(-1))

	a.services = tview.NewTable().SetSelectable(true, false).SetSeparator(' ')
	a.services.SetBorder(true).SetTitle(" Services ").
		SetTitleColor(theme.Accent).SetBorderColor(theme.Border)
	a.services.SetBackgroundColor(theme.Panel)
	a.services.SetSelectedStyle(tcell.StyleDefault.
		Background(theme.SelectedBg).Foreground(theme.SelectedFg))
	a.services.SetSelectionChangedFunc(func(row, col int) { a.refreshDetails(row) })

	a.details = tview.NewTextView().SetDynamicColors(true).SetWrap(true)
	a.details.SetBorder(true).SetTitle(" Details ").
		SetTitleColor(theme.Accent).SetBorderColor(theme.Border)
	a.details.SetBackgroundColor(theme.Panel)

	a.fkeys = tview.NewTextView().SetDynamicColors(true).SetWrap(false)
	a.fkeys.SetText(fkeyBar())
	a.fkeys.SetBackgroundColor(theme.Surface)

	content := tview.NewFlex().SetDirection(tview.FlexColumn).
		AddItem(a.services, 0, 1, true).
		AddItem(a.details, 0, 1, false)

	layout := tview.NewFlex().SetDirection(tview.FlexRow).
		AddItem(a.menuBar, 1, 0, false).
		AddItem(content, 0, 1, true).
		AddItem(a.fkeys, 1, 0, false)
	layout.SetBackgroundColor(theme.Background)

	a.pages = tview.NewPages().AddPage("main", layout, true, true)

	a.tv.SetRoot(a.pages, true).EnableMouse(false)
	a.tv.SetInputCapture(a.handleKey)

	a.refreshServices()
}

// ─── Rendering ──────────────────────────────────────────────────────────────

func (a *App) renderMenuBar(active int) string {
	out := " "
	for i, s := range a.sections {
		if i == active {
			out += fmt.Sprintf("[#0A0A19:#00AAFF] %s [-:-:-] ", s.title)
		} else {
			out += fmt.Sprintf("[#E5E7EB] %s [-] ", s.title)
		}
	}
	out += "  [#6B7280](F9: menu  F10: quit)[-]"
	return out
}

func fkeyBar() string {
	keys := []struct{ k, l string }{
		{"F1", "Help"}, {"F2", "Start"}, {"F3", "Stop"}, {"F4", "Restart"},
		{"F5", "Logs"}, {"F7", "Export"}, {"F8", "Import"},
		{"F9", "Menu"}, {"F10", "Quit"},
	}
	out := ""
	for _, k := range keys {
		out += fmt.Sprintf("[#00AAFF]%s[-] %s  ", k.k, k.l)
	}
	return out
}

// ─── Polling ────────────────────────────────────────────────────────────────

func (a *App) startPolling() {
	go func() {
		t := time.NewTicker(3 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-a.stopPoll:
				return
			case <-t.C:
				st := actions.Poll(context.Background())
				a.tv.QueueUpdateDraw(func() {
					a.status = st
					a.refreshServices()
				})
			}
		}
	}()
	a.status = actions.Poll(context.Background())
}

func (a *App) refreshServices() {
	a.services.Clear()
	type svcRow struct {
		name, note, stateStr string
		dotColor             tcell.Color
		stateColor           tcell.Color
	}
	aiEnabled := actions.AIGatewayEnabled()
	var rows []svcRow
	rows = append(rows, svcRow{"Core", "time-series engine",
		stateLabel(a.status.Core), dotColor(a.status.Core), stateColor(a.status.Core)})
	rows = append(rows, svcRow{"Web UI", "http://localhost:8080",
		stateLabel(a.status.UI), dotColor(a.status.UI), stateColor(a.status.UI)})
	if aiEnabled {
		rows = append(rows, svcRow{"AI Capabilities", "http://localhost:7436",
			stateLabel(a.status.Gateway), dotColor(a.status.Gateway), stateColor(a.status.Gateway)})
	} else {
		rows = append(rows, svcRow{"AI Capabilities", "(disabled)",
			"[#9CA3AF]disabled[-]", theme.TextMuted, theme.TextMuted})
	}
	rows = append(rows, svcRow{"REST API", "http://localhost:7433",
		stateLabel(a.status.APIHealthy), dotColor(a.status.APIHealthy), stateColor(a.status.APIHealthy)})

	for i, r := range rows {
		dot := tview.NewTableCell("●").SetAlign(tview.AlignCenter).SetTextColor(r.dotColor)
		name := tview.NewTableCell(r.name).SetTextColor(theme.Text)
		state := tview.NewTableCell(r.stateStr).SetTextColor(r.stateColor)
		note := tview.NewTableCell(r.note).SetTextColor(theme.TextDim)
		a.services.SetCell(i, 0, dot)
		a.services.SetCell(i, 1, name)
		a.services.SetCell(i, 2, state)
		a.services.SetCell(i, 3, note)
	}
	a.refreshDetails(a.services.GetSelection())
}

func dotColor(on bool) tcell.Color {
	if on {
		return theme.Running
	}
	return theme.Stopped
}
func stateColor(on bool) tcell.Color {
	if on {
		return theme.Running
	}
	return theme.Stopped
}

func (a *App) refreshDetails(row ...int) {
	r := 0
	if len(row) > 0 {
		r = row[0]
	}
	labels := []string{"Core", "Web UI", "AI Capabilities", "REST API"}
	if r < 0 || r >= len(labels) {
		r = 0
	}
	s := fmt.Sprintf(
		"[::b]%s[-:-:-]\n\n"+
			"Stack aggregate: [#00AAFF]%s[-]\n\n"+
			"Core         %s\n"+
			"Web UI       %s\n"+
			"AI Capabilities %s\n"+
			"REST API     %s\n\n"+
			"[#9CA3AF]Version %s — %s[-]",
		labels[r], a.status.Aggregate(),
		stateLabel(a.status.Core), stateLabel(a.status.UI),
		stateLabel(a.status.Gateway), stateLabel(a.status.APIHealthy),
		cli.Version, actions.HomeDir(),
	)
	a.details.SetText(s)
}

func stateLabel(on bool) string {
	if on {
		return "[#22C55E]running[-]"
	}
	return "[#EF4444]stopped[-]"
}

// ─── Key handling ───────────────────────────────────────────────────────────

func (a *App) handleKey(ev *tcell.EventKey) *tcell.EventKey {
	switch ev.Key() {
	case tcell.KeyF1:
		a.showHelp()
		return nil
	case tcell.KeyF2:
		a.runAction("Starting stack…", "start")
		return nil
	case tcell.KeyF3:
		a.runAction("Stopping stack…", "stop")
		return nil
	case tcell.KeyF4:
		a.runAction("Restarting stack…", "restart")
		return nil
	case tcell.KeyF5:
		a.showLogsPickerExec("")
		return nil
	case tcell.KeyF7:
		a.doExport()
		return nil
	case tcell.KeyF8:
		a.doImport()
		return nil
	case tcell.KeyF9:
		a.openMenu(0)
		return nil
	case tcell.KeyF10, tcell.KeyCtrlC:
		a.tv.Stop()
		return nil
	}
	switch ev.Rune() {
	case 'q', 'Q':
		a.tv.Stop()
		return nil
	}
	return ev
}

// ─── Pull-down menu (F9) ────────────────────────────────────────────────────

func (a *App) openMenu(index int) {
	if index < 0 {
		index = len(a.sections) - 1
	}
	if index >= len(a.sections) {
		index = 0
	}
	a.menuBar.SetText(a.renderMenuBar(index))

	section := a.sections[index]
	list := tview.NewList().ShowSecondaryText(false)
	// Use explicit Style (fg+bg) for every row so tview doesn't leave
	// each item's background at the terminal default (which renders as
	// gray). Selected row uses its own style via SetSelectedFocusStyle.
	itemStyle := tcell.StyleDefault.
		Foreground(theme.Text).
		Background(theme.MenuBg)
	selectedStyle := tcell.StyleDefault.
		Foreground(theme.SelectedFg).
		Background(theme.SelectedBg)
	list.SetMainTextStyle(itemStyle)
	list.SetSecondaryTextStyle(itemStyle)
	list.SetShortcutStyle(itemStyle)
	list.SetSelectedStyle(selectedStyle)
	list.SetBackgroundColor(theme.MenuBg)
	list.SetBorder(true).
		SetTitle(fmt.Sprintf(" %s ", section.title)).
		SetTitleColor(theme.Accent).
		SetBorderColor(theme.BorderFocus)

	// Every row is now a plain label — no right-aligned accelerator
	// column (F-keys are in the bottom bar only).
	for _, item := range section.items {
		if item.sep {
			// Plain dashes as visual separator (List doesn't render color
			// tags in items without extra setup).
			list.AddItem("──────────────────────────", "", 0, nil)
			continue
		}
		act := item.action
		list.AddItem(item.label, "", 0, func() {
			a.pages.RemovePage("menu")
			a.menuBar.SetText(a.renderMenuBar(-1))
			if act != nil {
				act(a)
			}
		})
	}
	// Navigation between sections and close
	list.SetInputCapture(func(ev *tcell.EventKey) *tcell.EventKey {
		switch ev.Key() {
		case tcell.KeyEscape:
			a.pages.RemovePage("menu")
			a.menuBar.SetText(a.renderMenuBar(-1))
			return nil
		case tcell.KeyLeft:
			a.pages.RemovePage("menu")
			a.openMenu(index - 1)
			return nil
		case tcell.KeyRight:
			a.pages.RemovePage("menu")
			a.openMenu(index + 1)
			return nil
		}
		return ev
	})

	// Position under the selected top-menu label. Use a Grid so the
	// dropdown sits exactly where we want and the area around it is
	// transparent (the main page keeps rendering behind without color
	// bleed into the dropdown).
	x := menuOffsetFor(a.sections, index)
	width := 50
	height := len(section.items) + 2
	grid := tview.NewGrid().
		SetRows(1, height, 0).
		SetColumns(x, width, 0).
		AddItem(list, 1, 1, 1, 1, 0, 0, true)
	grid.SetBackgroundColor(tcell.ColorDefault) // let main page show through
	a.pages.AddPage("menu", grid, true, true)
}

// menuOffsetFor returns the rough horizontal column where the given top-menu
// label starts (so the dropdown aligns under it). Heuristic — good enough.
func menuOffsetFor(sections []menuSection, index int) int {
	x := 1
	for i, s := range sections {
		if i == index {
			return x
		}
		x += len(s.title) + 2
	}
	return x
}

// ─── Actions ────────────────────────────────────────────────────────────────

func (a *App) runAction(title string, kind string) {
	a.showMessage(title, "Please wait…", false)
	go func() {
		var err error
		switch kind {
		case "start":
			err = actions.Compose(context.Background(), nil, nil, "up", "-d")
		case "stop":
			err = actions.Compose(context.Background(), nil, nil, "down")
		case "restart":
			err = actions.Compose(context.Background(), nil, nil, "restart")
		}
		a.tv.QueueUpdateDraw(func() {
			if err != nil {
				a.showMessage("Error", err.Error(), true)
			} else {
				a.pages.RemovePage("modal")
				a.status = actions.Poll(context.Background())
				a.refreshServices()
			}
		})
	}()
}

func (a *App) showLogsPickerExec(service string) {
	a.tv.Suspend(func() {
		args := []string{"logs", "-f", "--tail", "200"}
		if service != "" {
			args = append(args, service)
		}
		_ = actions.Compose(context.Background(), nil, nil, args...)
	})
}

func (a *App) editConfig(rel string) {
	a.openEditor(filepath.Join(actions.HomeDir(), rel))
}

func (a *App) openInstallLog() {
	a.openViewer("/tmp/falconpulsar-install.log")
}

// confirmUninstall runs the same multi-step flow as the macOS / Windows
// trays: pick "Keep data" or "Remove everything", then (for the
// destructive option) require typing DELETE, then execute uninstall.sh
// with the matching flag.
func (a *App) confirmUninstall() {
	list := tview.NewList().ShowSecondaryText(true)
	list.SetMainTextStyle(tcell.StyleDefault.
		Foreground(theme.Text).Background(theme.MenuBg))
	list.SetSecondaryTextStyle(tcell.StyleDefault.
		Foreground(theme.TextDim).Background(theme.MenuBg))
	list.SetSelectedStyle(tcell.StyleDefault.
		Foreground(theme.SelectedFg).Background(theme.SelectedBg))
	list.SetBackgroundColor(theme.MenuBg)
	list.SetBorder(true).
		SetTitle(" Uninstall FalconPulsar ").
		SetTitleColor(theme.Accent).
		SetBorderColor(theme.BorderFocus)

	list.AddItem("Keep my data",
		"Remove the application; keep ~/falconpulsar/data so you can reinstall later.",
		0, func() {
			a.pages.RemovePage("modal")
			a.runUninstall(false)
		})
	list.AddItem("Remove everything (DELETE ALL DATA)",
		"Stops the stack, removes ~/falconpulsar completely — irreversible.",
		0, func() {
			a.pages.RemovePage("modal")
			a.confirmPurge()
		})
	list.AddItem("Cancel", "", 0, func() { a.pages.RemovePage("modal") })

	a.pushModal("Uninstall FalconPulsar", list, 72, 9)
}

// confirmPurge demands the word DELETE before wiping everything.
func (a *App) confirmPurge() {
	form := tview.NewForm().
		AddInputField(`Type "DELETE" to confirm (case-sensitive)`, "", 20, nil, nil)
	form.SetFieldBackgroundColor(theme.Surface).
		SetButtonBackgroundColor(theme.AccentDim).
		SetLabelColor(theme.Text)
	form.SetBackgroundColor(theme.Panel)
	form.AddButton("Cancel", func() { a.pages.RemovePage("modal") })
	form.AddButton("Delete everything", func() {
		typed := form.GetFormItem(0).(*tview.InputField).GetText()
		a.pages.RemovePage("modal")
		if typed != "DELETE" {
			a.showMessage("Uninstall cancelled",
				"The confirmation word did not match. Nothing was removed.", true)
			return
		}
		a.runUninstall(true)
	})
	a.pushModal("Confirm total removal", form, 64, 7)
	a.tv.SetFocus(form)
}

func (a *App) runUninstall(purge bool) {
	// Find uninstall.sh (installer drops it into ~/falconpulsar).
	home := actions.HomeDir()
	script := filepath.Join(home, "uninstall.sh")
	if _, err := os.Stat(script); err != nil {
		a.showMessage("Uninstaller not found",
			"Expected at "+script+". Re-run the installer to get it back.",
			true)
		return
	}

	// Copy the script to /tmp BEFORE running it — when the script deletes
	// its parent directory, bash won't lose the file it's reading from.
	// Also copy auth.sh alongside so the standalone uninstaller can still
	// require admin credentials.
	tmp := fmt.Sprintf("/tmp/fp-uninstall-%d.sh", os.Getpid())
	if data, err := os.ReadFile(script); err == nil {
		_ = os.WriteFile(tmp, data, 0700)
	}
	authSrc := filepath.Join(home, "auth.sh")
	authTmp := filepath.Join("/tmp", "auth.sh")
	if data, err := os.ReadFile(authSrc); err == nil {
		_ = os.WriteFile(authTmp, data, 0600)
		defer os.Remove(authTmp)
	}

	flag := "--keep"
	if purge {
		flag = "--purge"
	}
	a.showMessage("Uninstalling…",
		"Running uninstall.sh "+flag+" --yes\nPlease wait — this may take up to a minute.",
		false)

	go func() {
		// Run the /tmp copy so bash doesn't die when $FP_HOME is deleted.
		runPath := script
		if _, err := os.Stat(tmp); err == nil {
			runPath = tmp
		}
		// --force: the TUI runs inside alt-screen mode, so prompting for
		// admin credentials via bash `read </dev/tty` would race with tview's
		// input handler. The TUI already guards uninstall with a DELETE-type
		// confirmation, so skipping the bash auth gate here is safe — the
		// user is already locally authenticated by having shell access +
		// fp binary access.
		cmd := exec.Command("bash", runPath, flag, "--yes", "--force")
		cmd.Dir = "/" // cwd outside $FP_HOME
		out, err := cmd.CombinedOutput()
		_ = os.Remove(tmp) // best-effort cleanup
		a.tv.QueueUpdateDraw(func() {
			a.pages.RemovePage("modal")
			if err != nil {
				a.showMessage("Uninstall failed",
					fmt.Sprintf("%v\n\n%s", err, truncate(string(out), 1500)),
					true)
				return
			}
			finalMsg := "FalconPulsar has been removed. Your data at ~/falconpulsar/data is preserved."
			if purge {
				finalMsg = "FalconPulsar has been completely removed, including your data directory."
			}
			a.showMessage("Uninstall complete",
				finalMsg+"\n\nThe console will now exit.",
				true)
			// Give the user a moment to read, then terminate.
			go func() {
				time.Sleep(3 * time.Second)
				a.tv.QueueUpdateDraw(func() { a.tv.Stop() })
			}()
		})
	}()
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "\n…(truncated)"
}

func aiToggleLabel() string {
	if actions.AIGatewayEnabled() {
		return "Disable AI Capabilities"
	}
	return "Enable AI Capabilities"
}

func (a *App) enableAIGateway() {
	// Admin auth required every time (matches macOS menu bar + Windows tray).
	// askAdminThen already prompts for credentials; on first-time enable the
	// resulting client is used to mint the gateway service token.
	a.askAdminThen("Enable AI Capabilities", func(cli *api.Client, user, pass string) {
		ctx := context.Background()
		// First-time bootstrap: create the gateway service token via REST.
		if !actions.HasGatewayToken() {
			token, err := cli.CreateGatewayToken(ctx)
			if err != nil {
				a.showMessage("Token setup failed", err.Error(), true)
				return
			}
			if err := actions.SetEnvValue("FP_API_KEY", token); err != nil {
				a.showMessage("Token setup failed", err.Error(), true)
				return
			}
		}
		actions.EnsureGatewayConfig()
		_ = actions.SetEnvValue("FP_AI_GATEWAY_ENABLED", "true")
		a.showMessage("Enabling AI Capabilities…",
			"Pulling image and starting the AI gateway container. This may take a moment.", false)
		go func() {
			// Target ai-gateway service explicitly — never touch core/ui.
			if err := actions.Compose(ctx, nil, nil, "--profile", "ai", "pull", "ai-gateway"); err != nil {
				a.tv.QueueUpdateDraw(func() {
					a.pages.RemovePage("modal")
					a.showMessage("Pull failed", err.Error(), true)
				})
				return
			}
			err := actions.Compose(ctx, nil, nil, "--profile", "ai", "up", "-d", "ai-gateway")
			if err == nil {
				// Wipe the gateway's self-seeded provider/model catalog
				// so the user lands on a clean AI configuration. See
				// actions.WipeGatewaySeedDefaults for the rationale.
				_ = actions.WipeGatewaySeedDefaults(ctx, nil)
			}
			a.tv.QueueUpdateDraw(func() {
				a.pages.RemovePage("modal")
				a.sections = buildSections()
				a.status = actions.Poll(ctx)
				a.refreshServices()
				if err != nil {
					a.showMessage("Error", err.Error(), true)
				} else {
					a.showMessage("AI Capabilities enabled",
						"Close any open FalconPulsar Web UI sessions and sign in again to see the AI features, then configure LLM providers in Settings > AI Configuration.", true)
				}
			})
		}()
	})
}

func (a *App) disableAIGateway() {
	// Admin auth required every time, then the destructive confirmation.
	a.askAdminThen("Disable AI Capabilities", func(cli *api.Client, user, pass string) {
		m := tview.NewModal().
			SetText("Disable AI Capabilities?\n\nThis will stop and remove the AI gateway container, delete its data directory and gateway.yaml, clear the service token, and delete the AI gateway image. Core and UI stay running. Re-enabling later will re-download the image.").
			AddButtons([]string{"Disable and Remove", "Cancel"}).
			SetDoneFunc(func(idx int, label string) {
				a.pages.RemovePage("modal")
				if label != "Disable and Remove" {
					return
				}
				_ = actions.SetEnvValue("FP_AI_GATEWAY_ENABLED", "false")
				a.showMessage("Disabling AI Capabilities…",
					"Removing AI gateway container, data, config, token, and image.", false)
				go func() {
					_ = actions.SurgicalDisableAI(context.Background(), nil)
					a.tv.QueueUpdateDraw(func() {
						a.pages.RemovePage("modal")
						a.sections = buildSections()
						a.status = actions.Poll(context.Background())
						a.refreshServices()
						a.showMessage("AI Capabilities disabled",
							"AI Capabilities disabled and removed. Core and UI are unaffected.", true)
					})
				}()
			})
		m.SetBackgroundColor(theme.Panel)
		a.pages.AddPage("modal", m, true, true)
	})
}

func (a *App) doExport() {
	a.askAdminThen("Export Configuration", func(cli *api.Client, user, pass string) {
		a.askPathThen("Save backup as…", "falconpulsar-config.fpconfig", func(path string) {
			a.showMessage("Exporting…", "Please wait", false)
			go func() {
				err := configbackup.Export(context.Background(), path, cli, user, pass)
				a.tv.QueueUpdateDraw(func() {
					a.pages.RemovePage("modal")
					if err != nil {
						a.showMessage("Export failed", err.Error(), true)
					} else {
						a.showMessage("Export complete", "Saved to "+path, true)
					}
				})
			}()
		})
	})
}

func (a *App) doImport() {
	a.askPathThen("Import backup file…", "", func(path string) {
		a.askAdminThen("Import Configuration", func(cli *api.Client, user, pass string) {
			a.showMessage("Importing…", "Please wait", false)
			go func() {
				err := configbackup.Import(context.Background(), path, cli, user, pass)
				a.tv.QueueUpdateDraw(func() {
					a.pages.RemovePage("modal")
					if err != nil {
						a.showMessage("Import failed", err.Error(), true)
					} else {
						a.showMessage("Import complete",
							"Restart the stack (F4) for changes to take effect.", true)
					}
				})
			}()
		})
	})
}

// ─── Dialogs ────────────────────────────────────────────────────────────────

func (a *App) showMessage(title, body string, dismissable bool) {
	m := tview.NewModal().
		SetText(fmt.Sprintf("[::b]%s[-:-:-]\n\n%s", title, body)).
		SetBackgroundColor(theme.Panel)
	if dismissable {
		m.AddButtons([]string{"OK"}).
			SetDoneFunc(func(int, string) { a.pages.RemovePage("modal") })
	}
	a.pages.AddPage("modal", m, true, true)
}

func (a *App) pushModal(title string, content tview.Primitive, w, h int) {
	frame := tview.NewFrame(content).
		SetBorders(1, 1, 1, 1, 2, 2).
		AddText(title, true, tview.AlignCenter, theme.Accent)
	frame.SetBackgroundColor(theme.Panel)
	frame.SetBorder(true).SetBorderColor(theme.BorderFocus)
	flex := tview.NewFlex().
		AddItem(nil, 0, 1, false).
		AddItem(tview.NewFlex().SetDirection(tview.FlexRow).
			AddItem(nil, 0, 1, false).
			AddItem(frame, h+4, 0, true).
			AddItem(nil, 0, 1, false),
			w, 0, true).
		AddItem(nil, 0, 1, false)
	a.pages.AddPage("modal", flex, true, true)
}

func (a *App) askAdminThen(purpose string, then func(*api.Client, string, string)) {
	form := tview.NewForm().
		AddInputField("Admin username", "admin", 30, nil, nil).
		AddPasswordField("Admin password", "", 30, '*', nil)
	form.SetFieldBackgroundColor(theme.Surface).
		SetButtonBackgroundColor(theme.AccentDim).
		SetLabelColor(theme.Text)
	form.SetBackgroundColor(theme.Panel)
	form.AddButton("Continue", func() {
		user := form.GetFormItem(0).(*tview.InputField).GetText()
		pass := form.GetFormItem(1).(*tview.InputField).GetText()
		a.pages.RemovePage("modal")
		go func() {
			cli := api.New()
			if err := cli.Login(context.Background(), user, pass); err != nil {
				a.tv.QueueUpdateDraw(func() { a.showMessage("Login failed", err.Error(), true) })
				return
			}
			isAdmin, err := cli.IsAdmin(context.Background())
			if err != nil {
				a.tv.QueueUpdateDraw(func() { a.showMessage("Error", err.Error(), true) })
				return
			}
			if !isAdmin {
				a.tv.QueueUpdateDraw(func() { a.showMessage("Access denied", auth.ErrNotAdmin.Error(), true) })
				return
			}
			a.tv.QueueUpdateDraw(func() { then(cli, user, pass) })
		}()
	})
	form.AddButton("Cancel", func() { a.pages.RemovePage("modal") })
	a.pushModal(purpose, form, 52, 8)
	a.tv.SetFocus(form)
}

func (a *App) askPathThen(title, suggestion string, then func(string)) {
	form := tview.NewForm().
		AddInputField("File path", suggestion, 60, nil, nil)
	form.SetFieldBackgroundColor(theme.Surface).
		SetButtonBackgroundColor(theme.AccentDim).
		SetLabelColor(theme.Text)
	form.SetBackgroundColor(theme.Panel)
	form.AddButton("OK", func() {
		path := form.GetFormItem(0).(*tview.InputField).GetText()
		a.pages.RemovePage("modal")
		if path != "" {
			then(path)
		}
	})
	form.AddButton("Cancel", func() { a.pages.RemovePage("modal") })
	a.pushModal(title, form, 72, 5)
	a.tv.SetFocus(form)
}

// ─── Help & About (left-aligned, not Modal) ────────────────────────────────

func (a *App) showHelp() {
	tv := tview.NewTextView().SetDynamicColors(true).SetWrap(false)
	tv.SetBackgroundColor(theme.Panel)
	tv.SetText(
		"[::b]Keyboard Shortcuts[-:-:-]\n\n" +
			"  [#00AAFF]F1[-]    Help\n" +
			"  [#00AAFF]F2[-]    Start stack\n" +
			"  [#00AAFF]F3[-]    Stop stack\n" +
			"  [#00AAFF]F4[-]    Restart stack\n" +
			"  [#00AAFF]F5[-]    View logs (all services)\n" +
			"  [#00AAFF]F6[-]    Edit core config\n" +
			"  [#00AAFF]F7[-]    Export configuration (admin)\n" +
			"  [#00AAFF]F8[-]    Import configuration (admin)\n" +
			"  [#00AAFF]F9[-]    Open menu bar\n" +
			"  [#00AAFF]F10[-]   Quit\n" +
			"  [#00AAFF]Q[-]     Quit\n" +
			"  [#00AAFF]↑/↓[-]   Navigate services\n\n" +
			"[::b]CLI mode (for scripts)[-:-:-]\n\n" +
			"  fp status [--json]\n" +
			"  fp start | stop | restart\n" +
			"  fp logs [service]\n" +
			"  fp open\n" +
			"  fp config edit [core|gateway|compose]\n" +
			"  fp config export <file>\n" +
			"  fp config import <file>\n\n" +
			"  https://falconpulsar.com/docs\n\n" +
			"[#6B7280]Press Esc or Enter to close.[-]")
	tv.SetInputCapture(func(ev *tcell.EventKey) *tcell.EventKey {
		if ev.Key() == tcell.KeyEscape || ev.Key() == tcell.KeyEnter {
			a.pages.RemovePage("modal")
			return nil
		}
		return ev
	})
	a.pushModal("Keyboard Shortcuts", tv, 64, 24)
}

func (a *App) showAbout() {
	tv := tview.NewTextView().SetDynamicColors(true).SetWrap(true)
	tv.SetBackgroundColor(theme.Panel)
	tv.SetText(fmt.Sprintf(
		"[::b]FalconPulsar[-:-:-]\n\n"+
			"Version:     %s\n"+
			"Stack dir:   %s\n"+
			"Web UI:      http://localhost:8080\n"+
			"REST API:    http://localhost:7433\n"+
			"AI Capabilities: http://localhost:7436\n\n"+
			"Website:     https://falconpulsar.com\n"+
			"Docs:        https://falconpulsar.com/docs\n"+
			"Roadmap:     https://falconpulsar.com/roadmap\n\n"+
			"(c) 2026 FalconPulsar Contributors — GNU AGPL v3\n\n"+
			"[#6B7280]Press Esc or Enter to close.[-]",
		cli.Version, actions.HomeDir()))
	tv.SetInputCapture(func(ev *tcell.EventKey) *tcell.EventKey {
		if ev.Key() == tcell.KeyEscape || ev.Key() == tcell.KeyEnter {
			a.pages.RemovePage("modal")
			return nil
		}
		return ev
	})
	a.pushModal("About FalconPulsar", tv, 60, 14)
}
