# install.ps1 - Instalador global de PC Toolkit (sin admin)
#
# En un PC nuevo, desde una consola PowerShell normal:
#   irm https://raw.githubusercontent.com/ikerlorente11/pc-toolkit/main/install.ps1 | iex
#
# Desde el repo clonado:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1                          # pregunta herramienta a herramienta
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Tools all               # todas, sin preguntar
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Tools taskbar-rdp       # solo las indicadas
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Update                  # actualiza lo ya instalado
#
# (Este archivo debe quedarse en ASCII: con "irm | iex" no se respeta la codificacion.)
[CmdletBinding()]
param(
    [string[]]$Tools,
    [switch]$Update
)

$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# 1. Origen: el repo clonado, o descarga de GitHub si viene de "irm | iex"
$src = $PSScriptRoot
if (-not $src -or -not (Test-Path (Join-Path $src 'tools'))) {
    Write-Host 'Descargando PC Toolkit de GitHub...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path $env:TEMP "pc-toolkit-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'pc-toolkit.zip'
    Invoke-WebRequest 'https://github.com/ikerlorente11/pc-toolkit/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $tmp
    $src = Join-Path $tmp 'pc-toolkit-main'
}

# 2. Copiar la aplicacion a %LOCALAPPDATA%\PcToolkit\app (fuera de OneDrive; sustituye la version anterior)
$root = Join-Path $env:LOCALAPPDATA 'PcToolkit'
$app  = Join-Path $root 'app'
$firstInstall = -not (Test-Path $app)

$managers = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -match 'manager\\PcToolkit\.ps1' })
foreach ($m in $managers) { Stop-Process -Id $m.ProcessId -Force -ErrorAction SilentlyContinue }
foreach ($m in $managers) { Wait-Process -Id $m.ProcessId -Timeout 10 -ErrorAction SilentlyContinue }
# Reintentos por si algun archivo sigue bloqueado un instante
for ($i = 1; (Test-Path $app); $i++) {
    try { Remove-Item $app -Recurse -Force; break }
    catch { if ($i -ge 5) { throw }; Start-Sleep -Seconds 1 }
}
New-Item -ItemType Directory -Force -Path $app | Out-Null
foreach ($item in 'core', 'manager', 'tools', 'assets', 'VERSION', 'LICENSE', 'uninstall.ps1') {
    Copy-Item (Join-Path $src $item) $app -Recurse -Force
}

Import-Module (Join-Path $app 'core\Toolkit.psm1') -Force
$all = @(Get-Tools)

# 3. Instalaciones antiguas de los repos sueltos (audio-autoswitch, taskbar-rdp): se migran solas
$legacy = @{ 'audio-autoswitch' = 'AudioAutoSwitch'; 'taskbar-rdp' = 'TaskbarRdp' }
$legacyFound = @(foreach ($id in $legacy.Keys) {
    $dir = Join-Path $env:LOCALAPPDATA $legacy[$id]
    if (Test-Path $dir) {
        $oldConfig = Join-Path $dir 'config.json'
        $newConfig = Join-Path (Get-ToolDataDir $id) 'config.json'
        if ((Test-Path $oldConfig) -and -not (Test-Path $newConfig)) { Copy-Item $oldConfig $newConfig }
        $id
    }
})

# 4. Que herramientas instalar ("-Tools a,b" llega como un solo texto si se lanza con -File)
$Tools = @($Tools | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim() })
if ($Update) {
    $selected = @($all | Where-Object { (Get-ToolState $_) -ne 'NotInstalled' })
} elseif ($Tools -contains 'all') {
    $selected = $all
} elseif ($Tools) {
    $selected = @($all | Where-Object { $Tools -contains $_.id })
} else {
    Write-Host ''
    Write-Host 'Herramientas disponibles:' -ForegroundColor Cyan
    $selected = @(foreach ($t in $all) {
        Write-Host ''
        Write-Host "  $($t.name)" -ForegroundColor White
        Write-Host "  $($t.description)" -ForegroundColor DarkGray
        if ((Read-Host '  Instalar? [S/n]') -notmatch '^[nN]') { $t }
    })
}
$selected += @($all | Where-Object { $legacyFound -contains $_.id -and $selected.id -notcontains $_.id })

# 5. Instalar (en una actualizacion, las que estaban desactivadas siguen desactivadas)
foreach ($t in $selected) {
    $wasDisabled = (Get-ToolState $t) -eq 'Disabled'
    Write-Host "Instalando $($t.name)..."
    try {
        Install-Tool $t
        if ($wasDisabled) { Disable-Tool $t }
        if ($legacyFound -contains $t.id) {
            Remove-Item (Join-Path $env:LOCALAPPDATA $legacy[$t.id]) -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warning "$($t.name) no se pudo instalar: $($_.Exception.Message)"
    }
}

# 6. Gestor: acceso directo en el menu Inicio, arranque con Windows y abrirlo
Register-Manager -Autostart ($firstInstall -or (Test-ManagerAutostart))
Start-Manager -Show

Write-Host ''
Write-Host "PC Toolkit v$(Get-ToolkitVersion) instalado." -ForegroundColor Green
Write-Host "  Carpeta: $root"
Write-Host '  Abrelo desde el menu Inicio (PC Toolkit) o desde su icono en la bandeja del sistema.'
