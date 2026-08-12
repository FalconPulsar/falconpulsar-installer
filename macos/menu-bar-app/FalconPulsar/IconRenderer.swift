// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

// =============================================================================
// IconRenderer.swift -- draws the shared icon set (Icons.g.swift) with AppKit.
//
// The macOS half of a deliberate pair. IconRenderer.cs is the Windows half and
// does the same four things in the same order; keep them in step. Between them
// they are the ONLY code that interprets a path from icons.def, which is why
// the grammar is four absolute commands and nothing else -- every feature
// added here has to be added correctly twice.
//
// WHY THIS REPLACED SF SYMBOLS
//
// SF Symbols is an Apple font and cannot ship on Windows, so the Windows tray
// used Segoe MDL2 Assets instead. The two menus could never agree: `brain`,
// `square.grid.2x2` and `safari` have no MDL2 equivalent at all. Owning the
// geometry makes both platforms identical by construction.
//
// The one visible change on THIS platform: `Request a Feature` used a literal
// emoji, which is full-colour and font-dependent, so it never matched the
// monochrome items around it. It is a drawn mark now like everything else.
// =============================================================================

import AppKit

enum IconRenderer {

    /// Render a named icon from Icons.g.swift into a square NSImage.
    ///
    /// - Parameters:
    ///   - name: key in `Icons.all`
    ///   - color: ink
    ///   - size: point size; the inline menu icons are 14
    ///   - knockout: colour a `K` subpath paints in — the menu background, so
    ///     an arrow inside a filled disc reads as a hole. `.clear` by default,
    ///     which knocks a real hole through and lets the menu show through
    ///     whatever its material is (AppKit menus are translucent; painting a
    ///     solid "background colour" would show as a grey plate).
    static func render(_ name: String,
                       color: NSColor,
                       size: CGFloat = 14,
                       knockout: NSColor = .clear) -> NSImage
    {
        let image = NSImage(size: NSSize(width: size, height: size))
        guard let subpaths = Icons.all[name] else {
            // Unknown name is a build-time mistake — the caller passes a
            // literal. A blank image is survivable; a crash on menu build is
            // not. Mirrors the same decision in IconRenderer.cs.
            return image
        }

        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current else { return image }
        ctx.imageInterpolation = .high
        ctx.shouldAntialias = true

        // icons.def is authored y-DOWN (SVG / GDI+ convention). AppKit's
        // default is y-up, so flip once here. The Windows renderer needs no
        // equivalent — this is the single place the two differ, and it is why
        // the same path data produces the same picture on both.
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: size)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()

        let scale = size / 24.0

        for sp in subpaths {
            let path = buildPath(sp.data)
            let xf = NSAffineTransform()
            xf.scale(by: scale)
            path.transform(using: xf as AffineTransform)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.windingRule = .nonZero

            switch sp.mode.first {
            case "F":
                color.setFill()
                path.fill()
            case "K":
                if knockout == .clear {
                    // Punch through instead of painting over: menus are
                    // translucent, so a solid fill would read as a grey plate
                    // sitting inside the disc.
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    NSColor.black.setFill()
                    path.fill()
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                } else {
                    knockout.setFill()
                    path.fill()
                }
            case "S":
                let w = CGFloat(Double(sp.mode.dropFirst()) ?? 2.0)
                color.setStroke()
                path.lineWidth = w * scale
                path.stroke()
            default:
                break
            }
        }

        // Menu icons follow the menu's own text colour (and invert correctly
        // when a row is highlighted) only if they are templates.
        image.isTemplate = true
        return image
    }

    /// Absolute M / L / C / Z only. Mirrors BuildPath() in IconRenderer.cs —
    /// if you change one, change the other. sync-icons.sh rejects anything
    /// outside this grammar before it can reach either parser.
    private static func buildPath(_ data: String) -> NSBezierPath {
        let path = NSBezierPath()
        let tokens = data.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)

        var i = 0
        func num() -> CGFloat {
            // The generator validated every token, so a failure here means
            // Icons.g.swift was hand-edited despite the header saying not to.
            defer { i += 1 }
            guard i < tokens.count, let v = Double(tokens[i]) else { return 0 }
            return CGFloat(v)
        }

        while i < tokens.count {
            let cmd = tokens[i]; i += 1
            switch cmd {
            case "M":
                path.move(to: NSPoint(x: num(), y: num()))
            case "L":
                path.line(to: NSPoint(x: num(), y: num()))
            case "C":
                let c1 = NSPoint(x: num(), y: num())
                let c2 = NSPoint(x: num(), y: num())
                let to = NSPoint(x: num(), y: num())
                path.curve(to: to, controlPoint1: c1, controlPoint2: c2)
            case "Z":
                path.close()
            default:
                break
            }
        }
        return path
    }
}
