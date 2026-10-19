# AudioAutoSwitch.ps1 - Cambia los dispositivos de audio por defecto al encender/apagar unos auriculares Bluetooth.
# Lo lanza oculto la tarea programada "AudioAutoSwitch" al iniciar sesion y se queda vigilando.
# Lee la configuracion de %LOCALAPPDATA%\PcToolkit\data\audio-autoswitch\config.json (la crea configure.ps1).

Import-Module AudioDeviceCmdlets

$DataDir    = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\audio-autoswitch'
$ConfigPath = Join-Path $DataDir 'config.json'
if (-not (Test-Path $ConfigPath)) { exit }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# Evitar instancias duplicadas
$mutex = New-Object System.Threading.Mutex($false, "AudioAutoSwitch_$($cfg.RenderGuid)")
try { if (-not $mutex.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] {}

$StateKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\$($cfg.RenderGuid)"
$LogFile  = Join-Path $DataDir 'AudioAutoSwitch.log'

function Write-Log($msg) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 100KB) { Clear-Content $LogFile }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
    } catch {}
}

function Get-HeadphonesConnected {
    try { ((Get-ItemProperty -Path $StateKey -Name DeviceState -ErrorAction Stop).DeviceState) -eq 1 }
    catch { $false }
}

function Set-Defaults($renderId, $captureId, $label) {
    try {
        Set-AudioDevice -ID $renderId  | Out-Null
        if ($captureId) { Set-AudioDevice -ID $captureId | Out-Null }
        Write-Log "Cambiado a: $label"
    } catch {
        Write-Log "ERROR cambiando a ${label}: $_"
    }
}

Write-Log 'Vigilante iniciado'
$lastConnected = $null

while ($true) {
    $connected = Get-HeadphonesConnected
    if ($null -eq $lastConnected) {
        if ($connected) { Set-Defaults $cfg.HeadphoneRenderId $cfg.HeadphoneCaptureId $cfg.HeadphoneLabel }
        else            { Set-Defaults $cfg.FallbackRenderId  $cfg.FallbackCaptureId  $cfg.FallbackLabel }
    }
    elseif ($connected -ne $lastConnected) {
        if ($connected) {
            Start-Sleep -Seconds 2   # dar tiempo al perfil Bluetooth a estabilizarse
            Set-Defaults $cfg.HeadphoneRenderId $cfg.HeadphoneCaptureId $cfg.HeadphoneLabel
        } else {
            Set-Defaults $cfg.FallbackRenderId $cfg.FallbackCaptureId $cfg.FallbackLabel
        }
    }
    $lastConnected = $connected
    Start-Sleep -Seconds 2
}
