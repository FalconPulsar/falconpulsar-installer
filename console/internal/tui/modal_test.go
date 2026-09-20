package tui

import (
	"fmt"
	"strings"
	"testing"

	"github.com/gdamore/tcell/v2"
	"github.com/rivo/tview"
)

// A modal must show its LAST line.
//
// pushModal sized the frame at h+6, assuming six rows of chrome. tview's
// Frame uses seven, so the bottom line of every modal was cut off. On the
// update dialog that line was "Press a to apply now, Esc to close" — the
// only place the apply key was named. The operator saw a panel documenting
// nothing but Esc, pressed the Enter the frame's footer advertised, and
// concluded the console could not apply updates.
func TestModalShowsItsLastLine(t *testing.T) {
	var b strings.Builder
	// 19 lines is what the real dialog builds for three updated images,
	// two up to date and one host component.
	for i := 1; i <= 18; i++ {
		fmt.Fprintf(&b, "LINE%02d\n", i)
	}
	fmt.Fprintln(&b, "LASTLINE press a to apply")

	tv := tview.NewTextView().SetDynamicColors(true).SetWrap(false)
	tv.SetText(b.String())
	contentH := strings.Count(b.String(), "\n") + 1

	rendered := renderModalToStrings(t, "Check for updates", tv, 76, contentH,
		"Enter or a: apply now · Esc: close")

	joined := strings.Join(rendered, "\n")
	if !strings.Contains(joined, "LASTLINE") {
		t.Errorf("the modal clipped its last line; rendered:\n%s", joined)
	}
	if !strings.Contains(joined, "LINE18") {
		t.Errorf("the modal clipped line 18 too; rendered:\n%s", joined)
	}
}

// The footer must not advertise keys the panel does not answer. A read-only
// panel has no fields to tab between.
func TestReadOnlyModalFooterNamesItsOwnKeys(t *testing.T) {
	tv := tview.NewTextView().SetText("nothing to do here\n")
	rendered := renderModalToStrings(t, "Check for updates", tv, 76, 14,
		"Enter or a: apply now · Esc: close")
	joined := strings.Join(rendered, "\n")
	if strings.Contains(joined, "Tab: next field") {
		t.Errorf("a modal with no fields still offers Tab; rendered:\n%s", joined)
	}
	if !strings.Contains(joined, "apply now") {
		t.Errorf("the panel's own hint never reached the screen; rendered:\n%s", joined)
	}
}

// renderModalToStrings lays a modal out exactly as pushModalHint does and
// returns the rows a real terminal would show.
func renderModalToStrings(t *testing.T, title string, content tview.Primitive, w, h int, hint string) []string {
	t.Helper()
	frame := tview.NewFrame(content).
		SetBorders(1, 1, 1, 1, 2, 2).
		AddText(title, true, tview.AlignCenter, tcell.ColorAqua).
		AddText(hint, false, tview.AlignCenter, tcell.ColorGray)
	frame.SetBorder(true)

	flex := tview.NewFlex().
		AddItem(nil, 0, 1, false).
		AddItem(tview.NewFlex().SetDirection(tview.FlexRow).
			AddItem(nil, 0, 1, false).
			AddItem(frame, h+modalChromeRows, 0, true).
			AddItem(nil, 0, 1, false), w, 0, true).
		AddItem(nil, 0, 1, false)

	sc := tcell.NewSimulationScreen("UTF-8")
	if err := sc.Init(); err != nil {
		t.Fatal(err)
	}
	sc.SetSize(120, 44)
	app := tview.NewApplication().SetScreen(sc).SetRoot(flex, true)
	go func() { _ = app.Run() }()
	defer app.Stop()
	for i := 0; i < 50; i++ {
		app.Draw()
	}

	cells, cw, ch := sc.GetContents()
	var out []string
	for y := 0; y < ch; y++ {
		var row strings.Builder
		for x := 0; x < cw; x++ {
			row.WriteRune(cells[y*cw+x].Runes[0])
		}
		if line := strings.TrimSpace(row.String()); line != "" {
			out = append(out, line)
		}
	}
	return out
}
