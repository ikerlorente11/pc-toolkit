# disable.ps1 - Al desactivar o desinstalar con un juego abierto, devuelve el HDR que se había quitado.
. (Join-Path $PSScriptRoot 'common.ps1')
[void](Restore-Hdr)
