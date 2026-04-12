# =============================================================================
# build-assets.ps1 — Generate Inno Setup wizard images from falcon-logo.png.
#
# Inno Setup wants:
#   - WizardImageFile        : 164x314 24-bit BMP (large welcome side panel,
#                              shown on the welcome and finish pages)
#   - WizardSmallImageFile   : 55x58 24-bit BMP (small header bitmap shown
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

    # ── Header bitmap: 55 x 58 (Inno Setup default for WizardSmallImageFile) ──
    # WizardSizePercent=120 in installer.iss auto-scales this to 66x70.
    $headerPath = Join-Path $assetsDir 'header.bmp'
    Write-Host "Generating $headerPath (55x58)"
    $headerBmp = New-Object System.Drawing.Bitmap 55, 58
    try {
        $g = [System.Drawing.Graphics]::FromImage($headerBmp)
        try {
            # White background — blends with the Inno Setup header chrome.
            $g.Clear([System.Drawing.Color]::White)
            $g.InterpolationMode    = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode        = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.PixelOffsetMode      = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality   = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

            # Source is square; fit it as 47x47 centered with 4px padding
            $padding = 4
            $size    = 47
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

    # ── Welcome bitmap: 164 x 314 (Inno Setup default for WizardImageFile) ──
    # WizardSizePercent=120 in installer.iss auto-scales this to ~197x377.
    $welcomePath = Join-Path $assetsDir 'welcome.bmp'
    Write-Host "Generating $welcomePath (164x314)"
    $welcomeBmp = New-Object System.Drawing.Bitmap 164, 314
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

            # Logo centered horizontally, ~50px from the top
            $logoSize = 120
            $logoX = ($welcomeBmp.Width - $logoSize) / 2
            $logoY = 50
            $g.DrawImage($png, $logoX, $logoY, $logoSize, $logoSize)

            # "FalconPulsar" wordmark below the logo
            $titleFont  = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
            $titleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
            $titleRect  = New-Object System.Drawing.RectangleF 0, 185, 164, 24
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
    # ── Icon: multi-size .ico for SetupIconFile ────────────────────────────
    # Inno Setup uses this as the installer .exe icon and the Add/Remove
    # Programs entry icon. We generate a single 256x256 PNG-compressed
    # icon entry. Windows Explorer scales it to 16/32/48 as needed.
    $icoPath = Join-Path $assetsDir 'falcon.ico'
    Write-Host "Generating $icoPath (256x256 PNG-compressed icon)"
    $icoSize = 256
    $icoBmp = New-Object System.Drawing.Bitmap $icoSize, $icoSize, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($icoBmp)
        try {
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.InterpolationMode    = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode        = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.PixelOffsetMode      = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality   = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.DrawImage($png, 0, 0, $icoSize, $icoSize)
        } finally {
            $g.Dispose()
        }
        # Write the .ico binary format manually because GetHicon() always
        # returns a 32x32 handle. We embed a single 256x256 PNG entry
        # that Windows scales to all needed sizes (16, 32, 48, 256).
        $ms = New-Object System.IO.MemoryStream
        $icoBmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBytes = $ms.ToArray()
        $ms.Dispose()

        $fs = [System.IO.File]::Create($icoPath)
        $bw = New-Object System.IO.BinaryWriter($fs)
        # ICO header (6 bytes)
        $bw.Write([int16]0)                    # reserved
        $bw.Write([int16]1)                    # type: icon
        $bw.Write([int16]1)                    # image count
        # Directory entry (16 bytes)
        $bw.Write([byte]0)                     # width: 0 means 256
        $bw.Write([byte]0)                     # height: 0 means 256
        $bw.Write([byte]0)                     # color palette
        $bw.Write([byte]0)                     # reserved
        $bw.Write([int16]1)                    # color planes
        $bw.Write([int16]32)                   # bits per pixel
        $bw.Write([int32]$pngBytes.Length)      # PNG data size
        $bw.Write([int32]22)                   # data offset (6 + 16)
        # PNG image data
        $bw.Write($pngBytes)
        $bw.Close()
        $fs.Close()
    } finally {
        $icoBmp.Dispose()
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
Get-ChildItem -Path $assetsDir -Filter '*.ico' | ForEach-Object {
    $sizeKB = [math]::Round($_.Length / 1KB, 1)
    Write-Host "  $($_.Name) ($sizeKB KB)"
}

# Explicit exit 0 — calling code uses $LASTEXITCODE, which is only set by
# native exes, not by .ps1 dot-source / & invocations. Without this, the
# CI step's `if ($LASTEXITCODE -ne 0)` check sees stale state.
exit 0
