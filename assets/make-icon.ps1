# make-icon.ps1 - Genera assets\pc-toolkit.ico (varios tamanos) dibujando el icono con System.Drawing.
# Solo hace falta volver a ejecutarlo si se cambia el diseno:
#   powershell -ExecutionPolicy Bypass -File .\assets\make-icon.ps1

Add-Type -AssemblyName System.Drawing

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $p
}

# Cuadrado azul redondeado con dos interruptores: uno encendido y otro apagado
function New-IconBitmap([int]$s) {
    $bmp = New-Object Drawing.Bitmap($s, $s, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode   = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'

    $bg = New-RoundRect 0 0 $s $s ($s * 0.22)
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF(0, 0)), (New-Object Drawing.PointF($s, $s)),
        [Drawing.ColorTranslator]::FromHtml('#2b8ae0'), [Drawing.ColorTranslator]::FromHtml('#0050a8'))
    $g.FillPath($brush, $bg)

    $tw = $s * 0.66; $th = $s * 0.24; $tx = ($s - $tw) / 2
    $white = New-Object Drawing.SolidBrush([Drawing.Color]::White)
    $dim   = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(110, 255, 255, 255))
    $blue  = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#0a5cb8'))
    $k = $th * 0.66; $pad = ($th - $k) / 2

    # Arriba: encendido (pista blanca, bola azul a la derecha)
    $y1 = $s * 0.20
    $g.FillPath($white, (New-RoundRect $tx $y1 $tw $th ($th / 2)))
    $g.FillEllipse($blue, $tx + $tw - $pad - $k, $y1 + $pad, $k, $k)

    # Abajo: apagado (pista translucida, bola blanca a la izquierda)
    $y2 = $s * 0.56
    $g.FillPath($dim, (New-RoundRect $tx $y2 $tw $th ($th / 2)))
    $g.FillEllipse($white, $tx + $pad, $y2 + $pad, $k, $k)

    $g.Dispose()
    $bmp
}

# Imagen DIB de 32 bits (formato clasico de .ico; la transparencia va en el canal alfa)
function ConvertTo-Dib($bmp) {
    $s = $bmp.Width
    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($ms)
    $w.Write([int]40); $w.Write([int]$s); $w.Write([int]($s * 2)); $w.Write([int16]1); $w.Write([int16]32)
    1..6 | ForEach-Object { $w.Write([int]0) }
    for ($y = $s - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $s; $x++) {
            $c = $bmp.GetPixel($x, $y)
            $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A)
        }
    }
    $w.Write((New-Object byte[] ([math]::Ceiling($s / 32) * 4 * $s)))   # mascara AND vacia
    $w.Flush()
    , $ms.ToArray()
}

$sizes  = 16, 20, 24, 32, 40, 48, 64, 256
$images = foreach ($s in $sizes) {
    $bmp = New-IconBitmap $s
    if ($s -eq 256) { $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() }
    else { ConvertTo-Dib $bmp }
}

$out = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter($out)
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$images[$i].Length); $w.Write([int]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $w.Write([byte[]]$img) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'pc-toolkit.ico'), $out.ToArray())

# Vista previa en grande para el README
(New-IconBitmap 256).Save((Join-Path $PSScriptRoot 'pc-toolkit.png'), [Drawing.Imaging.ImageFormat]::Png)
