# Games.ps1 - Vigilante de Juegos. Cada segundo, para los juegos de la lista que estén abiertos:
#   - HDR: se quita en la pantalla del juego mientras está abierto, y luego se devuelve.
#   - Ventana sin bordes: si su ventana no está sin bordes ocupando su pantalla, se coloca (también si
#     el juego vuelve a poner el borde al cambiar de resolución...).
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

$logged = @{}   # ventana -> ya se apuntó en el registro (para no repetirlo en cada corrección)
function Update-Windows($games) {
    foreach ($g in ($games | Where-Object Borderless)) {
        $procs = [Diagnostics.Process]::GetProcessesByName([IO.Path]::GetFileNameWithoutExtension($g.Exe))
        foreach ($p in $procs) {
            foreach ($hwnd in [PcToolkit.GameWindows.Native]::GetWindows($p.Id)) {
                $screen = Get-GameScreen $g.Screen
                $b = $screen.Bounds
                if ([PcToolkit.GameWindows.Native]::IsPlaced($hwnd, $b.X, $b.Y, $b.Width, $b.Height)) { continue }
                [void][PcToolkit.GameWindows.Native]::Place($hwnd, $b.X, $b.Y, $b.Width, $b.Height)
                if (-not $logged.ContainsKey([string]$hwnd)) {
                    Write-Log "$($g.Name): ventana sin bordes en $(Get-ScreenLabel $screen)"
                    $logged[[string]$hwnd] = $true
                }
            }
            $p.Dispose()
        }
    }
}

Write-Log 'Vigilante iniciado'
while ($true) {
    try {
        $games = (Get-GamesConfig).Games
        Update-Hdr $games
        Update-Windows $games
    } catch { Write-Log "ERROR: $($_.Exception.Message)" }
    Start-Sleep -Seconds 1
}
