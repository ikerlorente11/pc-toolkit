# HdrGames.ps1 - Vigilante de HDR por juego: cada 2 s mira si hay abierto algún juego de la lista;
# al abrirse uno quita el HDR y al cerrarse lo devuelve. Lo lanza oculto la tarea "PcToolkitHdrGames".
# Los cambios en la lista hechos desde el gestor se aplican solos.

. (Join-Path $PSScriptRoot 'common.ps1')

$mutex = New-Object System.Threading.Mutex($false, 'PcToolkit.HdrGames')
try { if (-not $mutex.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] {}

$LogFile = Join-Path $script:HdrGamesData 'HdrGames.log'
function Write-Log($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $script:HdrGamesData | Out-Null
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 100KB) { Clear-Content $LogFile }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

function Get-Names($displays) { (@($displays) | ForEach-Object Name) -join ', ' }

Write-Log 'Vigilante iniciado'
# Si quedó algo pendiente (reinicio con un juego abierto...), se recupera en la primera vuelta
$active = Test-Path $script:HdrRestoreFile
while ($true) {
    try {
        $game = Get-RunningHdrGame (Get-HdrGamesConfig).Games
        if ($game -and -not $active) {
            $off = Disable-HdrForGame
            if ($off) { Write-Log "$($game.Name) abierto: HDR desactivado en $(Get-Names $off)" }
            else { Write-Log "$($game.Name) abierto: el HDR ya estaba desactivado" }
            $active = $true
        } elseif (-not $game -and $active) {
            $back = Restore-Hdr
            if ($back) { Write-Log "Juego cerrado: HDR activado en $(Get-Names $back)" }
            $active = $false
        }
    } catch { Write-Log "ERROR: $($_.Exception.Message)" }
    Start-Sleep -Seconds 2
}
