// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

// =============================================================================
// IconRenderer.cs -- draws the shared icon set (Icons.g.cs) with GDI+.
//
// The Windows half of a deliberate pair. IconRenderer.swift is the macOS half
// and does the same four things in the same order; keep them in step. Between
// them they are the ONLY code that interprets a path from icons.def, which is
// why the grammar is four absolute commands and nothing else -- every feature
// added here has to be added correctly twice.
//
// WHY THIS REPLACED A FONT
//
// The menu used Segoe MDL2 Assets while macOS used SF Symbols. Two platform
// fonts, so the menus could never match: `brain`, `square.grid.2x2` and
// `safari` have no MDL2 equivalent, and SF Symbols cannot ship on Windows.
// Worse, no one on a Mac can render MDL2, so icon changes here were
// unverifiable -- a glyph swap that resolved to a blank box would have shipped
// looking fine in review. Owning the geometry makes the two platforms
// identical by construction and lets scripts/preview-icons.swift rasterize the
// exact shapes before they ship.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;

namespace FalconPulsar.Tray
{
    internal static class IconRenderer
    {
        /// <summary>
        /// Render a named icon from Icons.g.cs into a square bitmap.
        /// </summary>
        /// <param name="name">key in Icons.All</param>
        /// <param name="color">ink</param>
        /// <param name="size">pixel size; menu gutter icons are 16</param>
        /// <param name="knockout">
        /// colour a K subpath paints in -- the menu background, so an arrow
        /// inside a filled disc reads as a hole. SystemColors.Menu by default.
        /// </param>
        internal static Image Render(string name, Color color, int size = 16, Color? knockout = null)
        {
            var ko = knockout ?? SystemColors.Menu;
            var bmp = new Bitmap(size, size);

            if (!Icons.All.TryGetValue(name, out var subpaths))
            {
                // An unknown name is a build-time mistake, not a runtime one --
                // the caller passes a literal. Return the empty bitmap rather
                // than throwing: a missing icon is survivable, a tray that
                // won't start is not.
                return bmp;
            }

            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                // The paths are authored on a 24x24 grid with y increasing
                // downward, which is already GDI+'s orientation -- no flip
                // here, unlike the macOS side which has to invert AppKit's.
                var scale = size / 24f;

                foreach (var (mode, data) in subpaths)
                {
                    using var path = BuildPath(data);
                    using var xf = new Matrix();
                    xf.Scale(scale, scale);
                    path.Transform(xf);

                    if (mode == "F")
                    {
                        using var brush = new SolidBrush(color);
                        g.FillPath(brush, path);
                    }
                    else if (mode == "K")
                    {
                        using var brush = new SolidBrush(ko);
                        g.FillPath(brush, path);
                    }
                    else if (mode.Length > 1 && mode[0] == 'S')
                    {
                        var w = float.Parse(mode.Substring(1), CultureInfo.InvariantCulture);
                        using var pen = new Pen(color, w * scale)
                        {
                            StartCap = LineCap.Round,
                            EndCap = LineCap.Round,
                            LineJoin = LineJoin.Round,
                        };
                        g.DrawPath(pen, path);
                    }
                }
            }
            return bmp;
        }

        /// <summary>
        /// Absolute M / L / C / Z only. Mirrors buildPath() in
        /// IconRenderer.swift -- if you change one, change the other.
        /// sync-icons.sh rejects anything outside this grammar before it can
        /// reach either parser.
        /// </summary>
        private static GraphicsPath BuildPath(string data)
        {
            var path = new GraphicsPath(FillMode.Winding);
            var tokens = data.Split(new[] { ' ', ',' }, StringSplitOptions.RemoveEmptyEntries);

            var i = 0;
            float Num()
            {
                // The generator validated every token, so a failure here means
                // Icons.g.cs was hand-edited despite the header saying not to.
                var v = float.Parse(tokens[i], CultureInfo.InvariantCulture);
                i++;
                return v;
            }

            var cur = PointF.Empty;      // current point
            var start = PointF.Empty;    // subpath start, for Z

            while (i < tokens.Length)
            {
                var cmd = tokens[i]; i++;
                switch (cmd)
                {
                    case "M":
                        cur = new PointF(Num(), Num());
                        start = cur;
                        // GraphicsPath has no explicit moveto: starting a new
                        // figure is how you break the line from the previous
                        // one. Without this every M would draw a connecting
                        // segment from wherever the last subpath ended.
                        path.StartFigure();
                        break;

                    case "L":
                    {
                        var to = new PointF(Num(), Num());
                        path.AddLine(cur, to);
                        cur = to;
                        break;
                    }

                    case "C":
                    {
                        var c1 = new PointF(Num(), Num());
                        var c2 = new PointF(Num(), Num());
                        var to = new PointF(Num(), Num());
                        path.AddBezier(cur, c1, c2, to);
                        cur = to;
                        break;
                    }

                    case "Z":
                        path.CloseFigure();
                        cur = start;
                        break;
                }
            }
            return path;
        }
    }
}
