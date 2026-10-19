# KeyboardSound.ps1 - Vigilante de Keyboard Sound: reproduce el sonido elegido en cada pulsación.
# Lo lanza oculto la tarea programada "PcToolkitKeyboardSound". Los cambios de sonido o volumen
# hechos desde el gestor se aplican solos en un par de segundos.

Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot 'common.ps1')

$mutex = New-Object System.Threading.Mutex($false, 'PcToolkit.KeyboardSound')
try { if (-not $mutex.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] {}

$LogFile = Join-Path $script:KeyboardSoundData 'KeyboardSound.log'
function Write-Log($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $script:KeyboardSoundData | Out-Null
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 100KB) { Clear-Content $LogFile }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

$script:applied = $null
function Update-Player {
    $cfg = Get-KeyboardSoundConfig
    $key = "$($cfg.Sound)|$($cfg.Volume)"
    if ($key -eq $script:applied) { return }
    $old = [PcToolkit.KeyboardSound.KeyboardHook]::Player
    $player = New-Object PcToolkit.KeyboardSound.Player((Get-KeyboardSoundFile $cfg.Sound), 4)
    $player.SetVolume($cfg.Volume)
    [PcToolkit.KeyboardSound.KeyboardHook]::Player = $player
    if ($old) { $old.Dispose() }
    $script:applied = $key
    if ($player.Ready) { Write-Log "Sonido: $($script:KeyboardSounds[$cfg.Sound]), volumen $($cfg.Volume) %" }
    else { Write-Log "ERROR: no se pudo abrir el sonido $($cfg.Sound)" }
}

Update-Player
if (-not [PcToolkit.KeyboardSound.KeyboardHook]::Start()) { Write-Log 'ERROR: no se pudo escuchar el teclado'; exit 1 }
Write-Log 'Vigilante iniciado'

# Revisar la configuración cada 2 s (el gancho necesita este bucle de mensajes en el mismo hilo)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ try { Update-Player } catch { Write-Log "ERROR: $($_.Exception.Message)" } })
$timer.Start()
[System.Windows.Forms.Application]::Run()
