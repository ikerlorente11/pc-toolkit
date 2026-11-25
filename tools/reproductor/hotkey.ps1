# hotkey.ps1 - Atajo de El Reproductor: abre la app (o la trae al frente si ya está abierta).
# Lo ejecuta el gestor al pulsar el atajo; no devuelve texto, así que no sale el aviso.

. (Join-Path $PSScriptRoot 'common.ps1')
Start-Reproductor
