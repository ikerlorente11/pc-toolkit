# disable.ps1 - Al desactivar o desinstalar con un juego abierto, devuelve el HDR que se había quitado.
# Las ventanas sin bordes se quedan así hasta que se cierre el juego.
. (Join-Path $PSScriptRoot 'common.ps1')
[void](Restore-Hdr)
