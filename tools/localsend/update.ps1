# update.ps1 - Actualizaciones de LocalSend ("updates" en tool.json; el contrato está en core\Toolkit.psm1).
# La última versión es la última release de github.com/localsend/localsend (una llamada a la API) y se
# actualiza con winget, igual que se instaló (para el usuario; si está instalado para todos, pide administrador).
# «En uso» es tener su ventana abierta: oculto en la bandeja (como lo deja la herramienta para recibir) se
# cierra, se actualiza y se vuelve a abrir oculto; si no, la actualización automática no cerraría nunca.

param(
    [Parameter(Mandatory)][ValidateSet('info', 'latest', 'update')][string]$Action,
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# "1.18.2+64" -> "1.18.2"
function Get-LocalSendVersion {
    $exe = Get-LocalSendExe
    if ($exe) { ((Get-Item $exe).VersionInfo.ProductVersion -split '\+')[0].Trim() }
}

function Get-LocalSendProcesses {
    $session = (Get-Process -Id $PID).SessionId
    @(Get-Process localsend_app -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session)
}

# Su ventana está a la vista (MainWindowHandle es 0 si solo está en la bandeja)
function Test-LocalSendWindow { [bool](Get-LocalSendProcesses | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }) }

# Instalado fuera de la carpeta del usuario (Archivos de programa): actualizarlo pide administrador
function Test-LocalSendElevated {
    $exe = Get-LocalSendExe
    [bool]($exe -and -not $exe.StartsWith($env:LOCALAPPDATA, [StringComparison]::OrdinalIgnoreCase))
}

switch ($Action) {
    'info' {
        [pscustomobject]@{ Installed = Get-LocalSendVersion; InUse = Test-LocalSendWindow; Elevated = Test-LocalSendElevated }
    }
    'latest' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod 'https://api.github.com/repos/localsend/localsend/releases/latest' -UseBasicParsing
        $release.tag_name -replace '^v', ''
    }
    'update' {
        if (-not (Get-LocalSendExe)) { throw 'LocalSend no está instalado.' }
        $elevated = Test-LocalSendElevated
        if ($Auto -and $elevated) { throw 'LocalSend está instalado para todos los usuarios: actualizarlo pide permisos de administrador.' }
        $visible = Test-LocalSendWindow
        if ($Auto -and $visible) { throw 'LocalSend está abierto: se actualizará cuando lo cierres.' }
        $before = Get-LocalSendVersion
        $procs = Get-LocalSendProcesses
        Set-ToolStatus $(if ($elevated) { 'Actualizando LocalSend: acepta el aviso de permisos de Windows...' } else { 'Actualizando LocalSend con winget...' })
        if ($procs) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            $procs | ForEach-Object { Wait-Process -Id $_.Id -Timeout 10 -ErrorAction SilentlyContinue }
        }
        try {
            Install-WingetPackage 'LocalSend.LocalSend' -Upgrade -Elevated:$elevated
        } catch {
            Write-LocalSendLog "ERROR al actualizar LocalSend: $($_.Exception.Message)"
            throw
        } finally {
            # Si estaba abierto, se vuelve a abrir como estaba (oculto en la bandeja o con su ventana)
            if ($procs -and -not (Test-LocalSendRunning)) { try { Start-LocalSend -Hidden:(-not $visible) } catch {} }
        }
        $after = Get-LocalSendVersion
        if (-not (Test-NewerVersion $after $before)) {
            throw "winget todavía no ofrece una versión de LocalSend más nueva que la $before; se reintentará más tarde."
        }
        Write-LocalSendLog "LocalSend actualizado de $before a $after"
        $after
    }
}
