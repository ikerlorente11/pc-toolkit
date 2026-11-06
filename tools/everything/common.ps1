# common.ps1 - Dónde está Everything, configuración y registro de la herramienta. Lo cargan con "."
# install.ps1, Everything.ps1 (la tarea) y, dentro del gestor, window.ps1, settings.ps1 y home.ps1.
# Funciones "script:" para que sigan vivas en los botones y en la ventana de búsqueda.

$script:EverythingDir  = $PSScriptRoot
$script:EverythingData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\everything'

# Orden de los resultados: clave guardada -> (texto, código EVERYTHING_IPC_SORT_*)
$script:EverythingSorts = [ordered]@{
    name     = @('Nombre', 1)
    modified = @('Fecha de modificación (recientes primero)', 14)
    path     = @('Ruta', 3)
    size     = @('Tamaño (grandes primero)', 6)
}

# Everything.exe instalado (o $null): carpetas habituales, registro de desinstalación, el proceso en
# marcha y la versión portable de winget
function script:Get-EverythingExe {
    $dirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) | Where-Object { $_ }
    foreach ($d in $dirs) {
        $exe = Join-Path $d 'Everything\Everything.exe'
        if (Test-Path $exe) { return $exe }
    }
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($e in (Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Everything*' -and $_.InstallLocation })) {
        $exe = Join-Path $e.InstallLocation 'Everything.exe'
        if (Test-Path $exe) { return $exe }
    }
    $p = Get-Process Everything -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
    if ($p) { return $p.Path }
    $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    Get-ChildItem $winget -Directory -Filter 'voidtools.Everything_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'Everything.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
}

# ¿Está en marcha el Everything de esta sesión (el de la bandeja, que es el que atiende las búsquedas)?
# El servicio va en la sesión 0 y no cuenta.
function script:Test-EverythingClient {
    $session = (Get-Process -Id $PID).SessionId
    [bool](Get-Process Everything -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session)
}

function script:Start-EverythingClient {
    $exe = Get-EverythingExe
    if (-not $exe) { throw 'Everything no está instalado.' }
    Start-Process $exe -ArgumentList '-startup'   # en la bandeja, sin abrir su ventana
}

function script:Write-EverythingLog($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $script:EverythingData | Out-Null
        $log = Join-Path $script:EverythingData 'Everything.log'
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Clear-Content $log }
        Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

function script:Get-EverythingConfig {
    $path = Join-Path $script:EverythingData 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    @{
        Sort        = if ($script:EverythingSorts.Contains([string]$c.Sort)) { [string]$c.Sort } else { 'name' }
        MatchPath   = [bool]$c.MatchPath
        Folders     = if ($null -ne $c.Folders) { [bool]$c.Folders } else { $true }
        HideRecycleBin = if ($null -ne $c.HideRecycleBin) { [bool]$c.HideRecycleBin } else { $true }
        CloseOnBlur = if ($null -ne $c.CloseOnBlur) { [bool]$c.CloseOnBlur } else { $true }
    }
}

function script:Save-EverythingConfig($Config) {
    New-Item -ItemType Directory -Force -Path $script:EverythingData | Out-Null
    $Config | ConvertTo-Json | Set-Content (Join-Path $script:EverythingData 'config.json') -Encoding UTF8
}

function script:Set-EverythingSetting([string]$Name, $Value) {
    $cfg = Get-EverythingConfig
    $cfg[$Name] = $Value
    Save-EverythingConfig $cfg
}
