# =============================================================================
# build-assets.ps1 — Generate Inno Setup wizard images from falcon-logo.png.
#
# Inno Setup wants:
#   - WizardImageFile        : 192x386 24-bit BMP (large welcome side panel,
#                              shown on the welcome and finish pages)
#   - WizardSmallImageFile   : 119x123 24-bit BMP (small header bitmap shown
#                              on every other wizard page)
#
# We don't commit the BMPs to the repo (they're 100+ KB each and would
# churn on every logo update). Instead this script generates them from
# windows/assets/falcon-logo.png on demand. Both CI (build-windows.yml)
# and local devs run it before invoking ISCC.exe.
#
# Uses System.Drawing — no ImageMagick or other external deps. Runs on any
# machine with .NET Framework / .NET Desktop Runtime, which includes the
# windows-latest GitHub Actions runner.
#
# Output:
#   windows/assets/header.bmp
#   windows/assets/welcome.bmp
# =============================================================================

[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..'))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing

$assetsDir = Join-Path $RepoRoot 'windows\assets'
$srcPng    = Join-Path $assetsDir 'falcon-logo.png'

if (-not (Test-Path $srcPng)) {
    Write-Error "Source PNG not found: $srcPng"
    exit 1
}

Write-Host "Loading source: $srcPng"
$png = [System.Drawing.Image]::FromFile($srcPng)
try {
    Write-Host "  Source size: $($png.Width) x $($png.Height)"

    # ── Header bitmap: 119 x 123 (small image shown on every page header) ──
    $headerPath = Join-Path $assetsDir 'header.bmp'
    Write-Host "Generating $headerPath (119x123)"
    $headerBmp = New-Object System.Drawing.Bitmap 119, 123
    try {
        $g = [System.Drawing.Graphics]::FromImage($headerBmp)
        try {
            # White background — matches the wizard chrome on every page
            $g.Clear([System.Drawing.Color]::White)
            $g.InterpolationMode    = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode        = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.PixelOffsetMode      = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality   = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

            # Source is square; fit it as a 105x105 with 7px padding all around
            $padding = 7
            $size    = 105
            $x       = ($headerBmp.Width  - $size) / 2
            $y       = ($headerBmp.Height - $size) / 2
            $g.DrawImage($png, $x, $y, $size, $size)
        } finally {
            $g.Dispose()
        }
        $headerBmp.Save($headerPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
    } finally {
        $headerBmp.Dispose()
    }

    # ── Welcome bitmap: 192 x 386 (large side panel on welcome + finish) ──
    $welcomePath = Join-Path $assetsDir 'welcome.bmp'
    Write-Host "Generating $welcomePath (192x386)"
    $welcomeBmp = New-Object System.Drawing.Bitmap 192, 386
    try {
        $g = [System.Drawing.Graphics]::FromImage($welcomeBmp)
        try {
            # Dark navy background — matches the FalconPulsar logo's secondary blue
            $bg = [System.Drawing.Color]::FromArgb(255, 14, 26, 49)
            $g.Clear($bg)
            $g.InterpolationMode    = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode        = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.PixelOffsetMode      = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality   = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.TextRenderingHint    = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

            # Logo centered horizontally, ~70px from the top
            $logoSize = 150
            $logoX = ($welcomeBmp.Width - $logoSize) / 2
            $logoY = 70
            $g.DrawImage($png, $logoX, $logoY, $logoSize, $logoSize)

            # "FalconPulsar" wordmark below the logo
            $titleFont  = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
            $titleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
            $titleRect  = New-Object System.Drawing.RectangleF 0, 235, 192, 28
            $fmt        = New-Object System.Drawing.StringFormat
            $fmt.Alignment     = [System.Drawing.StringAlignment]::Center
            $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString('FalconPulsar', $titleFont, $titleBrush, $titleRect, $fmt)
            $titleFont.Dispose()
            $titleBrush.Dispose()

            # Tag line removed per user request — FalconPulsar is broader
            # than time-series. The wordmark alone is sufficient.
        } finally {
            $g.Dispose()
        }
        $welcomeBmp.Save($welcomePath, [System.Drawing.Imaging.ImageFormat]::Bmp)
    } finally {
        $welcomeBmp.Dispose()
    }
} finally {
    $png.Dispose()
}

Write-Host ''
Write-Host 'Generated assets:'
Get-ChildItem -Path $assetsDir -Filter '*.bmp' | ForEach-Object {
    $sizeKB = [math]::Round($_.Length / 1KB, 1)
    Write-Host "  $($_.Name) ($sizeKB KB)"
}

# Explicit exit 0 — calling code uses $LASTEXITCODE, which is only set by
# native exes, not by .ps1 dot-source / & invocations. Without this, the
# CI step's `if ($LASTEXITCODE -ne 0)` check sees stale state.
exit 0
