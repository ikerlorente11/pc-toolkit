# GameWindows.ps1 - Vigilante de Ventanas de juegos: cada segundo busca las ventanas de los juegos de
# la lista y, si no están sin bordes ocupando su pantalla, las coloca. Si el juego vuelve a poner el
# borde (al cambiar de resolución...), se corrige en la siguiente vuelta. Lo lanza oculto la tarea
# "PcToolkitGameWindows". Los cambios hechos desde el gestor se aplican solos.

. (Join-Path $PSScriptRoot 'common.ps1')
[PcToolkit.GameWindows.Native]::Init()

$mutex = New-Object System.Threading.Mutex($false, 'PcToolkit.GameWindows')
try { if (-not $mutex.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] {}

$LogFile = Join-Path $script:GameWindowsData 'GameWindows.log'
function Write-Log($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $script:GameWindowsData | Out-Null
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 100KB) { Clear-Content $LogFile }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

Write-Log 'Vigilante iniciado'
$logged = @{}   # ventana -> ya se apuntó en el registro (para no repetirlo en cada corrección)
while ($true) {
    try {
        foreach ($g in (Get-GameWindowsConfig).Games) {
            $procs = [Diagnostics.Process]::GetProcessesByName([IO.Path]::GetFileNameWithoutExtension($g.Exe))
            foreach ($p in $procs) {
                foreach ($hwnd in [PcToolkit.GameWindows.Native]::GetWindows($p.Id)) {
                    $b = (Get-GameScreen $g.Screen).Bounds
                    if ([PcToolkit.GameWindows.Native]::IsPlaced($hwnd, $b.X, $b.Y, $b.Width, $b.Height)) { continue }
                    [void][PcToolkit.GameWindows.Native]::Place($hwnd, $b.X, $b.Y, $b.Width, $b.Height)
                    if (-not $logged.ContainsKey([string]$hwnd)) {
                        Write-Log "$($g.Name): ventana sin bordes en $(Get-ScreenLabel (Get-GameScreen $g.Screen))"
                        $logged[[string]$hwnd] = $true
                    }
                }
                $p.Dispose()
            }
        }
    } catch { Write-Log "ERROR: $($_.Exception.Message)" }
    Start-Sleep -Seconds 1
}
