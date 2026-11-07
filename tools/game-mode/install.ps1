# install.ps1 - Instala Modo juegos (lo llaman el instalador global y el gestor).
# La entrada de arranque y la tarea elevada necesitan administrador: se pide UAC solo si faltan.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

New-Item -ItemType Directory -Force -Path $script:GameModeData | Out-Null
if (-not (Test-GameModeSetupCurrent)) { Invoke-GameModeElevated 'Setup.ps1' }
Register-GameModeTask
