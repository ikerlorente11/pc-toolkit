# Games.ps1 - Vigilante de Juegos. Cada segundo, para los juegos de la lista que estén abiertos:
#   - HDR: al abrirse uno que lo apaga se quita el HDR, y al cerrarse se devuelve.
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

function Get-Names($displays) { (@($displays) | ForEach-Object Name) -join ', ' }

function Update-Hdr($games) {
    $game = Get-RunningGame $games -Hdr
    if ($game -and -not $script:hdrOff) {
        $off = Disable-HdrForGame
        if ($off) { Write-Log "$($game.Name) abierto: HDR desactivado en $(Get-Names $off)" }
        else { Write-Log "$($game.Name) abierto: el HDR ya estaba desactivado" }
        $script:hdrOff = $true
    } elseif (-not $game -and $script:hdrOff) {
        $back = Restore-Hdr
        if ($back) { Write-Log "Juego cerrado: HDR activado en $(Get-Names $back)" }
        $script:hdrOff = $false
    }
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
# Si quedó HDR por devolver (reinicio con un juego abierto...), se recupera en la primera vuelta
$script:hdrOff = Test-Path $script:HdrRestoreFile
while ($true) {
    try {
        $games = (Get-GamesConfig).Games
        Update-Hdr $games
        Update-Windows $games
    } catch { Write-Log "ERROR: $($_.Exception.Message)" }
    Start-Sleep -Seconds 1
}
