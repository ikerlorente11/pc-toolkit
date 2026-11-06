# common.ps1 - Dónde está LocalSend, su estado, el acceso de "Enviar a" y la configuración de la herramienta.
# Lo cargan con "." install.ps1, LocalSend.ps1 (la tarea), disable.ps1 y, dentro del gestor, settings.ps1
# y home.ps1. Funciones "script:" para que sigan vivas en los botones del gestor.

$script:LocalSendDir  = $PSScriptRoot
$script:LocalSendData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\localsend'
$script:LocalSendProductCode = '{00809252-FEC6-448E-83B4-E7F55AE7E47D}_is1'   # instalador oficial (Inno Setup)

# localsend_app.exe instalado (o $null): para el usuario (lo que instala winget), para todos, lo que diga
# el registro de desinstalación o el proceso en marcha
function script:Get-LocalSendExe {
    $dirs = @((Join-Path $env:LOCALAPPDATA 'Programs'), $env:ProgramFiles) | Where-Object { $_ }
    foreach ($d in $dirs) {
        $exe = Join-Path $d 'LocalSend\localsend_app.exe'
        if (Test-Path $exe) { return $exe }
    }
    foreach ($hive in 'HKCU', 'HKLM') {
        $e = Get-ItemProperty "$($hive):\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$script:LocalSendProductCode" -ErrorAction SilentlyContinue
        if ($e.InstallLocation) {
            $exe = Join-Path $e.InstallLocation 'localsend_app.exe'
            if (Test-Path $exe) { return $exe }
        }
    }
    Get-Process localsend_app -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1 -ExpandProperty Path
}

function script:Test-LocalSendRunning {
    $session = (Get-Process -Id $PID).SessionId
    [bool](Get-Process localsend_app -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session)
}

# Nombre con el que los demás dispositivos ven este PC (lo elige LocalSend; se cambia en su ventana)
function script:Get-LocalSendAlias {
    $files = @((Join-Path $env:APPDATA 'LocalSend\settings.json'),
               (Join-Path $env:APPDATA 'org.localsend\localsend_app\shared_preferences.json'))
    $exe = Get-LocalSendExe
    if ($exe) { $files = @((Join-Path (Split-Path $exe) 'settings.json')) + $files }   # versión portable
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { continue }
        try {
            $alias = (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json).'flutter.ls_alias'
            if ($alias) { return [string]$alias }
        } catch {}
    }
}

# Abre LocalSend. Con archivos, va directo a enviarlos (si ya está abierto, se los pasa a esa ventana).
function script:Start-LocalSend([string[]]$Files, [switch]$Hidden) {
    $exe = Get-LocalSendExe
    if (-not $exe) { throw 'LocalSend no está instalado.' }
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.WorkingDirectory = Split-Path $exe
    # Entre comillas y con las barras finales dobladas (una "\" antes de la comilla la escaparía)
    $argv = @($Files | Where-Object { $_ } | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' })
    if ($Hidden) { $argv = @('--hidden') + $argv }
    $psi.Arguments = $argv -join ' '
    [void][Diagnostics.Process]::Start($psi)
}

# Elegir archivos (diálogo de Windows) y abrir LocalSend con ellos listos para enviar. Solo en el gestor.
function script:Invoke-LocalSendPick {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Title = 'Elige los archivos que quieres enviar con LocalSend'
    if ($dlg.ShowDialog()) { Start-LocalSend $dlg.FileNames }
}

function script:Write-LocalSendLog($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $script:LocalSendData | Out-Null
        $log = Join-Path $script:LocalSendData 'LocalSend.log'
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Clear-Content $log }
        Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

function script:Get-LocalSendConfig {
    $path = Join-Path $script:LocalSendData 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    @{ SendTo = if ($null -ne $c.SendTo) { [bool]$c.SendTo } else { $true } }
}

function script:Set-LocalSendSetting([string]$Name, $Value) {
    $cfg = Get-LocalSendConfig
    $cfg[$Name] = $Value
    New-Item -ItemType Directory -Force -Path $script:LocalSendData | Out-Null
    $cfg | ConvertTo-Json | Set-Content (Join-Path $script:LocalSendData 'config.json') -Encoding UTF8
}

# "LocalSend" en el menú Enviar a del Explorador. Es el mismo acceso directo que crea la opción "Menú
# contextual" de LocalSend, así que las dos opciones no se pisan.
function script:Get-LocalSendSendToPath { Join-Path ([Environment]::GetFolderPath('SendTo')) 'LocalSend.lnk' }

function script:Set-LocalSendSendTo([bool]$Enabled) {
    $lnkPath = Get-LocalSendSendToPath
    if (-not $Enabled) { Remove-Item $lnkPath -Force -ErrorAction SilentlyContinue; return }
    $exe = Get-LocalSendExe
    if (-not $exe) { return }
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
    $lnk.TargetPath       = $exe
    $lnk.WorkingDirectory = Split-Path $exe
    $lnk.Description      = 'Enviar con LocalSend a un dispositivo de la red local'
    $lnk.Save()
}
