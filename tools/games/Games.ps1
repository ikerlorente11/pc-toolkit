# Games.ps1 - Vigilante de Juegos. Cada segundo, para los juegos de la lista que estén abiertos:
#   - HDR: se quita en la pantalla del juego mientras está abierto, y luego se devuelve.
#   - Ventana sin bordes: si su ventana no está sin bordes ocupando su pantalla, se coloca (también si
#     el juego vuelve a poner el borde al cambiar de resolución...).
#   - Barra flotante (GameBar.ps1) al dejar el ratón arriba del todo en la pantalla del juego.
# Lo lanza oculto la tarea "PcToolkitGames". Los cambios hechos desde el gestor se aplican solos.

. (Join-Path $PSScriptRoot 'common.ps1')
[PcToolkit.GameWindows.Native]::Init()

$mutex = New-Object System.Threading.Mutex($false, 'PcToolkit.Games')
try { if (-not $mutex.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] {}

$LogFile = Join-Path $script:GamesData 'Games.log'
function Write-Log($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $script:GamesData | Out-Null
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 100KB) { Clear-Content $LogFile }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

# HDR apagado solo en las pantallas donde hay un juego que lo pide; en cuanto el juego se cierra o
# cambia de pantalla, se devuelve. Si estaba apagado de antes, no se toca (ni se enciende luego).
function Update-Hdr($games) {
    $wanted = Get-HdrGameScreens $games
    $before = @(Get-HdrOffKeys)
    $off = $before
    $displays = Get-HdrDisplays
    foreach ($d in $displays) {
        $game = if ($d.GdiName) { $wanted[$d.GdiName] }
        if ($game -and $d.Enabled -and $off -notcontains $d.Key) {
            [void][PcToolkit.Hdr.Native]::Set($d, $false)
            $off += $d.Key
            Write-Log "$($game.Name) abierto: HDR desactivado en $($d.Name) ($(Get-ScreenLabel (Get-GameScreen $d.GdiName)))"
        } elseif (-not $game -and $off -contains $d.Key) {
            if (-not $d.Enabled) { [void][PcToolkit.Hdr.Native]::Set($d, $true) }
            $off = @($off | Where-Object { $_ -ne $d.Key })
            Write-Log "HDR activado de nuevo en $($d.Name) ($(Get-ScreenLabel (Get-GameScreen $d.GdiName)))"
        }
    }
    # Las pantallas desconectadas se olvidan
    $off = @($off | Where-Object { $displays.Key -contains $_ })
    if (($off -join ',') -ne ($before -join ',')) { Save-HdrOffKeys $off }
}

$logged   = @{}   # ventana -> ya se apuntó en el registro (para no repetirlo en cada corrección)
$placedOn = @{}   # ventana -> pantalla en la que se colocó la última vez
$script:GameScreens = @()   # juegos sin bordes abiertos ahora: @{ Game; Screen } (para la barra)
function Update-Windows($games) {
    $script:GameScreens = @()
    foreach ($g in ($games | Where-Object Borderless)) {
        $procs = [Diagnostics.Process]::GetProcessesByName([IO.Path]::GetFileNameWithoutExtension($g.Exe))
        foreach ($p in $procs) {
            foreach ($hwnd in [PcToolkit.GameWindows.Native]::GetWindows($p.Id)) {
                $key = [string]$hwnd
                $screen = Get-GameScreen $g.Screen
                # Si el usuario la ha sacado de donde se colocó (Win + Mayús + flecha), esa pasa a ser su pantalla
                $r = [PcToolkit.GameWindows.Native]::GetBorderlessRect($hwnd)
                if ($r -and $placedOn.ContainsKey($key)) {
                    $center = New-Object Drawing.Point ([int]($r[0] + $r[2] / 2)), ([int]($r[1] + $r[3] / 2))
                    $now = [Windows.Forms.Screen]::FromPoint($center)
                    if ($now.DeviceName -ne $placedOn[$key] -and $now.DeviceName -ne $screen.DeviceName) {
                        Set-GameScreen $g.Exe $now
                        $screen = $now
                        Write-Log "$($g.Name): movido a $(Get-ScreenLabel $screen)"
                    }
                }
                $x, $y, $w, $h = Get-GameRect $g $screen
                $placedOn[$key] = $screen.DeviceName
                $script:GameScreens += @{ Game = $g; Screen = $screen }
                if ([PcToolkit.GameWindows.Native]::IsPlaced($hwnd, $x, $y, $w, $h)) { continue }
                [void][PcToolkit.GameWindows.Native]::Place($hwnd, $x, $y, $w, $h)
                if (-not $logged.ContainsKey($key)) {
                    Write-Log "$($g.Name): ventana sin bordes en $(Get-ScreenLabel $screen)"
                    $logged[$key] = $true
                }
            }
            $p.Dispose()
        }
    }
}

function Update-All {
    try {
        $games = (Get-GamesConfig).Games
        Update-Hdr $games
        Update-Windows $games
    } catch { Write-Log "ERROR: $($_.Exception.Message)" }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$app = New-Object Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
. (Join-Path $PSScriptRoot 'GameBar.ps1')

Write-Log 'Vigilante iniciado'
# Bucle de mensajes de WPF (lo necesita la barra): repaso completo cada segundo y ratón cada 100 ms
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({ Update-All })
$timer.Start()
Update-All
[void]$app.Run()
