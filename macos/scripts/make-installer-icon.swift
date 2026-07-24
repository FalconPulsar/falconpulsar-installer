// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

// Composites the falcon logo with a blue "download arrow" badge to produce a
// 1024x1024 installer-icon PNG used as both the DMG volume icon and the
// Installer.app icon. Usage: swift make-installer-icon.swift <logo.png> <out.png>

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data(
        "usage: make-installer-icon.swift <logo.png> <out.png>\n".utf8))
    exit(2)
}
let logoPath = args[1]
let outPath = args[2]

guard let logo = NSImage(contentsOfFile: logoPath) else {
    FileHandle.standardError.write(Data("could not read logo at \(logoPath)\n".utf8))
    exit(1)
}

let size = CGSize(width: 1024, height: 1024)
guard let ctx = CGContext(
    data: nil,
    width: Int(size.width),
    height: Int(size.height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("could not create CG context\n".utf8))
    exit(1)
}

// Draw the logo centered, filling ~80% of the canvas.
let logoSide: CGFloat = 820
let logoRect = CGRect(
    x: (size.width - logoSide) / 2,
    y: (size.height - logoSide) / 2 + 40, // nudged up so badge has room
    width: logoSide, height: logoSide)
NSGraphicsContext.saveGraphicsState()
let gCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = gCtx
logo.draw(in: logoRect)
NSGraphicsContext.restoreGraphicsState()

// Draw a filled blue circle badge in the bottom-right.
let badgeSide: CGFloat = 330
let badgePadding: CGFloat = 40
let badgeRect = CGRect(
    x: size.width - badgeSide - badgePadding,
    y: badgePadding,
    width: badgeSide, height: badgeSide)

// Outer white ring (halo) so the badge separates from busy backgrounds.
let haloRect = badgeRect.insetBy(dx: -12, dy: -12)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
ctx.fillEllipse(in: haloRect)

// Blue fill circle.
ctx.setFillColor(CGColor(red: 0.10, green: 0.47, blue: 0.95, alpha: 1.0))
ctx.fillEllipse(in: badgeRect)

// Down-arrow glyph, centered in the badge.
// Shaft width = badgeSide * 0.18, head spread = badgeSide * 0.55.
let cx = badgeRect.midX
let cy = badgeRect.midY
let shaftW = badgeSide * 0.18
let shaftH = badgeSide * 0.32
let headW = badgeSide * 0.55
let headH = badgeSide * 0.30
let topY = cy + shaftH / 2 + headH / 4       // top of shaft (up is +y in CG)
let shaftBottomY = cy - shaftH / 2 + headH / 4
let tipY = shaftBottomY - headH

let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: cx - shaftW / 2, y: topY))
arrow.addLine(to: CGPoint(x: cx + shaftW / 2, y: topY))
arrow.addLine(to: CGPoint(x: cx + shaftW / 2, y: shaftBottomY))
arrow.addLine(to: CGPoint(x: cx + headW / 2, y: shaftBottomY))
arrow.addLine(to: CGPoint(x: cx, y: tipY))
arrow.addLine(to: CGPoint(x: cx - headW / 2, y: shaftBottomY))
arrow.addLine(to: CGPoint(x: cx - shaftW / 2, y: shaftBottomY))
arrow.closeSubpath()

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
ctx.addPath(arrow)
ctx.fillPath()

// Write PNG.
guard let cgImage = ctx.makeImage() else {
    FileHandle.standardError.write(Data("could not produce image\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode PNG\n".utf8))
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(Int(size.width))x\(Int(size.height)))")
