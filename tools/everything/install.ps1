# install.ps1 - Instala la herramienta Everything (lo llaman el instalador global y el gestor).
# Si Everything no está instalado, lo instala con winget (MSI oficial de voidtools, con su servicio de
# indexado): Windows pide permisos de administrador y, si se rechazan, la instalación se cancela.
# La tarea solo se asegura de que Everything esté en marcha al iniciar sesión; la ventana de búsqueda
# vive en el gestor y la abre su atajo.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Get-EverythingExe)) {
    Set-ToolStatus 'Instalando Everything: acepta el aviso de permisos de Windows...'
    Install-WingetPackage 'voidtools.Everything' @('--installer-type', 'wix') -Elevated
    if (-not (Get-EverythingExe)) { throw 'No se encuentra Everything después de instalarlo.' }
    Write-EverythingLog "Everything instalado con winget en $(Get-EverythingExe)"
}

$user     = Get-CurrentUserId
$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'Everything.ps1')
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'PcToolkitEverything' -Action $action -Trigger $trigger -Settings $settings `
    -Description 'PC Toolkit: inicia Everything en la bandeja (la búsqueda la abre el gestor con un atajo)' -Force | Out-Null
