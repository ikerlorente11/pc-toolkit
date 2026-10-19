# hotkey.ps1 - Atajo de Audio AutoSwitch: pasa al siguiente dispositivo de salida conectado.
# Lo ejecuta el gestor al pulsar el atajo de tool.json y muestra el texto que devuelve.
# El vigilante lo detecta como cambio a mano (y cambia el micro si está configurado).

if (-not ('PcToolkit.Audio.Endpoints' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'AudioEndpoints.cs') }

$devices = @([PcToolkit.Audio.Endpoints]::List(0) | Where-Object { -not $_.IsHandsFree })
if (-not $devices) { return 'No hay dispositivos de sonido conectados' }

$i = [array]::IndexOf(@($devices | ForEach-Object Id), [PcToolkit.Audio.Endpoints]::GetDefaultId(0))
$next = $devices[($i + 1) % $devices.Count]
[PcToolkit.Audio.Endpoints]::SetDefault($next.Id)
$next.Name
