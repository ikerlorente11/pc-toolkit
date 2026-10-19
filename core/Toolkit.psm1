# Toolkit.psm1 - Funciones comunes de PC Toolkit (instalador global, gestor y herramientas)
#
# Cada herramienta vive en tools\<id>\ con:
#   tool.json      manifiesto (id, name, description, task, process opcional, log opcional)
#   install.ps1    registra su tarea programada (obligatorio)
#   configure.ps1  ventana de configuracion; devuelve $true si se guardo (opcional)
#   disable.ps1    deja el sistema como estaba al desactivarla (opcional)
# Estado: sin tarea = no instalada; tarea deshabilitada = desactivada; si no, activa.

$ErrorActionPreference = 'Stop'

$Root    = Join-Path $env:LOCALAPPDATA 'PcToolkit'
$AppDir  = Split-Path $PSScriptRoot -Parent
$RepoRaw = 'https://raw.githubusercontent.com/ikerlorente11/pc-toolkit/main'
$RunKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$AppsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PcToolkit'

function Get-ToolkitRoot { $Root }

function Get-ToolkitVersion { (Get-Content (Join-Path $AppDir 'VERSION') -Raw).Trim() }

function Get-ToolkitRemoteVersion {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (Invoke-RestMethod "$RepoRaw/VERSION" -UseBasicParsing).Trim()
}

# Lanza el instalador de GitHub en modo -Update en una consola nueva
function Start-ToolkitUpdate {
    $cmd = "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; " +
           "try { & ([scriptblock]::Create((Invoke-RestMethod '$RepoRaw/install.ps1' -UseBasicParsing))) -Update } " +
           "catch { Write-Host `$_ -ForegroundColor Red; Read-Host 'Pulsa Enter para cerrar' }"
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
}

function Get-ToolDataDir([string]$Id) {
    $dir = Join-Path $Root "data\$Id"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dir
}

function Get-Tools {
    Get-ChildItem (Join-Path $AppDir 'tools') -Directory | ForEach-Object {
        $manifest = Join-Path $_.FullName 'tool.json'
        if (Test-Path $manifest) {
            $tool = Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
            $tool | Add-Member -NotePropertyMembers @{
                Dir          = $_.FullName
                Configurable = Test-Path (Join-Path $_.FullName 'configure.ps1')
            }
            $tool
        }
    }
}

function Get-CurrentUserId { [Security.Principal.WindowsIdentity]::GetCurrent().Name }

# Accion de tarea programada que ejecuta un script de PowerShell sin mostrar ventana
function New-HiddenTaskAction([string]$Script) {
    $vbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
    New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$Script`""
}

function Get-ToolState($Tool) {
    $task = Get-ScheduledTask -TaskName $Tool.task -ErrorAction SilentlyContinue
    if (-not $task)                     { 'NotInstalled' }
    elseif ($task.State -eq 'Disabled') { 'Disabled' }
    else                                { 'Enabled' }
}

function Get-ToolProcess($Tool) {
    if (-not $Tool.process) { return }
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -match $Tool.process }
}

function Stop-ToolProcess($Tool) {
    Get-ToolProcess $Tool | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-ToolLog($Tool) {
    if ($Tool.log) { Join-Path $Root "data\$($Tool.id)\$($Tool.log)" }
}

function Install-Tool($Tool) {
    Stop-ToolProcess $Tool
    & (Join-Path $Tool.Dir 'install.ps1')
    Start-ScheduledTask -TaskName $Tool.task
}

function Enable-Tool($Tool) {
    Enable-ScheduledTask -TaskName $Tool.task | Out-Null
    Start-ScheduledTask -TaskName $Tool.task
}

function Disable-Tool($Tool) {
    Disable-ScheduledTask -TaskName $Tool.task | Out-Null
    Stop-ToolProcess $Tool
    $hook = Join-Path $Tool.Dir 'disable.ps1'
    if (Test-Path $hook) { & $hook }
}

# Quita la tarea y borra su configuracion y log
function Uninstall-Tool($Tool) {
    if (Get-ScheduledTask -TaskName $Tool.task -ErrorAction SilentlyContinue) {
        Disable-Tool $Tool
        Unregister-ScheduledTask -TaskName $Tool.task -Confirm:$false
    }
    $data = Join-Path $Root "data\$($Tool.id)"
    if (Test-Path $data) { Remove-Item $data -Recurse -Force }
}

# Abre la ventana de configuracion; si se guarda y la herramienta esta activa, la reinicia
function Invoke-ToolConfigure($Tool) {
    $saved = & (Join-Path $Tool.Dir 'configure.ps1')
    if ($saved -and (Get-ToolState $Tool) -eq 'Enabled') {
        Stop-ToolProcess $Tool
        Start-ScheduledTask -TaskName $Tool.task
    }
}

# --- Gestor (icono en la bandeja) ---

function Get-ManagerArguments {
    $vbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
    $mgr = Join-Path $AppDir 'manager\PcToolkit.ps1'
    "`"$vbs`" `"$mgr`""
}

function Get-StartMenuShortcut { Join-Path ([Environment]::GetFolderPath('Programs')) 'PC Toolkit.lnk' }

function Test-ManagerAutostart { [bool](Get-ItemProperty $RunKey -Name PcToolkit -ErrorAction SilentlyContinue) }

function Set-ManagerAutostart([bool]$Enabled) {
    if ($Enabled) { Set-ItemProperty $RunKey -Name PcToolkit -Value "wscript.exe $(Get-ManagerArguments)" }
    else          { Remove-ItemProperty $RunKey -Name PcToolkit -ErrorAction SilentlyContinue }
}

function Register-Manager([bool]$Autostart = $true) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Get-StartMenuShortcut))
    $lnk.TargetPath   = 'wscript.exe'
    $lnk.Arguments    = "$(Get-ManagerArguments) -Show"
    $lnk.IconLocation = Join-Path $AppDir 'assets\pc-toolkit.ico'
    $lnk.Description  = 'Gestor de utilidades de PC Toolkit'
    $lnk.Save()
    Set-ManagerAutostart $Autostart

    # Entrada en Configuracion > Aplicaciones para desinstalar como cualquier programa
    $uninstall = Join-Path $AppDir 'uninstall.ps1'
    New-Item $AppsKey -Force | Out-Null
    $strings = @{
        DisplayName     = 'PC Toolkit'
        DisplayVersion  = Get-ToolkitVersion
        Publisher       = 'ikerlorente11'
        DisplayIcon     = Join-Path $AppDir 'assets\pc-toolkit.ico'
        InstallLocation = $Root
        URLInfoAbout    = 'https://github.com/ikerlorente11/pc-toolkit'
        UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstall`""
    }
    foreach ($name in $strings.Keys) { New-ItemProperty $AppsKey -Name $name -Value $strings[$name] -PropertyType String -Force | Out-Null }
    foreach ($name in 'NoModify', 'NoRepair') { New-ItemProperty $AppsKey -Name $name -Value 1 -PropertyType DWord -Force | Out-Null }
}

function Start-Manager([switch]$Show) {
    $arguments = Get-ManagerArguments
    if ($Show) { $arguments += ' -Show' }
    Start-Process wscript.exe -ArgumentList $arguments
}

function Stop-Manager {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -match 'manager\\PcToolkit\.ps1' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Unregister-Manager {
    Stop-Manager
    Set-ManagerAutostart $false
    Remove-Item (Get-StartMenuShortcut) -ErrorAction SilentlyContinue
    Remove-Item $AppsKey -Recurse -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function *
