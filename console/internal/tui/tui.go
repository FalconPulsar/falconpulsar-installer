// Package tui implements the Midnight-Commander-style interactive console.
package tui

import (
	"context"
	"fmt"
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

type App struct {
	tv         *tview.Application
	pages      *tview.Pages
	layout     *tview.Flex
	menuBar    *tview.TextView
	services   *tview.Table
	details    *tview.TextView
	fkeys      *tview.TextView
	status     actions.Status
	stopPoll   chan struct{}
}

// Run launches the TUI event loop.
func Run() error {
	app := &App{
		tv:       tview.NewApplication(),
		stopPoll: make(chan struct{}),
	}
	app.build()
	app.startPolling()
	defer close(app.stopPoll)
	return app.tv.Run()
}

func (a *App) build() {
	a.menuBar = tview.NewTextView().
		SetDynamicColors(true).
		SetRegions(true).
		SetWrap(false)
	a.menuBar.SetText(renderMenuBar(-1))
	a.menuBar.SetBackgroundColor(theme.Surface)

	a.services = tview.NewTable().
		SetSelectable(true, false).
		SetSeparator(' ').
		SetBorders(false)
	a.services.SetBorder(true).
		SetTitle(" Services ").
		SetTitleColor(theme.Accent).
		SetBorderColor(theme.Border).
		SetBackgroundColor(theme.Panel)
	a.services.SetSelectedStyle(tcell.StyleDefault.Background(theme.SelectedBg).Foreground(theme.SelectedFg))
	a.services.SetSelectionChangedFunc(func(row, col int) {
		a.refreshDetails(row)
	})

	a.details = tview.NewTextView().
		SetDynamicColors(true).
		SetWrap(true)
	a.details.SetBorder(true).
		SetTitle(" Details ").
		SetTitleColor(theme.Accent).
		SetBorderColor(theme.Border).
		SetBackgroundColor(theme.Panel)

	a.fkeys = tview.NewTextView().
		SetDynamicColors(true).
		SetWrap(false)
	a.fkeys.SetText(fkeyBar()).
		SetBackgroundColor(theme.Surface)

	content := tview.NewFlex().SetDirection(tview.FlexColumn).
		AddItem(a.services, 0, 1, true).
		AddItem(a.details, 0, 1, false)

	a.layout = tview.NewFlex().SetDirection(tview.FlexRow).
		AddItem(a.menuBar, 1, 0, false).
		AddItem(content, 0, 1, true).
		AddItem(a.fkeys, 1, 0, false)
	a.layout.SetBackgroundColor(theme.Background)

	a.pages = tview.NewPages().
		AddPage("main", a.layout, true, true)

	a.tv.SetRoot(a.pages, true).EnableMouse(false)
	a.tv.SetInputCapture(a.handleKey)

	a.refreshServices()
}

// ── Layout helpers ──────────────────────────────────────────────────────────

func renderMenuBar(active int) string {
	labels := []string{"Stack", "Logs", "Config", "Backup", "Help"}
	out := " "
	for i, l := range labels {
		if i == active {
			out += fmt.Sprintf("[#0A0A19:#00AAFF] %s [-:-:-] ", l)
		} else {
			out += fmt.Sprintf("[#E5E7EB] %s [-] ", l)
		}
	}
	return out
}

func fkeyBar() string {
	keys := []struct{ k, l string }{
		{"F1", "Help"}, {"F2", "Start"}, {"F3", "Stop"},
		{"F4", "Restart"}, {"F5", "Logs"}, {"F6", "Edit"},
		{"F7", "Export"}, {"F8", "Import"}, {"F10", "Quit"},
	}
	out := ""
	for _, k := range keys {
		out += fmt.Sprintf("[#00AAFF]%s[-] %s  ", k.k, k.l)
	}
	return out
}

// ── Data refresh ────────────────────────────────────────────────────────────

func (a *App) startPolling() {
	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-a.stopPoll:
				return
			case <-ticker.C:
				a.status = actions.Poll(context.Background())
				a.tv.QueueUpdateDraw(func() {
					a.refreshServices()
				})
			}
		}
	}()
	a.status = actions.Poll(context.Background())
}

func (a *App) refreshServices() {
	a.services.Clear()
	rows := []struct {
		name, note string
		on         bool
	}{
		{"Core", "time-series engine", a.status.Core},
		{"Web UI", "http://localhost:8080", a.status.UI},
		{"AI Gateway", "http://localhost:7436", a.status.Gateway},
		{"REST API", "http://localhost:7433", a.status.APIHealthy},
	}
	for i, r := range rows {
		dot := tview.NewTableCell("●").SetAlign(tview.AlignCenter)
		name := tview.NewTableCell(r.name)
		state := tview.NewTableCell(stateLabel(r.on))
		note := tview.NewTableCell(r.note)
		name.SetTextColor(theme.Text)
		note.SetTextColor(theme.TextDim)
		if r.on {
			dot.SetTextColor(theme.Running)
			state.SetTextColor(theme.Running)
		} else {
			dot.SetTextColor(theme.Stopped)
			state.SetTextColor(theme.Stopped)
		}
		a.services.SetCell(i, 0, dot)
		a.services.SetCell(i, 1, name)
		a.services.SetCell(i, 2, state)
		a.services.SetCell(i, 3, note)
	}
	a.refreshDetails(a.services.GetSelection())
}

func (a *App) refreshDetails(row ...int) {
	var r int
	if len(row) > 0 {
		r = row[0]
	}
	labels := []string{"Core", "Web UI", "AI Gateway", "REST API"}
	if r < 0 || r >= len(labels) {
		r = 0
	}
	title := labels[r]
	agg := a.status.Aggregate()
	s := fmt.Sprintf(
		"[::b]%s[-:-:-]\n\n"+
			"Stack aggregate: [#00AAFF]%s[-]\n\n"+
			"Core         %s\n"+
			"Web UI       %s\n"+
			"AI Gateway   %s\n"+
			"REST API     %s\n\n"+
			"[#9CA3AF]Version %s — %s[-]",
		title, agg,
		stateLabel(a.status.Core),
		stateLabel(a.status.UI),
		stateLabel(a.status.Gateway),
		stateLabel(a.status.APIHealthy),
		cli.Version,
		actions.HomeDir(),
	)
	a.details.SetText(s)
}

func stateLabel(on bool) string {
	if on {
		return "[#22C55E]running[-]"
	}
	return "[#EF4444]stopped[-]"
}

// ── Key handling ────────────────────────────────────────────────────────────

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
		a.showLogsPicker()
		return nil
	case tcell.KeyF6:
		a.showConfigPicker()
		return nil
	case tcell.KeyF7:
		a.doExport()
		return nil
	case tcell.KeyF8:
		a.doImport()
		return nil
	case tcell.KeyF10:
		a.tv.Stop()
		return nil
	case tcell.KeyCtrlC:
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

// ── Actions ─────────────────────────────────────────────────────────────────

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

func (a *App) showLogsPicker() {
	services := []string{"All", "core", "ui", "ai-gateway"}
	list := tview.NewList().ShowSecondaryText(false)
	for _, s := range services {
		s := s
		list.AddItem(s, "", 0, func() {
			a.pages.RemovePage("modal")
			a.tv.Suspend(func() {
				if s == "All" {
					_ = actions.Compose(context.Background(), nil, nil, "logs", "-f", "--tail", "100")
				} else {
					_ = actions.Compose(context.Background(), nil, nil, "logs", "-f", "--tail", "100", s)
				}
			})
		})
	}
	list.AddItem("Cancel", "", 0, func() { a.pages.RemovePage("modal") })
	a.pushModal("View Logs", list, 40, 8)
}

func (a *App) showConfigPicker() {
	list := tview.NewList().ShowSecondaryText(false)
	opts := []struct{ label, rel string }{
		{"Core (falconpulsar.toml)", filepath.Join("data", "falconpulsar.toml")},
		{"AI Gateway (gateway.yaml)", "gateway.yaml"},
		{"Docker Compose (compose.yml)", "compose.yml"},
	}
	for _, o := range opts {
		o := o
		list.AddItem(o.label, "", 0, func() {
			a.pages.RemovePage("modal")
			a.tv.Suspend(func() {
				_ = actions.EditFile(filepath.Join(actions.HomeDir(), o.rel))
			})
		})
	}
	list.AddItem("Cancel", "", 0, func() { a.pages.RemovePage("modal") })
	a.pushModal("Edit Configuration", list, 50, 8)
}

func (a *App) doExport() {
	a.askAdminThen("Export Configuration", func(cli *api.Client, user, pass string) {
		a.askPathThen("Save as…", "falconpulsar-config.fpconfig", func(path string) {
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
	a.askPathThen("Import from file…", "", func(path string) {
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

// ── Modal helpers ───────────────────────────────────────────────────────────

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
	frame.SetBackgroundColor(theme.Panel).SetBorder(true).SetBorderColor(theme.BorderFocus)
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
}

func (a *App) showHelp() {
	text := `[::b]FalconPulsar Console — Keyboard Shortcuts[-:-:-]

  F1   Help
  F2   Start stack
  F3   Stop stack
  F4   Restart stack
  F5   View logs
  F6   Edit config file
  F7   Export configuration (admin)
  F8   Import configuration (admin)
  F10  Quit
  Q    Quit
  ↑/↓  Navigate services

For automation use plain subcommands:
  fp status --json
  fp start | stop | restart
  fp logs [service]
  fp config export <file>
  fp config import <file>

https://falconpulsar.com/docs`
	m := tview.NewModal().
		SetText(text).
		AddButtons([]string{"OK"}).
		SetDoneFunc(func(int, string) { a.pages.RemovePage("modal") }).
		SetBackgroundColor(theme.Panel)
	a.pages.AddPage("modal", m, true, true)
}

