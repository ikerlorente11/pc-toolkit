# disable.ps1 - Al desactivar o desinstalar, deja la barra siempre visible (lo normal en Windows)
& (Join-Path $PSScriptRoot 'TaskbarRdp.ps1') -AlwaysVisible
