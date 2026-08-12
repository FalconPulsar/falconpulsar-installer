#!/usr/bin/env swift

// Renders shared/icons/icons.def to a contact-sheet PNG so the shapes can be
// LOOKED AT before they ship.
//
// This exists because of a specific mistake. Stop's icon was swapped from a
// hand-drawn square to the Segoe MDL2 glyph E71A on the assumption that MDL2
// has a filled square. Nobody on a Mac can render Segoe MDL2, so the change
// was unverifiable, and a glyph that resolves to a blank box would have cost
// Stop its icon entirely. It was reverted unshipped.
//
// Owning the geometry only helps if the geometry is checked. This uses the
// SAME NSBezierPath path-building the macOS menu bar uses at runtime, so a
// clean contact sheet also proves the parser handles every path in the file.
//
//   swift scripts/preview-icons.swift [out.png]

import AppKit
import Foundation

// MARK: - Parse icons.def  (must stay in lockstep with the two generated renderers)

struct SubPath { let mode: String; let data: String }

func loadIcons(_ path: String) -> [(String, [SubPath])] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    var order: [String] = []
    var byName: [String: [SubPath]] = [:]
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: "|", maxSplits: 2).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 3 else {
            FileHandle.standardError.write("malformed line: \(line)\n".data(using: .utf8)!)
            exit(1)
        }
        let (name, mode, data) = (parts[0], parts[1], parts[2])
        if byName[name] == nil { order.append(name); byName[name] = [] }
        byName[name]!.append(SubPath(mode: mode, data: data))
    }
    return order.map { ($0, byName[$0]!) }
}

// MARK: - Path builder: M / L / C / Z, absolute only

func buildPath(_ data: String) -> NSBezierPath {
    let p = NSBezierPath()
    let tokens = data.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    var i = 0
    func num() -> CGFloat {
        defer { i += 1 }
        guard i < tokens.count, let v = Double(tokens[i]) else {
            FileHandle.standardError.write("bad number near token \(i) in: \(data)\n".data(using: .utf8)!)
            exit(1)
        }
        return CGFloat(v)
    }
    while i < tokens.count {
        let cmd = tokens[i]; i += 1
        switch cmd {
        case "M": p.move(to: NSPoint(x: num(), y: num()))
        case "L": p.line(to: NSPoint(x: num(), y: num()))
        case "C":
            let c1 = NSPoint(x: num(), y: num())
            let c2 = NSPoint(x: num(), y: num())
            let to = NSPoint(x: num(), y: num())
            p.curve(to: to, controlPoint1: c1, controlPoint2: c2)
        case "Z": p.close()
        default:
            FileHandle.standardError.write("unknown command '\(cmd)' in: \(data)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    return p
}

/// Draw one icon into the current context at `size`, in `color`.
/// `knockout` is the colour a K subpath paints in — the menu background.
func drawIcon(_ subpaths: [SubPath], size: CGFloat, color: NSColor, knockout: NSColor) {
    let s = size / 24.0
    let xf = NSAffineTransform()
    xf.scale(by: s)
    for sp in subpaths {
        let path = buildPath(sp.data)
        path.transform(using: xf as AffineTransform)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if sp.mode == "F" {
            color.setFill(); path.fill()
        } else if sp.mode == "K" {
            knockout.setFill(); path.fill()
        } else if sp.mode.hasPrefix("S") {
            let w = CGFloat(Double(sp.mode.dropFirst()) ?? 2.0)
            color.setStroke(); path.lineWidth = w * s; path.stroke()
        } else {
            FileHandle.standardError.write("unknown mode '\(sp.mode)'\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

// MARK: - Contact sheet

let root = FileManager.default.currentDirectoryPath
let defPath = "\(root)/shared/icons/icons.def"
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "\(root)/icons-preview.png"

let icons = loadIcons(defPath)

// Every size the icons are actually used at, plus a large one to inspect the
// curves. 16 is the Windows menu gutter; 14 is the macOS inline size; 32 is
// the 2x retina raster of 16.
let sizes: [CGFloat] = [14, 16, 32, 64]
let cellW: CGFloat = 88, cellH: CGFloat = 96, labelH: CGFloat = 16
let cols = icons.count
let sheetW = cellW * CGFloat(cols), sheetH = cellH * CGFloat(sizes.count) + labelH

let img = NSImage(size: NSSize(width: sheetW, height: sheetH))
img.lockFocus()

// Menu-ish background so the knockout arrow is meaningful.
let bg = NSColor.white
bg.setFill()
NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()

// Flip: icons.def is authored y-down (GDI+ / SVG convention).
let flip = NSAffineTransform()
flip.translateX(by: 0, yBy: sheetH)
flip.scaleX(by: 1, yBy: -1)
flip.concat()

let ink = NSColor(calibratedWhite: 0.27, alpha: 1.0)   // the menu's 70,70,70

for (ci, (name, subpaths)) in icons.enumerated() {
    for (ri, size) in sizes.enumerated() {
        let cx = CGFloat(ci) * cellW + (cellW - size) / 2
        let cy = CGFloat(ri) * cellH + (cellH - size) / 2 + labelH

        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: cx, yBy: cy)
        t.concat()
        drawIcon(subpaths, size: size, color: ink, knockout: bg)
        NSGraphicsContext.restoreGraphicsState()
    }

    // Name, drawn upright (undo the flip locally).
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: CGFloat(ci) * cellW, yBy: 12)
    t.scaleX(by: 1, yBy: -1)
    t.concat()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10),
        .foregroundColor: NSColor.black,
    ]
    NSString(string: name).draw(at: NSPoint(x: 6, y: 0), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)  —  \(icons.count) icons at \(sizes.map { Int($0) })")
for (name, sp) in icons { print("  \(name): \(sp.count) subpath(s)") }
