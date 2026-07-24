// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

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
	Text        = tcell.NewRGBColor(0xFF, 0xFF, 0xFF) // pure white for menus / cards
	TextDim     = tcell.NewRGBColor(0xB8, 0xBF, 0xCC)
	TextMuted   = tcell.NewRGBColor(0x6B, 0x72, 0x80)
	// Saturated blue so terminals can't quantize it into gray.
	// This matches the FalconPulsar logo tone (darker sibling of Accent).
	MenuBg     = tcell.NewRGBColor(0x08, 0x2F, 0x4F)
	MenuItemBg = tcell.NewRGBColor(0x08, 0x2F, 0x4F)
	Running    = tcell.NewRGBColor(0x22, 0xC5, 0x5E)
	Partial    = tcell.NewRGBColor(0xF5, 0x9E, 0x0B)
	Stopped    = tcell.NewRGBColor(0xEF, 0x44, 0x44)
	SelectedBg = tcell.NewRGBColor(0x00, 0xAA, 0xFF)
	SelectedFg = tcell.NewRGBColor(0x0A, 0x0A, 0x19)
)
