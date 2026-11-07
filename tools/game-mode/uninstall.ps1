# uninstall.ps1 - Al desinstalar Modo juegos, quita (con administrador) su entrada de arranque y su tarea elevada.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if ((Get-GameModeState) -or (Get-ScheduledTask -TaskName $script:GameModeBootTask -ErrorAction SilentlyContinue)) {
    Invoke-GameModeElevated 'Remove.ps1'
}
