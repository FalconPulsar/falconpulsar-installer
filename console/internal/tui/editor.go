// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

package tui

import (
	"fmt"
	"os"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/theme"
	"github.com/gdamore/tcell/v2"
	"github.com/rivo/tview"
)

// openEditor shows a full-screen embedded editor for the given file path.
// Ctrl+S saves and closes; Esc discards and closes. Read errors produce a
// dismissible error dialog.
func (a *App) openEditor(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		a.showMessage("Cannot open file", err.Error(), true)
		return
	}

	area := tview.NewTextArea().
		SetText(string(data), false).
		SetPlaceholder("(empty file)")
	area.SetBackgroundColor(theme.Surface)

	status := tview.NewTextView().SetDynamicColors(true)
	status.SetBackgroundColor(theme.Surface)
	status.SetText(fmt.Sprintf(
		"[#00AAFF]Ctrl+S[-] save and close   "+
			"[#00AAFF]Esc[-] cancel without saving   "+
			"[#9CA3AF]%s[-]", path))

	frame := tview.NewFrame(area).
		SetBorders(0, 0, 0, 0, 1, 1).
		AddText(" Editing: "+path+" ", true, tview.AlignLeft, theme.Accent)
	frame.SetBackgroundColor(theme.Panel)
	frame.SetBorder(true).SetBorderColor(theme.BorderFocus)

	layout := tview.NewFlex().SetDirection(tview.FlexRow).
		AddItem(frame, 0, 1, true).
		AddItem(status, 1, 0, false)
	layout.SetBackgroundColor(theme.Panel)

	close := func() {
		a.pages.RemovePage("editor")
		a.tv.SetFocus(a.services)
	}

	area.SetInputCapture(func(ev *tcell.EventKey) *tcell.EventKey {
		// Ctrl+S → save and close
		if ev.Key() == tcell.KeyCtrlS {
			if err := os.WriteFile(path, []byte(area.GetText()), 0644); err != nil {
				a.showMessage("Save failed", err.Error(), true)
				return nil
			}
			close()
			a.showMessage("Saved", path, true)
			return nil
		}
		// Esc → cancel without saving
		if ev.Key() == tcell.KeyEscape {
			close()
			return nil
		}
		return ev
	})

	a.pages.AddPage("editor", layout, true, true)
	a.tv.SetFocus(area)
}

// openViewer shows a scrollable read-only view of a file.
func (a *App) openViewer(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		a.showMessage("Cannot open file", err.Error(), true)
		return
	}
	tv := tview.NewTextView().SetWrap(false)
	tv.SetBackgroundColor(theme.Surface)
	tv.SetText(string(data))

	status := tview.NewTextView().SetDynamicColors(true)
	status.SetBackgroundColor(theme.Surface)
	status.SetText(fmt.Sprintf(
		"[#00AAFF]↑/↓[-] scroll   [#00AAFF]PgUp/PgDn[-] page   "+
			"[#00AAFF]g/G[-] top/bottom   [#00AAFF]Esc[-] close   "+
			"[#9CA3AF]%s[-]", path))

	frame := tview.NewFrame(tv).
		SetBorders(0, 0, 0, 0, 1, 1).
		AddText(" Viewing: "+path+" ", true, tview.AlignLeft, theme.Accent)
	frame.SetBackgroundColor(theme.Panel)
	frame.SetBorder(true).SetBorderColor(theme.BorderFocus)

	layout := tview.NewFlex().SetDirection(tview.FlexRow).
		AddItem(frame, 0, 1, true).
		AddItem(status, 1, 0, false)
	layout.SetBackgroundColor(theme.Panel)

	close := func() {
		a.pages.RemovePage("viewer")
		a.tv.SetFocus(a.services)
	}
	tv.SetInputCapture(func(ev *tcell.EventKey) *tcell.EventKey {
		if ev.Key() == tcell.KeyEscape {
			close()
			return nil
		}
		switch ev.Rune() {
		case 'q', 'Q':
			close()
			return nil
		case 'g':
			tv.ScrollToBeginning()
			return nil
		case 'G':
			tv.ScrollToEnd()
			return nil
		}
		return ev
	})

	a.pages.AddPage("viewer", layout, true, true)
	a.tv.SetFocus(tv)
}
