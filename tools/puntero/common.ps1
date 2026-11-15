# common.ps1 - Dónde está la app El Puntero, su versión y cómo descargarla, arrancarla y pararla. Lo cargan
# con "." install.ps1, update.ps1, disable.ps1, Puntero.ps1 y, dentro del gestor, home.ps1. Funciones "script:"
# para que sigan vivas en los botones.
#
# La app es la de tools\puntero\app (Tauri): el CI de PC Toolkit la compila en Windows y publica su instalador
# NSIS en las releases del repo con etiqueta "puntero-v<versión>". Se instala para el usuario actual, en
# %LOCALAPPDATA%\El Puntero, y vive en la bandeja (con --hidden arranca sin abrir la ventana).

$script:PunteroData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\puntero'
$script:PunteroRepo = 'ikerlorente11/pc-toolkit'
$script:PunteroUninstallKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\El Puntero'
# el "Iniciar con Windows" de la propia app (tauri-plugin-autostart): con la herramienta lo hace la tarea
$script:PunteroRunKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'

function script:Write-PunteroLog([string]$Text) {
    New-Item -ItemType Directory -Force -Path $script:PunteroData | Out-Null
    Add-Content (Join-Path $script:PunteroData 'Puntero.log') "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
}

function script:Get-PunteroExe {
    $e = Get-ItemProperty $script:PunteroUninstallKey -ErrorAction SilentlyContinue
    if ($e.InstallLocation) {
        $exe = Join-Path $e.InstallLocation.Trim('"') 'el-puntero.exe'   # NSIS la guarda entre comillas
        if (Test-Path $exe) { return $exe }
    }
    $exe = Join-Path $env:LOCALAPPDATA 'El Puntero\el-puntero.exe'
    if (Test-Path $exe) { return $exe }
}

function script:Get-PunteroVersion {
    $exe = Get-PunteroExe
    if ($exe) { ((Get-Item $exe).VersionInfo.ProductVersion -split '\.')[0..2] -join '.' }
}

function script:Test-PunteroRunning {
    [bool](Get-Process el-puntero -ErrorAction SilentlyContinue)
}

# La última release de la app (etiqueta puntero-v*): versión y dirección de su instalador
function script:Get-PunteroLatest {
    $releases = Invoke-RestMethod "https://api.github.com/repos/$script:PunteroRepo/releases?per_page=30" -UseBasicParsing
    $release = $releases | Where-Object { $_.tag_name -like 'puntero-v*' -and -not $_.draft } | Select-Object -First 1
    if (-not $release) { throw 'No hay ninguna release de El Puntero todavía.' }
    $asset = $release.assets | Where-Object { $_.name -like '*setup.exe' } | Select-Object -First 1
    if (-not $asset) { throw "La release $($release.tag_name) no trae instalador." }
    [pscustomobject]@{ Version = $release.tag_name -replace '^puntero-v', ''; Url = $asset.browser_download_url; Name = $asset.name }
}

function script:Start-Puntero([switch]$Hidden) {
    $exe = Get-PunteroExe
    if (-not $exe) { throw 'El Puntero no está instalado.' }
    if ($Hidden) { Start-Process $exe -ArgumentList '--hidden' } else { Start-Process $exe }
}

function script:Stop-Puntero {
    Get-Process el-puntero -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Con la herramienta, la tarea lo arranca al iniciar sesión: fuera el arranque propio de la app (no se duplica
# y, al desactivar la herramienta, deja de arrancar de verdad)
function script:Remove-PunteroAutostart {
    Remove-ItemProperty $script:PunteroRunKey -Name 'El Puntero' -ErrorAction SilentlyContinue
}

# Descarga e instala (o actualiza) la app en silencio, para el usuario actual. Solo hacia arriba. Si estaba
# arrancada, la para para instalar y la vuelve a arrancar oculta (está en la bandeja: no se pierde nada).
function script:Install-Puntero {
    $latest = Get-PunteroLatest
    $current = Get-PunteroVersion
    if ($current -and ([version]$current -ge [version]$latest.Version)) { return $false }
    New-Item -ItemType Directory -Force -Path $script:PunteroData | Out-Null
    $setup = Join-Path $script:PunteroData $latest.Name
    Invoke-WebRequest $latest.Url -OutFile $setup -UseBasicParsing
    $wasRunning = Test-PunteroRunning
    Stop-Puntero
    $p = Start-Process $setup -ArgumentList '/S', '/currentuser' -PassThru -Wait
    Remove-Item $setup -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) { throw "El instalador de El Puntero terminó con el código $($p.ExitCode)." }
    if (-not (Get-PunteroExe)) { throw 'No se encuentra El Puntero después de instalarlo.' }
    Write-PunteroLog "El Puntero $($latest.Version) instalado en $(Get-PunteroExe)"
    if ($wasRunning) { Start-Puntero -Hidden }
    $true
}
