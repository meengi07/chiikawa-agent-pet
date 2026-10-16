param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

$Root = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Repository root does not exist: $Root"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $Root 'build/windows-artwork'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

$Cream = [System.Drawing.ColorTranslator]::FromHtml('#FFF9EF')
$Ink = [System.Drawing.ColorTranslator]::FromHtml('#53494A')
$Pink = [System.Drawing.ColorTranslator]::FromHtml('#F8DDE4')
$Blue = [System.Drawing.ColorTranslator]::FromHtml('#DCECF3')
$Butter = [System.Drawing.ColorTranslator]::FromHtml('#F7E9BD')

function Read-FirstFrame([string]$Name) {
    $path = Join-Path $Root "assets/$Name.png"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing sprite atlas: $path"
    }
    $atlas = $null
    try {
        $atlas = [System.Drawing.Bitmap]::FromFile($path)
        if ($Name -eq 'momonga') {
            if ($atlas.Width -ne 1536 -or $atlas.Height -ne 1024) {
                throw "Momonga atlas must be 1536 x 1024: $path"
            }
            $bounds = [System.Drawing.Rectangle]::new(0, 0, 384, 400)
        } else {
            if ($atlas.Width -lt 512 -or $atlas.Height -lt 480 -or
                $atlas.Width % 8 -ne 0 -or $atlas.Height % 6 -ne 0) {
                throw "Sprite atlas must contain an 8 x 6 frame grid: $path"
            }
            $bounds = [System.Drawing.Rectangle]::new(0, 0, ($atlas.Width / 8), ($atlas.Height / 6))
        }
        return $atlas.Clone($bounds, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    } catch {
        throw "Cannot read first sprite frame from ${path}: $($_.Exception.Message)"
    } finally {
        if ($null -ne $atlas) { $atlas.Dispose() }
    }
}

function New-ArtworkBitmap([int]$Width, [int]$Height, [switch]$Opaque) {
    $format = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    if ($Opaque) { $format = [System.Drawing.Imaging.PixelFormat]::Format24bppRgb }
    return [System.Drawing.Bitmap]::new($Width, $Height, $format)
}

function New-ArtworkGraphics([System.Drawing.Bitmap]$Bitmap) {
    $graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
    return $graphics
}

function Draw-RoundedPlate($Graphics, $Color, [single]$X, [single]$Y,
                           [single]$Width, [single]$Height, [single]$Radius,
                           [switch]$Outline) {
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $brush = $null
    $pen = $null
    try {
        $diameter = $Radius * 2
        $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
        $path.AddArc(($X + $Width - $diameter), $Y, $diameter, $diameter, 270, 90)
        $path.AddArc(($X + $Width - $diameter), ($Y + $Height - $diameter), $diameter, $diameter, 0, 90)
        $path.AddArc($X, ($Y + $Height - $diameter), $diameter, $diameter, 90, 90)
        $path.CloseFigure()
        $brush = [System.Drawing.SolidBrush]::new($Color)
        $Graphics.FillPath($brush, $path)
        if ($Outline) {
            $outlineColor = [System.Drawing.Color]::FromArgb(28, $Ink)
            $pen = [System.Drawing.Pen]::new($outlineColor, [single][Math]::Max(1, $Width / 128))
            $Graphics.DrawPath($pen, $path)
        }
    } finally {
        if ($null -ne $pen) { $pen.Dispose() }
        if ($null -ne $brush) { $brush.Dispose() }
        $path.Dispose()
    }
}

function Draw-Dot($Graphics, $Color, [single]$X, [single]$Y, [single]$Diameter) {
    $brush = [System.Drawing.SolidBrush]::new($Color)
    try { $Graphics.FillEllipse($brush, $X, $Y, $Diameter, $Diameter) }
    finally { $brush.Dispose() }
}

function Draw-Sprite($Graphics, [System.Drawing.Bitmap]$Sprite,
                     [single]$X, [single]$Y, [single]$Width, [single]$Height) {
    $scale = [Math]::Min($Width / $Sprite.Width, $Height / $Sprite.Height)
    $drawWidth = [int][Math]::Round($Sprite.Width * $scale)
    $drawHeight = [int][Math]::Round($Sprite.Height * $scale)
    $left = [int][Math]::Round($X + ($Width - $drawWidth) / 2)
    $top = [int][Math]::Round($Y + ($Height - $drawHeight) / 2)
    $destination = [System.Drawing.Rectangle]::new($left, $top, $drawWidth, $drawHeight)
    $state = $Graphics.Save()
    try {
        $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
        $Graphics.DrawImage($Sprite, $destination, 0, 0, $Sprite.Width, $Sprite.Height,
                            [System.Drawing.GraphicsUnit]::Pixel)
    } finally { $Graphics.Restore($state) }
}

function Write-InstallerSidebar($Sprites) {
    $bitmap = New-ArtworkBitmap 164 314 -Opaque
    $graphics = $null
    try {
        $graphics = New-ArtworkGraphics $bitmap
        $graphics.Clear($Cream)
        Draw-Dot $graphics $Pink -28 37 220
        Draw-Dot $graphics $Butter 130 21 12
        Draw-Dot $graphics $Blue 15 28 8
        Draw-Dot $graphics $Cream 143 189 15
        Draw-RoundedPlate $graphics $Cream 24 195 116 7 3.5
        Draw-Sprite $graphics $Sprites['chiikawa'] 6 24 152 190
        Draw-RoundedPlate $graphics $Blue 10 232 144 68 18 -Outline
        Draw-Sprite $graphics $Sprites['hachiware'] 13 234 44 61
        Draw-Sprite $graphics $Sprites['usagi'] 60 231 44 64
        Draw-Sprite $graphics $Sprites['momonga'] 107 239 44 53
        $path = Join-Path $OutputDirectory 'installer-sidebar.bmp'
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Bmp)
    } finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        $bitmap.Dispose()
    }
}

function Write-InstallerHeader($Sprites) {
    $bitmap = New-ArtworkBitmap 150 57 -Opaque
    $graphics = $null
    try {
        $graphics = New-ArtworkGraphics $bitmap
        $graphics.Clear($Cream)
        Draw-RoundedPlate $graphics $Pink 1 5 46 48 14
        Draw-RoundedPlate $graphics $Blue 50 13 99 39 13
        Draw-Sprite $graphics $Sprites['chiikawa'] 0 -4 48 60
        Draw-Sprite $graphics $Sprites['hachiware'] 49 7 33 45
        Draw-Sprite $graphics $Sprites['usagi'] 81 2 34 51
        Draw-Sprite $graphics $Sprites['momonga'] 116 11 33 40
        $path = Join-Path $OutputDirectory 'installer-header.bmp'
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Bmp)
    } finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        $bitmap.Dispose()
    }
}

function Write-AppIcon([System.Drawing.Bitmap]$Chiikawa) {
    $sizes = @(16, 32, 48, 64, 128, 256)
    $faceBounds = [System.Drawing.Rectangle]::new(
        ($Chiikawa.Width / 8), ($Chiikawa.Height / 5),
        ($Chiikawa.Width * 3 / 4), ($Chiikawa.Height / 2))
    $face = $Chiikawa.Clone($faceBounds, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $writer = $null
    $stream = $null
    try {
        $path = Join-Path $OutputDirectory 'AppIcon.ico'
        $stream = [System.IO.File]::Create($path)
        $writer = [System.IO.BinaryWriter]::new($stream)
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        foreach ($size in $sizes) {
            $dimension = $size
            if ($size -eq 256) { $dimension = 0 }
            $maskStride = [int]([Math]::Ceiling($size / 32.0) * 4)
            $payloadLength = 40 + $size * $size * 4 + $maskStride * $size
            $writer.Write([byte]$dimension)
            $writer.Write([byte]$dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$payloadLength)
            $writer.Write([uint32]$offset)
            $offset += $payloadLength
        }
        foreach ($size in $sizes) {
            $bitmap = New-ArtworkBitmap $size $size
            $graphics = $null
            $locked = $null
            try {
                $graphics = New-ArtworkGraphics $bitmap
                $graphics.Clear([System.Drawing.Color]::Transparent)
                Draw-RoundedPlate $graphics $Cream ($size * 0.08) ($size * 0.08) `
                    ($size * 0.84) ($size * 0.84) ($size * 0.185) -Outline
                if ($size -le 32) {
                    Draw-Sprite $graphics $face ($size * 0.148) ($size * 0.207) `
                        ($size * 0.703) ($size * 0.586)
                } else {
                    Draw-Sprite $graphics $Chiikawa ($size * 0.125) ($size * -0.047) `
                        ($size * 0.75) ($size * 0.938)
                }
                $graphics.Dispose()
                $graphics = $null

                # Uncompressed icon DIBs support both NSIS and the executable resource compiler.
                $maskStride = [int]([Math]::Ceiling($size / 32.0) * 4)
                $writer.Write([uint32]40)
                $writer.Write([int32]$size)
                $writer.Write([int32]($size * 2))
                $writer.Write([uint16]1)
                $writer.Write([uint16]32)
                $writer.Write([uint32]0)
                $writer.Write([uint32]($size * $size * 4 + $maskStride * $size))
                $writer.Write([int32]0)
                $writer.Write([int32]0)
                $writer.Write([uint32]0)
                $writer.Write([uint32]0)
                $bounds = [System.Drawing.Rectangle]::new(0, 0, $size, $size)
                $locked = $bitmap.LockBits($bounds, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                                           [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $row = [byte[]]::new($size * 4)
                $mask = [byte[]]::new($maskStride * $size)
                for ($y = $size - 1; $y -ge 0; $y--) {
                    $rowAddress = [System.IntPtr]::Add($locked.Scan0, ($y * $locked.Stride))
                    [System.Runtime.InteropServices.Marshal]::Copy($rowAddress, $row, 0, $row.Length)
                    $writer.Write($row)
                    for ($x = 0; $x -lt $size; $x++) {
                        if ($row[$x * 4 + 3] -eq 0) {
                            $maskIndex = ($size - 1 - $y) * $maskStride + [int][Math]::Floor($x / 8.0)
                            $mask[$maskIndex] = $mask[$maskIndex] -bor (128 -shr ($x % 8))
                        }
                    }
                }
                $writer.Write($mask)
            } finally {
                if ($null -ne $locked) { $bitmap.UnlockBits($locked) }
                if ($null -ne $graphics) { $graphics.Dispose() }
                $bitmap.Dispose()
            }
        }
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $face.Dispose()
    }
}

$Sprites = @{}
try {
    foreach ($name in @('chiikawa', 'hachiware', 'usagi', 'momonga')) {
        $Sprites[$name] = Read-FirstFrame $name
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Write-InstallerSidebar $Sprites
    Write-InstallerHeader $Sprites
    Write-AppIcon $Sprites['chiikawa']
} finally {
    foreach ($sprite in $Sprites.Values) { $sprite.Dispose() }
}
Write-Host "Windows artwork: $OutputDirectory (AppIcon.ico, installer-sidebar.bmp, installer-header.bmp)"
