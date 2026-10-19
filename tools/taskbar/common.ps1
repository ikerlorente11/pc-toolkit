# common.ps1 - Perfiles de la barra de tareas: leer/guardar la configuración, aplicar el perfil que
# toque y refrescar la barra. Lo cargan con "." Taskbar.ps1 (tarea programada), settings.ps1,
# home.ps1 y refresh.ps1 (gestor). Funciones "script:" para que sigan vivas en los botones del gestor.
#
# Qué se aplica al momento y qué no (comprobado en Windows 11 25H2):
#   ocultar, alineación, pantallas, tamaño de iconos y búsqueda -> al momento (registro + aviso a Explorer)
#   posición -> hay que reiniciar Explorer; en Windows 11 solo abajo/arriba (a los lados queda vacía)

if (-not ('PcToolkit.Taskbar.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'TaskbarNative.cs') }
$script:TaskbarDataDir   = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\taskbar'
$script:ExplorerAdvanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$script:ExplorerSearch   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
$script:StuckRects       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
$script:IsWindows11      = [Environment]::OSVersion.Version.Build -ge 22000

$script:TaskbarEdges   = @{ left = 0; top = 1; right = 2; bottom = 3 }
$script:TaskbarSearch  = @{ hidden = 0; icon = 1; box = 2 }   # SearchboxTaskbarMode
$script:TaskbarIcons   = @{ small = 0; normal = 1 }          # IconSizePreference ('auto' = sin valor, lo de serie)

# Posiciones que admite este Windows
function script:Get-TaskbarPositions {
    if ($script:IsWindows11) { @('bottom', 'top') } else { @('bottom', 'top', 'left', 'right') }
}

# Ajustes actuales de Windows (base de los perfiles iniciales)
function script:Get-CurrentTaskbarProfile {
    $adv = Get-ItemProperty $script:ExplorerAdvanced -ErrorAction SilentlyContinue
    $search = (Get-ItemProperty $script:ExplorerSearch -ErrorAction SilentlyContinue).SearchboxTaskbarMode
    $edge = [PcToolkit.Taskbar.Native]::GetEdge()
    @{
        AutoHide   = [PcToolkit.Taskbar.Native]::GetAutoHide()
        Position   = ($script:TaskbarEdges.GetEnumerator() | Where-Object Value -eq $edge | Select-Object -First 1).Key
        Alignment  = if ($adv.TaskbarAl -eq 0) { 'left' } else { 'center' }                         # sin valor = centro
        AllScreens = $adv.MMTaskbarEnabled -ne 0                                                     # sin valor = todas
        IconSize   = if ($adv.IconSizePreference -eq 0) { 'small' } elseif ($adv.IconSizePreference -eq 1) { 'normal' } else { 'auto' }
        Search     = if ($search -eq 0) { 'hidden' } elseif ($search -eq 2) { 'box' } else { 'icon' }
    }
}

function script:ConvertTo-TaskbarProfile($Source, $Fallback) {
    $p = @{}
    foreach ($k in 'AutoHide', 'AllScreens') { $p[$k] = if ($null -ne $Source.$k) { [bool]$Source.$k } else { $Fallback[$k] } }
    $p.Position  = if ($Source.Position -in (Get-TaskbarPositions)) { $Source.Position } else { $Fallback.Position }
    $p.Alignment = if ($Source.Alignment -in 'left', 'center') { $Source.Alignment } else { $Fallback.Alignment }
    $p.IconSize  = if ($Source.IconSize -in 'small', 'normal', 'auto') { $Source.IconSize } else { $Fallback.IconSize }
    $p.Search    = if ($Source.Search -in 'hidden', 'icon', 'box') { $Source.Search } else { $Fallback.Search }
    if ($p.Position -notin (Get-TaskbarPositions)) { $p.Position = 'bottom' }
    $p
}

# Configuración: perfil normal y, opcional, uno independiente para Escritorio Remoto.
# Sin configuración guardada, ambos parten de los ajustes actuales; el remoto, siempre visible.
function script:Get-TaskbarConfig {
    $path = Join-Path $script:TaskbarDataDir 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $now = Get-CurrentTaskbarProfile
    $localDefault = $now.Clone();  $localDefault.AutoHide = $true
    $remoteDefault = $now.Clone(); $remoteDefault.AutoHide = $false
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

# 'Remote' en una sesión de Escritorio Remoto con perfil propio; si no, 'Local'
function script:Get-ActiveTaskbarProfileName($Config) {
    if ($Config.RemoteEnabled -and [PcToolkit.Taskbar.Native]::IsRemote) { 'Remote' } else { 'Local' }
}

# Escribe un valor DWORD solo si cambia ($null = quitarlo). Devuelve si ha cambiado algo.
function script:Set-TaskbarValue([string]$Key, [string]$Name, $Value) {
    $current = (Get-ItemProperty $Key -ErrorAction SilentlyContinue).$Name
    if ($null -eq $Value) {
        if ($null -eq $current) { return $false }
        Remove-ItemProperty $Key $Name -ErrorAction SilentlyContinue
        return $true
    }
    if ($current -eq $Value) { return $false }
    if (-not (Test-Path $Key)) { New-Item $Key -Force | Out-Null }
    Set-ItemProperty $Key $Name ([int]$Value) -Type DWord
    $true
}

function script:Restart-Explorer {
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    for ($i = 0; $i -lt 30 -and -not [PcToolkit.Taskbar.Native]::TrayReady; $i++) { Start-Sleep -Seconds 1 }
    Start-Sleep -Seconds 3
}

function script:Test-TaskbarPositionPending($TaskbarProfile) {
    [PcToolkit.Taskbar.Native]::GetEdge() -ne $script:TaskbarEdges[$TaskbarProfile.Position]
}

# Aplica un perfil; solo toca lo que cambia, para no hacer parpadear la barra.
# La posición necesita reiniciar Explorer: con -SkipPosition se deja para otro momento.
function script:Invoke-TaskbarProfile($TaskbarProfile, [switch]$SkipPosition) {
    if (-not $SkipPosition -and (Test-TaskbarPositionPending $TaskbarProfile)) {
        # Explorer lee al arrancar la posición (byte 12) y la ocultación (byte 8) de StuckRects3
        $bytes = [byte[]](Get-ItemProperty $script:StuckRects).Settings
        $bytes[12] = [byte]$script:TaskbarEdges[$TaskbarProfile.Position]
        $bytes[8]  = if ($TaskbarProfile.AutoHide) { $bytes[8] -bor 1 } else { $bytes[8] -band 0xFE }
        Set-ItemProperty $script:StuckRects Settings $bytes -Type Binary
        Restart-Explorer
        # Recién arrancada, la barra a veces ignora el cambio de ocultación: se insiste hasta que se mantiene
        for ($i = 0; $i -lt 10 -and [PcToolkit.Taskbar.Native]::GetAutoHide() -ne $TaskbarProfile.AutoHide; $i++) {
            [PcToolkit.Taskbar.Native]::SetAutoHide($TaskbarProfile.AutoHide)
            Start-Sleep -Seconds 1
        }
    }
    $changed = Set-TaskbarValue $script:ExplorerAdvanced 'TaskbarAl' $(if ($TaskbarProfile.Alignment -eq 'left') { 0 } else { 1 })
    $changed = (Set-TaskbarValue $script:ExplorerAdvanced 'MMTaskbarEnabled' $(if ($TaskbarProfile.AllScreens) { 1 } else { 0 })) -or $changed
    $changed = (Set-TaskbarValue $script:ExplorerAdvanced 'IconSizePreference' $script:TaskbarIcons[$TaskbarProfile.IconSize]) -or $changed
    $changed = (Set-TaskbarValue $script:ExplorerSearch 'SearchboxTaskbarMode' $script:TaskbarSearch[$TaskbarProfile.Search]) -or $changed
    if ($changed) { [PcToolkit.Taskbar.Native]::NotifySettingsChanged() }
    if ([PcToolkit.Taskbar.Native]::GetAutoHide() -ne $TaskbarProfile.AutoHide) { [PcToolkit.Taskbar.Native]::SetAutoHide($TaskbarProfile.AutoHide) }
}

# Aplica el perfil que corresponde ahora. Devuelve su nombre.
function script:Invoke-ActiveTaskbarProfile([switch]$SkipPosition) {
    $cfg = Get-TaskbarConfig
    $name = Get-ActiveTaskbarProfileName $cfg
    Invoke-TaskbarProfile $cfg[$name] -SkipPosition:$SkipPosition
    $name
}

# Para cuando la barra con ocultación automática deja de aparecer al acercar el puntero:
# equivale a desactivar y volver a activar "Ocultar automáticamente".
function script:Invoke-TaskbarRefresh {
    $cfg = Get-TaskbarConfig
    $taskbarProfile = $cfg[(Get-ActiveTaskbarProfileName $cfg)]
    [PcToolkit.Taskbar.Native]::SetAutoHide($false)
    Start-Sleep -Milliseconds 400
    [PcToolkit.Taskbar.Native]::SetAutoHide($taskbarProfile.AutoHide)
}

function script:Get-TaskbarProfileLabel([string]$Name) { if ($Name -eq 'Remote') { 'Perfil de Escritorio remoto' } else { 'Perfil normal' } }

$script:TaskbarPositionLabels = @{ bottom = 'Abajo'; top = 'Arriba'; left = 'Izquierda'; right = 'Derecha' }

# Resumen corto para la portada: posición y ocultación
function script:Get-TaskbarProfileSummary($TaskbarProfile) {
    "$($script:TaskbarPositionLabels[$TaskbarProfile.Position])  ·  $(if ($TaskbarProfile.AutoHide) { 'Ocultación automática' } else { 'Siempre visible' })"
}
