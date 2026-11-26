# Toolkit.psm1 - Funciones comunes de PC Toolkit (instalador global, gestor y herramientas)
#
# Cada herramienta vive en tools\<id>\ con:
#   tool.json      manifiesto (id, name, description, task, process opcional, log opcional, installNote
#                  opcional: aviso junto al boton Instalar si no es "para el usuario, sin admin")
#   install.ps1    registra su tarea programada (obligatorio)
#   settings.ps1   pagina de ajustes dentro del gestor (opcional; ver manager\PcToolkit.ps1)
#   home.ps1       bloque dentro de su tarjeta en la portada del gestor (opcional)
#   disable.ps1    deja el sistema como estaba al desactivarla (opcional)
#   uninstall.ps1  limpieza extra al desinstalarla, antes de borrar su tarea y sus datos (opcional)
#   update.ps1     actualizaciones de la app que instala (opcional; con "updates": true en tool.json).
#                  Recibe -Action:
#                    info     -> @{ Installed = '0.5.0' o $null; InUse = <abierta: actualizar obligaria a
#                                cerrarla>; Elevated = <actualizar pide permisos de administrador> } (local, rapido)
#                    latest   -> ultima version publicada (consulta la red)
#                    update   -> la actualiza y devuelve la version instalada. Con -Auto nunca cierra la app
#                                abierta (lanza un error) y no pide permisos de administrador.
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

# Lanza el instalador de GitHub en modo -Update, sin ventana (al terminar vuelve a abrir el gestor).
# -NoShow: el gestor vuelve solo a la bandeja, sin abrir el panel (actualizacion automatica). Solo se
# pasa si el install.ps1 descargado ya lo admite.
function Start-ToolkitUpdate([switch]$NoShow) {
    $log = Join-Path $Root 'update.log'
    $quiet = if ($NoShow) { '$true' } else { '$false' }
    $cmd = "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; " +
           "try { `$s = Invoke-RestMethod '$RepoRaw/install.ps1' -UseBasicParsing; `$a = @{ Update = `$true }; " +
           "if ($quiet -and `$s -match 'switch\]\`$NoShow') { `$a.NoShow = `$true }; " +
           "& ([scriptblock]::Create(`$s)) @a *> '$log' } " +
           "catch { `$_ | Out-File '$log' -Append }"
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
}

# --- Actualizaciones de las apps de las herramientas (update.ps1, ver arriba) ---

# "1.18.2+64", "v0.5.1" o "1.4.1.1032" -> [version] (o $null si no se entiende)
function ConvertTo-AppVersion([string]$Text) {
    if ($Text -match '(\d+(\.\d+){1,3})') { [version]$Matches[1] }
}

# $true si $Latest es mas nueva que $Installed (si falta alguna de las dos, $false)
function Test-NewerVersion([string]$Latest, [string]$Installed) {
    $l = ConvertTo-AppVersion $Latest
    $i = ConvertTo-AppVersion $Installed
    [bool]($l -and $i -and $l -gt $i)
}

function Get-ToolAppInfo($Tool)   { & (Join-Path $Tool.Dir 'update.ps1') -Action info }
function Get-ToolAppLatest($Tool) { [string](& (Join-Path $Tool.Dir 'update.ps1') -Action latest) }
function Update-ToolApp($Tool, [switch]$Auto) { [string](@(& (Join-Path $Tool.Dir 'update.ps1') -Action update -Auto:$Auto)[-1]) }

# Carga un tipo de C# compilandolo solo la primera vez: la DLL se guarda en %LOCALAPPDATA%\PcToolkit\cache con
# el hash del codigo en el nombre (si el codigo cambia, se compila otra). Compilar con Add-Type cuesta de 150 a
# 500 ms por archivo en cada arranque; cargar la DLL, unos pocos. Si algo falla, se compila como siempre.
function Import-ToolkitType {
    param(
        [Parameter(Mandatory)][string]$TypeName,
        [string]$Path,
        [string]$Source,
        [string[]]$ReferencedAssemblies = @()
    )
    if ($TypeName -as [type]) { return }
    if ($Path) { $Source = [IO.File]::ReadAllText($Path) }
    $refs = @($ReferencedAssemblies | Where-Object { $_ })
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        $bytes = [Text.Encoding]::UTF8.GetBytes("$Source|$($refs -join '|')|$($PSVersionTable.CLRVersion)")
        $hash = -join ($sha.ComputeHash($bytes)[0..7] | ForEach-Object { $_.ToString('x2') })
        # Con .NET y no con cmdlets (Test-Path, Add-Type -Path...): en un proceso recien abierto, el primer uso de
        # cada cmdlet cuesta mas que cargar la DLL
        $dir = Join-Path $Root 'cache'
        $base = $TypeName -replace '[^\w]', '-'
        $dll = Join-Path $dir "$base-$hash.dll"
        if (-not [IO.File]::Exists($dll)) {
            [void][IO.Directory]::CreateDirectory($dir)
            # Se compila con otro nombre y se renombra: otro proceso puede estar compilando el mismo a la vez
            $tmp = Join-Path $dir "$base-$hash-$PID.dll"
            $p = @{ TypeDefinition = $Source; OutputAssembly = $tmp; OutputType = 'Library' }
            if ($refs) { $p.ReferencedAssemblies = $refs }
            Add-Type @p
            try { [IO.File]::Move($tmp, $dll) } catch { try { [IO.File]::Delete($tmp) } catch {} }
            # Las de versiones anteriores del mismo tipo
            foreach ($old in [IO.Directory]::GetFiles($dir, "$base-*.dll")) {
                if ($old -ne $dll) { try { [IO.File]::Delete($old) } catch {} }
            }
        }
        # Desde memoria: el archivo no queda bloqueado (se puede desinstalar o limpiar la cache con procesos abiertos)
        [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
        if (-not ($TypeName -as [type])) { throw "La DLL $dll no tiene el tipo $TypeName." }
    } catch {
        if ($TypeName -as [type]) { return }
        $p = @{ TypeDefinition = $Source }
        if ($refs) { $p.ReferencedAssemblies = $refs }
        Add-Type @p
    }
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
                HasSettings  = Test-Path (Join-Path $_.FullName 'settings.ps1')
                HasHome      = Test-Path (Join-Path $_.FullName 'home.ps1')
                HasUpdates   = [bool]$tool.updates -and (Test-Path (Join-Path $_.FullName 'update.ps1'))
            }
            $tool
        }
    }
}

function Get-CurrentUserId { [Security.Principal.WindowsIdentity]::GetCurrent().Name }

# Texto de progreso de una instalacion: en el gestor sale bajo la herramienta (tool-action.ps1 deja la
# ruta en PCTOOLKIT_STATUS); en el instalador global, en la consola
function Set-ToolStatus([string]$Text) {
    if ($env:PCTOOLKIT_STATUS) { Set-Content -Path $env:PCTOOLKIT_STATUS -Value $Text -Encoding UTF8 }
    else { Write-Host "  $Text" }
}

# Instala un programa de otro fabricante con winget. -Elevated: lo lanza como administrador, asi que
# Windows muestra el aviso de permisos (UAC) y el usuario decide; si lo rechaza, se cancela.
# -Upgrade: actualiza el que ya esta instalado ("winget upgrade"); si winget aun no tiene una version
# nueva, no hace nada (quien lo llama compara la version antes y despues).
function Install-WingetPackage([string]$Id, [string[]]$Arguments = @(), [switch]$Elevated, [switch]$Upgrade) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'Falta winget (el Instalador de aplicacion de Microsoft Store). Instalalo y vuelve a intentarlo.' }
    $verb = if ($Upgrade) { 'upgrade' } else { 'install' }
    $argv = @($verb, '--id', $Id, '--exact', '--source', 'winget', '--silent', '--disable-interactivity',
              '--accept-package-agreements', '--accept-source-agreements') + $Arguments
    if ($Elevated) {
        try { $p = Start-Process $winget.Source -ArgumentList $argv -Verb RunAs -WindowStyle Hidden -Wait -PassThru }
        catch { throw 'Instalacion cancelada: no se concedieron permisos de administrador.' }
    } else {
        $p = Start-Process $winget.Source -ArgumentList $argv -WindowStyle Hidden -Wait -PassThru
    }
    # 0x8A150061: ya estaba instalado; 0x8A15002B: no hay nada que actualizar
    if ($p.ExitCode -notin 0, -1978335135, -1978335189) {
        throw ('winget no pudo instalar {0} (codigo 0x{1:X8}).' -f $Id, $p.ExitCode)
    }
}

# Accion de tarea programada que ejecuta un script de PowerShell sin mostrar ventana
function New-HiddenTaskAction([string]$Script) {
    $vbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
    New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$Script`""
}

# Tarea de la herramienta por COM del Programador de tareas (o $null si no existe): mucho mas rapido que
# Get-ScheduledTask, que ademas tiene que cargar su modulo (casi un segundo la primera vez)
function Get-TaskFolder {
    if (-not $script:taskFolder) {
        $scheduler = New-Object -ComObject Schedule.Service
        $scheduler.Connect()
        $script:taskFolder = $scheduler.GetFolder('\')
    }
    $script:taskFolder
}

function Get-ToolTask($Tool) {
    for ($try = 0; $try -lt 2; $try++) {
        try { return (Get-TaskFolder).GetTask($Tool.task) }
        catch {
            if ($_.Exception.HResult -eq -2147024894) { return $null }   # 0x80070002: no existe
            $script:taskFolder = $null   # conexion perdida (p. ej., se reinicio el servicio): se reconecta
        }
    }
    $null
}

function Get-ToolState($Tool) {
    $task = Get-ToolTask $Tool
    if (-not $task) { 'NotInstalled' } elseif ($task.Enabled) { 'Enabled' } else { 'Disabled' }
}

# Estado de varias herramientas (id -> estado) con una sola consulta: mas rapido que Get-ToolState con cada una,
# sobre todo con las no instaladas (cada una es una excepcion)
function Get-ToolStates($Tools) {
    $enabled = @{}   # tarea -> activada (las claves no distinguen mayusculas, como los nombres de tarea)
    for ($try = 0; $try -lt 2; $try++) {
        try { foreach ($t in (Get-TaskFolder).GetTasks(1)) { $enabled[$t.Name] = [bool]$t.Enabled }; break }   # 1: tambien las ocultas
        catch { $enabled = @{}; $script:taskFolder = $null }
    }
    $states = @{}
    foreach ($t in $Tools) {
        $states[$t.id] = if (-not $enabled.ContainsKey($t.task)) { 'NotInstalled' } elseif ($enabled[$t.task]) { 'Enabled' } else { 'Disabled' }
    }
    $states
}

# Si hay algun proceso con ese nombre (sin .exe); con -ThisSession, en la sesion de este proceso. La lista de
# procesos se toma como mucho una vez por segundo: las firmas del gestor preguntan por varios programas seguidos
# y cada vuelta a todos los procesos del sistema cuesta ~10 ms
function Test-ProcessRunning([string]$Name, [switch]$ThisSession) {
    $now = [DateTime]::UtcNow
    if (-not $script:procSnapshot -or ($now - $script:procSnapshot.At).TotalMilliseconds -gt 1000) {
        $names = @{}
        foreach ($p in [Diagnostics.Process]::GetProcesses()) {
            $sessions = $names[$p.ProcessName]
            if (-not $sessions) { $sessions = $names[$p.ProcessName] = New-Object Collections.Generic.List[int] }
            $sessions.Add($p.SessionId)
            $p.Dispose()
        }
        if ($null -eq $script:mySession) { $script:mySession = [Diagnostics.Process]::GetCurrentProcess().SessionId }
        $script:procSnapshot = @{ At = $now; Names = $names }
    }
    $sessions = $script:procSnapshot.Names[$Name]
    if (-not $sessions) { return $false }
    if (-not $ThisSession) { return $true }
    $sessions.Contains($script:mySession)
}

# Ejecuta install/uninstall/enable/disable en otro proceso para no bloquear el gestor.
# Devuelve el proceso y el archivo donde va escribiendo el progreso.
# update: actualiza la app de la herramienta (update.ps1); autoupdate: lo mismo sin cerrar la app ni pedir
# permisos de administrador (si esta abierta, sale con el codigo 2 para reintentarlo mas tarde).
function Start-ToolAction($Tool, [ValidateSet('install', 'uninstall', 'enable', 'disable', 'update', 'autoupdate')][string]$Action) {
    $status = Join-Path $env:TEMP "pctoolkit-$($Tool.id)-$Action-$([guid]::NewGuid().ToString('N')).txt"
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'tool-action.ps1')`" " +
                     "-Action $Action -Id $($Tool.id) -StatusFile `"$status`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    [pscustomobject]@{ Process = [Diagnostics.Process]::Start($psi); StatusFile = $status; Action = $Action }
}

# Procesos powershell.exe en marcha con su linea de comandos: @{ ProcessId; CommandLine }. Preguntarlo a WMI
# cuesta 100-200 ms, asi que solo se hace cuando cambia la lista de powershell.exe (mirarla cuesta ~1 ms)
function Get-PowerShellProcesses {
    $procs = [Diagnostics.Process]::GetProcessesByName('powershell')
    $key = (@($procs | ForEach-Object {
        $start = try { $_.StartTime.Ticks } catch { 0 }   # por si se reutiliza un PID
        "$($_.Id):$start"
    }) | Sort-Object) -join ','
    foreach ($p in $procs) { $p.Dispose() }
    if ($script:psProcKey -ne $key) {
        $script:psProcList = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -Property ProcessId, CommandLine |
            ForEach-Object { [pscustomobject]@{ ProcessId = $_.ProcessId; CommandLine = $_.CommandLine } })
        $script:psProcKey = $key
    }
    $script:psProcList
}

function Get-ToolProcess($Tool) {
    if (-not $Tool.process) { return }
    $pattern = $Tool.process
    Get-PowerShellProcesses | Where-Object { $_.CommandLine -match $pattern }
}

function Stop-ToolProcess($Tool) {
    Get-ToolProcess $Tool | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-ToolLog($Tool) {
    if ($Tool.log) { Join-Path $Root "data\$($Tool.id)\$($Tool.log)" }
}

# -Disabled: la deja instalada pero desactivada sin llegar a lanzarla (al actualizar una que estaba
# desactivada; si se lanzara, su tarea podria terminar despues de disable.ps1 y deshacerlo)
function Install-Tool($Tool, [switch]$Disabled) {
    Stop-ToolProcess $Tool
    & (Join-Path $Tool.Dir 'install.ps1')
    if ($Disabled) { Disable-Tool $Tool } else { Start-ScheduledTask -TaskName $Tool.task }
}

# Activar y desactivar van por COM (Get-ToolTask): con Enable-/Disable-ScheduledTask, cargar su modulo
# hacia que el interruptor tardara un par de segundos en responder
function Enable-Tool($Tool) {
    $task = Get-ToolTask $Tool
    if (-not $task) { throw "No se encuentra la tarea programada $($Tool.task)." }
    $task.Enabled = $true
    [void]$task.Run($null)
}

function Disable-Tool($Tool) {
    $task = Get-ToolTask $Tool
    if (-not $task) { throw "No se encuentra la tarea programada $($Tool.task)." }
    $task.Enabled = $false
    Stop-ToolProcess $Tool
    $hook = Join-Path $Tool.Dir 'disable.ps1'
    if (Test-Path $hook) { & $hook }
}

# Quita la tarea y borra su configuracion y log
function Uninstall-Tool($Tool) {
    if (Get-ToolTask $Tool) {
        Disable-Tool $Tool
        $hook = Join-Path $Tool.Dir 'uninstall.ps1'
        if (Test-Path $hook) { & $hook }
        $script:taskFolder.DeleteTask($Tool.task, 0)
    }
    $data = Join-Path $Root "data\$($Tool.id)"
    if (Test-Path $data) { Remove-Item $data -Recurse -Force }
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
