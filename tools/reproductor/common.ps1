# common.ps1 - Dónde está la app El Reproductor, su versión y cómo descargarla. Lo cargan con "." install.ps1,
# update.ps1, disable.ps1, hotkey.ps1 y, dentro del gestor, home.ps1. Funciones "script:" para que sigan vivas
# en los botones.
#
# La app es la de tools\reproductor\app (Tauri): el CI de PC Toolkit la compila en Windows y publica su instalador
# NSIS en las releases del repo con etiqueta "reproductor-v<versión>". Se instala para el usuario actual, en
# %LOCALAPPDATA%\El Reproductor.

$script:ReproductorDir  = $PSScriptRoot
$script:ReproductorData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\reproductor'
$script:ReproductorRepo = 'ikerlorente11/pc-toolkit'
$script:ReproductorUninstallKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\El Reproductor'

function script:Write-ReproductorLog([string]$Text) {
    New-Item -ItemType Directory -Force -Path $script:ReproductorData | Out-Null
    Add-Content (Join-Path $script:ReproductorData 'Reproductor.log') "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
}

# el-reproductor.exe instalado (o $null): lo que diga el registro de desinstalación, o la carpeta de siempre
function script:Get-ReproductorExe {
    # con .NET y no con Get-ItemProperty/Test-Path: la portada del gestor lo pregunta cada dos segundos
    $key = $script:ReproductorUninstallKey.Replace('HKCU:\', 'HKEY_CURRENT_USER\')
    $location = [string][Microsoft.Win32.Registry]::GetValue($key, 'InstallLocation', $null)
    if ($location) {
        $exe = Join-Path $location.Trim('"') 'el-reproductor.exe'   # NSIS la guarda entre comillas
        if ([IO.File]::Exists($exe)) { return $exe }
    }
    $exe = Join-Path $env:LOCALAPPDATA 'El Reproductor\el-reproductor.exe'
    if ([IO.File]::Exists($exe)) { return $exe }
}

function script:Get-ReproductorVersion {
    $exe = Get-ReproductorExe
    if ($exe) { ([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion -split '\.')[0..2] -join '.' }   # 0.1.0.0 -> 0.1.0, como la etiqueta
}

function script:Test-ReproductorRunning {
    [Diagnostics.Process]::GetProcessesByName('el-reproductor').Length -gt 0
}

# La última release de la app (etiqueta reproductor-v*): versión y dirección de su instalador
function script:Get-ReproductorLatest {
    $releases = Invoke-RestMethod "https://api.github.com/repos/$script:ReproductorRepo/releases?per_page=30" -UseBasicParsing
    $release = $releases | Where-Object { $_.tag_name -like 'reproductor-v*' -and -not $_.draft } | Select-Object -First 1
    if (-not $release) { throw 'No hay ninguna release de El Reproductor todavía.' }
    $asset = $release.assets | Where-Object { $_.name -like '*setup.exe' } | Select-Object -First 1
    if (-not $asset) { throw "La release $($release.tag_name) no trae instalador." }
    [pscustomobject]@{ Version = $release.tag_name -replace '^reproductor-v', ''; Url = $asset.browser_download_url; Name = $asset.name }
}

# Descarga e instala (o actualiza) la app en silencio, para el usuario actual. Si está abierta la cierra,
# salvo con -KeepOpen (actualización automática o reinstalación de la herramienta): entonces no la toca y falla.
function script:Install-Reproductor([switch]$KeepOpen) {
    $latest = Get-ReproductorLatest
    $current = Get-ReproductorVersion
    # solo hacia arriba: una versión instalada más nueva que la release (una de prueba) se deja como está
    if ($current -and ([version]$current -ge [version]$latest.Version)) { return $false }
    if ($KeepOpen -and (Test-ReproductorRunning)) { throw 'El Reproductor está abierta: se actualizará cuando la cierres.' }
    New-Item -ItemType Directory -Force -Path $script:ReproductorData | Out-Null
    $setup = Join-Path $script:ReproductorData $latest.Name
    Invoke-WebRequest $latest.Url -OutFile $setup -UseBasicParsing
    if (Test-ReproductorRunning) {
        # se ha abierto mientras se descargaba
        if ($KeepOpen) { Remove-Item $setup -ErrorAction SilentlyContinue; throw 'El Reproductor está abierta: se actualizará cuando la cierres.' }
        Get-Process el-reproductor -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    $p = Start-Process $setup -ArgumentList '/S', '/currentuser' -PassThru -Wait
    Remove-Item $setup -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) { throw "El instalador de El Reproductor terminó con el código $($p.ExitCode)." }
    if (-not (Get-ReproductorExe)) { throw 'No se encuentra El Reproductor después de instalarla.' }
    Write-ReproductorLog "El Reproductor $($latest.Version) instalada en $(Get-ReproductorExe)"
    $true
}

function script:Start-Reproductor([string[]]$Files) {
    $exe = Get-ReproductorExe
    if (-not $exe) { throw 'El Reproductor no está instalada.' }
    if ($Files) { Start-Process $exe -ArgumentList ($Files | ForEach-Object { "`"$_`"" }) } else { Start-Process $exe }
}
