# common.ps1 - Perfiles de la barra de tareas: leer/guardar la configuración, aplicar el perfil que
# toque y refrescar la barra. Lo cargan con "." Taskbar.ps1 (tarea programada), settings.ps1,
# home.ps1 y refresh.ps1 (gestor). Funciones "script:" para que sigan vivas en los botones del gestor.

if (-not ('PcToolkit.Taskbar.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'TaskbarNative.cs') }
$script:TaskbarDataDir = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\taskbar'
$script:ExplorerAdvanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

# Ajustes actuales de Windows (para el perfil inicial)
function script:Get-CurrentTaskbarProfile {
    $adv = Get-ItemProperty $script:ExplorerAdvanced -ErrorAction SilentlyContinue
    @{
        AutoHide   = [PcToolkit.Taskbar.Native]::GetAutoHide()
        Alignment  = if ($adv.TaskbarAl -eq 0) { 'left' } else { 'center' }   # sin valor = centro (lo de serie)
        AllScreens = $adv.MMTaskbarEnabled -ne 0                               # sin valor = todas
    }
}

function script:ConvertTo-TaskbarProfile($Source, $Fallback) {
    @{
        AutoHide   = if ($null -ne $Source.AutoHide)   { [bool]$Source.AutoHide }   else { $Fallback.AutoHide }
        Alignment  = if ($Source.Alignment -in 'left', 'center') { $Source.Alignment } else { $Fallback.Alignment }
        AllScreens = if ($null -ne $Source.AllScreens) { [bool]$Source.AllScreens } else { $Fallback.AllScreens }
    }
}

# Configuración: perfil Normal (delante del PC) y, opcional, uno distinto para Escritorio Remoto.
# Sin configuración guardada: Normal = como está ahora pero autoocultable; Remoto = siempre visible
# (lo que hacía la herramienta antes).
function script:Get-TaskbarConfig {
    $path = Join-Path $script:TaskbarDataDir 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $now = Get-CurrentTaskbarProfile
    $localDefault  = @{ AutoHide = $true;  Alignment = $now.Alignment; AllScreens = $now.AllScreens }
    $remoteDefault = @{ AutoHide = $false; Alignment = $now.Alignment; AllScreens = $now.AllScreens }
    @{
        Local         = ConvertTo-TaskbarProfile $c.Local $localDefault
        RemoteEnabled = if ($null -ne $c.RemoteEnabled) { [bool]$c.RemoteEnabled } else { $true }
        Remote        = ConvertTo-TaskbarProfile $c.Remote $remoteDefault
    }
}

function script:Save-TaskbarConfig($Config) {
    New-Item -ItemType Directory -Force -Path $script:TaskbarDataDir | Out-Null
    $Config | ConvertTo-Json | Set-Content (Join-Path $script:TaskbarDataDir 'config.json') -Encoding UTF8
}

# 'Remote' si estamos en Escritorio Remoto y hay perfil para ello; si no, 'Local'
function script:Get-ActiveTaskbarProfileName($Config) {
    if ($Config.RemoteEnabled -and [PcToolkit.Taskbar.Native]::IsRemote) { 'Remote' } else { 'Local' }
}

function script:Set-ExplorerValue([string]$Name, [int]$Value) {
    $current = (Get-ItemProperty $script:ExplorerAdvanced -ErrorAction SilentlyContinue).$Name
    if ($current -ne $Value) { Set-ItemProperty $script:ExplorerAdvanced $Name $Value -Type DWord; return $true }
    $false
}

# Aplica un perfil; solo toca lo que cambia, para no hacer parpadear la barra
function script:Invoke-TaskbarProfile($TaskbarProfile) {
    $changed = Set-ExplorerValue 'TaskbarAl' $(if ($TaskbarProfile.Alignment -eq 'left') { 0 } else { 1 })
    $changed = (Set-ExplorerValue 'MMTaskbarEnabled' $(if ($TaskbarProfile.AllScreens) { 1 } else { 0 })) -or $changed
    if ($changed) { [PcToolkit.Taskbar.Native]::NotifySettingsChanged() }
    if ([PcToolkit.Taskbar.Native]::GetAutoHide() -ne $TaskbarProfile.AutoHide) { [PcToolkit.Taskbar.Native]::SetAutoHide($TaskbarProfile.AutoHide) }
}

# Aplica el perfil que toca ahora mismo. Devuelve su nombre.
function script:Invoke-ActiveTaskbarProfile {
    $cfg = Get-TaskbarConfig
    $name = Get-ActiveTaskbarProfileName $cfg
    Invoke-TaskbarProfile $cfg[$name]
    $name
}

# Arreglo para cuando la barra autoocultable se queda escondida y no sale con el ratón:
# lo mismo que desmarcar y volver a marcar "Ocultar automáticamente" a mano.
function script:Invoke-TaskbarRefresh {
    $cfg = Get-TaskbarConfig
    $taskbarProfile = $cfg[(Get-ActiveTaskbarProfileName $cfg)]
    [PcToolkit.Taskbar.Native]::SetAutoHide($false)
    Start-Sleep -Milliseconds 400
    [PcToolkit.Taskbar.Native]::SetAutoHide($taskbarProfile.AutoHide)
}

function script:Get-TaskbarProfileLabel([string]$Name) { if ($Name -eq 'Remote') { 'Escritorio Remoto' } else { 'Normal' } }

function script:Get-TaskbarProfileSummary($TaskbarProfile) {
    $parts = @(
        $(if ($TaskbarProfile.AutoHide) { 'se oculta' } else { 'siempre visible' }),
        $(if ($TaskbarProfile.Alignment -eq 'left') { 'a la izquierda' } else { 'centrada' }),
        $(if ($TaskbarProfile.AllScreens) { 'todas las pantallas' } else { 'solo la principal' })
    )
    $parts -join ', '
}
