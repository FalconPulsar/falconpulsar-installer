// Package theme defines the FalconPulsar-branded palette for the TUI.
package theme

import "github.com/gdamore/tcell/v2"

// Color palette lifted from the FalconPulsar brand.
// Background: deep navy — the dark side of the logo.
// Accent:     bright cyan-blue — matches falconpulsar.com and the logo.
// Status:     green / amber / red for running / partial / stopped.
var (
	Background  = tcell.NewRGBColor(0x0A, 0x0A, 0x19)
	Surface     = tcell.NewRGBColor(0x11, 0x14, 0x24)
	Panel       = tcell.NewRGBColor(0x15, 0x19, 0x2B)
	Border      = tcell.NewRGBColor(0x33, 0x3A, 0x55)
	BorderFocus = tcell.NewRGBColor(0x00, 0xAA, 0xFF)
	Accent      = tcell.NewRGBColor(0x00, 0xAA, 0xFF)
	AccentDim   = tcell.NewRGBColor(0x00, 0x70, 0xB0)
	Text        = tcell.NewRGBColor(0xE5, 0xE7, 0xEB)
	TextDim     = tcell.NewRGBColor(0x9C, 0xA3, 0xAF)
	TextMuted   = tcell.NewRGBColor(0x6B, 0x72, 0x80)
	Running     = tcell.NewRGBColor(0x22, 0xC5, 0x5E)
	Partial     = tcell.NewRGBColor(0xF5, 0x9E, 0x0B)
	Stopped     = tcell.NewRGBColor(0xEF, 0x44, 0x44)
	SelectedBg  = tcell.NewRGBColor(0x00, 0xAA, 0xFF)
	SelectedFg  = tcell.NewRGBColor(0x0A, 0x0A, 0x19)
)
