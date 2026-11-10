# common.ps1 - Dónde está la app La Estantería, su versión y cómo descargarla. Lo cargan con "." install.ps1,
# disable.ps1, hotkey.ps1 y, dentro del gestor, home.ps1. Funciones "script:" para que sigan vivas en los botones.
#
# La app es la de tools\estanteria\app (Tauri): el CI de PC Toolkit la compila en Windows y publica su instalador
# NSIS en las releases del repo con etiqueta "estanteria-v<versión>". Se instala para el usuario actual, en
# %LOCALAPPDATA%\La Estantería.

$script:EstanteriaDir  = $PSScriptRoot
$script:EstanteriaData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\estanteria'
$script:EstanteriaRepo = 'ikerlorente11/pc-toolkit'
$script:EstanteriaUninstallKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\La Estantería'

function script:Write-EstanteriaLog([string]$Text) {
    New-Item -ItemType Directory -Force -Path $script:EstanteriaData | Out-Null
    Add-Content (Join-Path $script:EstanteriaData 'Estanteria.log') "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
}

# la-estanteria.exe instalado (o $null): lo que diga el registro de desinstalación, o la carpeta de siempre
function script:Get-EstanteriaExe {
    $e = Get-ItemProperty $script:EstanteriaUninstallKey -ErrorAction SilentlyContinue
    if ($e.InstallLocation) {
        $exe = Join-Path $e.InstallLocation.Trim('"') 'la-estanteria.exe'   # NSIS la guarda entre comillas
        if (Test-Path $exe) { return $exe }
    }
    $exe = Join-Path $env:LOCALAPPDATA 'La Estantería\la-estanteria.exe'
    if (Test-Path $exe) { return $exe }
}

function script:Get-EstanteriaVersion {
    $exe = Get-EstanteriaExe
    if ($exe) { ((Get-Item $exe).VersionInfo.ProductVersion -split '\.')[0..2] -join '.' }   # 0.1.0.0 -> 0.1.0, como la etiqueta
}

function script:Test-EstanteriaRunning {
    [bool](Get-Process la-estanteria -ErrorAction SilentlyContinue)
}

# La última release de la app (etiqueta estanteria-v*): versión y dirección de su instalador
function script:Get-EstanteriaLatest {
    $releases = Invoke-RestMethod "https://api.github.com/repos/$script:EstanteriaRepo/releases?per_page=30" -UseBasicParsing
    $release = $releases | Where-Object { $_.tag_name -like 'estanteria-v*' -and -not $_.draft } | Select-Object -First 1
    if (-not $release) { throw 'No hay ninguna release de La Estantería todavía.' }
    $asset = $release.assets | Where-Object { $_.name -like '*setup.exe' } | Select-Object -First 1
    if (-not $asset) { throw "La release $($release.tag_name) no trae instalador." }
    [pscustomobject]@{ Version = $release.tag_name -replace '^estanteria-v', ''; Url = $asset.browser_download_url; Name = $asset.name }
}

# Descarga e instala (o actualiza) la app en silencio, para el usuario actual
function script:Install-Estanteria {
    $latest = Get-EstanteriaLatest
    $current = Get-EstanteriaVersion
    # solo hacia arriba: una versión instalada más nueva que la release (una de prueba) se deja como está
    if ($current -and ([version]$current -ge [version]$latest.Version)) { return $false }
    New-Item -ItemType Directory -Force -Path $script:EstanteriaData | Out-Null
    $setup = Join-Path $script:EstanteriaData $latest.Name
    Invoke-WebRequest $latest.Url -OutFile $setup -UseBasicParsing
    if (Test-EstanteriaRunning) { Get-Process la-estanteria -ErrorAction SilentlyContinue | Stop-Process -Force }
    $p = Start-Process $setup -ArgumentList '/S', '/currentuser' -PassThru -Wait
    Remove-Item $setup -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) { throw "El instalador de La Estantería terminó con el código $($p.ExitCode)." }
    if (-not (Get-EstanteriaExe)) { throw 'No se encuentra La Estantería después de instalarla.' }
    Write-EstanteriaLog "La Estantería $($latest.Version) instalada en $(Get-EstanteriaExe)"
    $true
}

function script:Start-Estanteria([string[]]$Files) {
    $exe = Get-EstanteriaExe
    if (-not $exe) { throw 'La Estantería no está instalada.' }
    if ($Files) { Start-Process $exe -ArgumentList ($Files | ForEach-Object { "`"$_`"" }) } else { Start-Process $exe }
}
