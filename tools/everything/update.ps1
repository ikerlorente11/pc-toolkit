# update.ps1 - Actualizaciones de Everything ("updates" en tool.json; el contrato está en core\Toolkit.psm1).
# La última versión sale de la página de descargas de voidtools (no está en GitHub) y se actualiza con winget.
# El MSI oficial va en Archivos de programa con su servicio, así que actualizarlo pide permisos de administrador:
# el gestor nunca lo actualiza solo, solo avisa y lo actualiza al pulsar Actualizar (Windows pregunta).

param(
    [Parameter(Mandatory)][ValidateSet('info', 'latest', 'update')][string]$Action,
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-EverythingVersion {
    $exe = Get-EverythingExe
    if ($exe) { (Get-Item $exe).VersionInfo.ProductVersion.Trim() }
}

# Fuera de la carpeta del usuario (lo normal: el MSI en Archivos de programa) pide administrador
function Test-EverythingElevated {
    $exe = Get-EverythingExe
    [bool]($exe -and -not $exe.StartsWith($env:LOCALAPPDATA, [StringComparison]::OrdinalIgnoreCase))
}

switch ($Action) {
    'info' {
        # Everything siempre está en la bandeja (es el que atiende las búsquedas): actualizarlo lo cierra un momento
        [pscustomobject]@{ Installed = Get-EverythingVersion; InUse = Test-EverythingClient; Elevated = Test-EverythingElevated }
    }
    'latest' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $html = (Invoke-WebRequest 'https://www.voidtools.com/downloads/' -UseBasicParsing).Content
        if ($html -notmatch 'Everything-(\d+(?:\.\d+){2,3})\.x64-Setup\.exe') { throw 'No se encuentra la versión de Everything en voidtools.com.' }
        $Matches[1]
    }
    'update' {
        if (-not (Get-EverythingExe)) { throw 'Everything no está instalado.' }
        $elevated = Test-EverythingElevated
        if ($Auto -and $elevated) { throw 'Actualizar Everything pide permisos de administrador: pulsa Actualizar en su página.' }
        if ($Auto -and (Test-EverythingClient)) { throw 'Everything está abierto: se actualizará cuando se cierre.' }
        $before = Get-EverythingVersion
        $wasRunning = Test-EverythingClient
        Set-ToolStatus $(if ($elevated) { 'Actualizando Everything: acepta el aviso de permisos de Windows...' } else { 'Actualizando Everything con winget...' })
        try {
            Install-WingetPackage 'voidtools.Everything' -Upgrade -Elevated:$elevated
        } catch {
            Write-EverythingLog "ERROR al actualizar Everything: $($_.Exception.Message)"
            throw
        } finally {
            # El instalador cierra el Everything de la bandeja; sin él no hay búsquedas
            if ($wasRunning -and -not (Test-EverythingClient)) { try { Start-EverythingClient } catch {} }
        }
        $after = Get-EverythingVersion
        if (-not (Test-NewerVersion $after $before)) {
            throw "winget todavía no ofrece una versión de Everything más nueva que la $before; prueba más tarde."
        }
        Write-EverythingLog "Everything actualizado de $before a $after"
        $after
    }
}
