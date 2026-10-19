# disable.ps1 - Al desactivar o desinstalar, vuelven los sonidos de Windows
. (Join-Path $PSScriptRoot 'common.ps1')
Restore-DeviceSounds
