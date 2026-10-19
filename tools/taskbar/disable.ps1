# disable.ps1 - Al desactivar o desinstalar, deja la barra siempre visible (lo normal en Windows).
# La alineación y las pantallas se quedan como estén.
& (Join-Path $PSScriptRoot 'Taskbar.ps1') -AlwaysVisible
