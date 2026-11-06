# install.ps1 - Instala la herramienta LocalSend (lo llaman el instalador global y el gestor).
# Si LocalSend no está instalado, lo instala con winget para el usuario actual (sin permisos de
# administrador). La tarea lo inicia oculto en la bandeja al iniciar sesión y crea el acceso de "Enviar a".

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Get-LocalSendExe)) {
    Set-ToolStatus 'Descargando e instalando LocalSend...'
    Install-WingetPackage 'LocalSend.LocalSend' @('--scope', 'user')
    if (-not (Get-LocalSendExe)) { throw 'No se encuentra LocalSend después de instalarlo.' }
    Write-LocalSendLog "LocalSend instalado con winget en $(Get-LocalSendExe)"
}

$user     = Get-CurrentUserId
$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'LocalSend.ps1')
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'PcToolkitLocalSend' -Action $action -Trigger $trigger -Settings $settings `
    -Description 'PC Toolkit: inicia LocalSend oculto en la bandeja para poder recibir archivos' -Force | Out-Null
