# GameMode.ps1 - Vigilante de Modo juegos (lo lanza oculto la tarea "PcToolkitGameMode" al iniciar sesión).
# El hipervisor no se puede encender ni apagar en caliente, así que solo ofrece reiniciar:
#   - Modo normal (hipervisor activo) y se abre un emulador de la lista -> ¿reiniciar en modo juegos?
#   - Modo juegos (sin hipervisor) y se abre Docker/WSL -> ¿reiniciar en modo normal?
# Pregunta una vez por apertura: hasta que se cierren todos los de la lista no vuelve a preguntar.

. (Join-Path $PSScriptRoot 'common.ps1')
Add-Type -AssemblyName System.Windows.Forms

$mutex = New-Object System.Threading.Mutex($false, 'PcToolkit.GameMode')
try { if (-not $mutex.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] {}

$LogFile = Join-Path $script:GameModeData 'GameMode.log'
function Write-Log($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $script:GameModeData | Out-Null
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 100KB) { Clear-Content $LogFile }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

# Pregunta Sí/No por encima de todo (también de un juego en pantalla completa sin bordes)
function Ask([string]$Text, [string]$Title) {
    $owner = New-Object Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; StartPosition = 'CenterScreen'; Size = '1,1'; Opacity = 0 }
    $owner.Show(); $owner.Activate()
    try {
        [Windows.Forms.MessageBox]::Show($owner, $Text, $Title, 'YesNo', 'Question', 'Button1') -eq 'Yes'
    } finally { $owner.Dispose() }
}

# El modo no cambia sin reiniciar: se mira una vez
$hypervisor = Test-HypervisorRunning
Write-Log ("Vigilante iniciado en modo {0}" -f $(if ($hypervisor) { 'normal (con hipervisor)' } else { 'juegos (sin hipervisor)' }))

# ¿Este arranque venía de un "reiniciar en modo juegos"? Si aun así hay hipervisor, avisar (y no volver a
# preguntar en esta sesión, porque reiniciar otra vez daría lo mismo)
$failedGamesBoot = $false
if (Test-Path $script:GameModePendingFile) {
    try {
        $requested = [datetime](Get-Content $script:GameModePendingFile -Raw -Encoding UTF8 | ConvertFrom-Json).Time
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        if ($boot -gt $requested -and ($boot - $requested).TotalMinutes -lt 15) {
            if ($hypervisor) {
                $failedGamesBoot = $true
                Write-Log 'AVISO: se reinició en modo juegos pero el hipervisor sigue activo'
                [void](Ask ("Se reinició en modo juegos, pero Windows ha vuelto a cargar el hipervisor (Hyper-V/VBS).`n`n" +
                            "Abre PC Toolkit > Modo juegos para ver el registro. ¿Entendido?") 'Modo juegos')
            } else { Write-Log 'Arranque en modo juegos correcto: sin hipervisor' }
        }
    } catch { Write-Log "ERROR al comprobar el arranque: $($_.Exception.Message)" }
    Remove-Item $script:GameModePendingFile -Force -ErrorAction SilentlyContinue
}

$asked = $false
while ($true) {
    try {
        $cfg = Get-GameModeConfig
        if ($hypervisor) { $ask = $cfg.AskOnEmulator;  $exes = $cfg.Emulators }
        else             { $ask = $cfg.AskOnContainer; $exes = $cfg.Containers }
        $running = if ($exes) { Get-RunningExe $exes }
        if (-not $running) { $asked = $false }
        elseif ($ask -and -not $asked -and -not ($hypervisor -and $failedGamesBoot) -and (Test-GameModeReady)) {
            $asked = $true
            if ($hypervisor) {
                Write-Log "$running abierto con el hipervisor activo: se pregunta"
                $yes = Ask ("Has abierto $running y Windows está con el hipervisor activo (Hyper-V/VBS), " +
                            "que hace que los emuladores vayan mucho más lentos.`n`n" +
                            "¿Activar el modo juegos y reiniciar ahora (sin hipervisor)?`n`n" +
                            "Guarda lo que tengas abierto. Se mantendrá en modo juegos (WSL y Docker no funcionarán) " +
                            "hasta que vuelvas al normal desde PC Toolkit o al abrir Docker/WSL.") 'Modo juegos'
                if ($yes) { Write-Log 'Aceptado: activar modo juegos'; Request-GameModeRestart 'games' }
                else { Write-Log 'Rechazado' }
            } else {
                Write-Log "$running abierto en modo juegos: se pregunta"
                $yes = Ask ("Has abierto $running, pero estás en modo juegos (sin hipervisor) y WSL/Docker no pueden funcionar.`n`n" +
                            "¿Desactivar el modo juegos y reiniciar ahora (con hipervisor)?`n`nGuarda lo que tengas abierto.") 'Modo juegos'
                if ($yes) { Write-Log 'Aceptado: desactivar modo juegos'; Request-GameModeRestart 'normal' }
                else { Write-Log 'Rechazado' }
            }
        }
    } catch { Write-Log "ERROR: $($_.Exception.Message)" }
    Start-Sleep -Seconds 2
}
