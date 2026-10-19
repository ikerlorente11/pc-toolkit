# Apply.ps1 - Aplica los sonidos elegidos para conectar y desconectar dispositivos.
# Lo lanza la tarea programada "PcToolkitDeviceSounds" al iniciar sesión (por si Windows los ha
# cambiado, p. ej. al cambiar de tema) y al activar la herramienta.

. (Join-Path $PSScriptRoot 'common.ps1')
Invoke-DeviceSounds

$cfg = Get-DeviceSoundsConfig
New-Item -ItemType Directory -Force -Path $script:DeviceSoundsData | Out-Null
$log = Join-Path $script:DeviceSoundsData 'DeviceSounds.log'
if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Clear-Content $log }
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Aplicado. Conectar: $(Get-DeviceSoundLabel $cfg.Connect) · Desconectar: $(Get-DeviceSoundLabel $cfg.Disconnect)" |
    Add-Content $log -Encoding UTF8
