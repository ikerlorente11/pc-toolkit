# hotkey.ps1 - Atajo de Audio AutoSwitch: pasa al siguiente dispositivo conectado y habilitado.
# Lo ejecuta el gestor al pulsar el atajo y muestra el texto que devuelve.
# El vigilante lo detecta como cambio a mano (y cambia el micro si está configurado).

. (Join-Path $PSScriptRoot 'common.ps1')

$devices = Get-EnabledAudioDevices
if (-not $devices) { return 'No hay dispositivos habilitados conectados' }

# Si suena uno no habilitado, IndexOf da -1 y se salta al primero habilitado
$i = [array]::IndexOf(@($devices | ForEach-Object Id), [PcToolkit.Audio.Endpoints]::GetDefaultId(0))
$next = $devices[($i + 1) % $devices.Count]
[PcToolkit.Audio.Endpoints]::SetDefault($next.Id)
$next.Name
