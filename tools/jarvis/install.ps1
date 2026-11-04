# install.ps1 - Instala Jarvis (lo llaman el instalador global y el gestor). Sin permisos de administrador.
#   1. Python 3.10-3.13 (si no hay, el de python.org para este usuario, con winget)
#   2. Entorno propio con OpenJarvis, Whisper y las voces locales (Piper y Kokoro)
#   3. Ollama y un modelo, si no los hay (el "cerebro", en local)
#   4. Modelo de Whisper descargado y config.toml de OpenJarvis
#   5. Tarea programada que arranca el asistente al iniciar sesión
# La primera vez tarda unos minutos (descargas de varios GB); al actualizar solo cambia lo necesario.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')
. (Join-Path $PSScriptRoot 'common.ps1')

New-Item -ItemType Directory -Force -Path $script:JarvisData | Out-Null
$LogFile = Join-Path $script:JarvisData 'Jarvis.log'
function Write-Log($msg) { Add-Content -Path $LogFile -Value ("{0}  [instalación] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 }

# Ejecuta un programa y falla con su salida si no termina bien
function Invoke-Native([string]$Exe, [string[]]$Arguments, [string]$What) {
    $out = & { $ErrorActionPreference = 'Continue'; & $Exe @Arguments 2>&1 } | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "$What falló:`n$out"
        throw "$What falló (código $LASTEXITCODE). Detalles en el registro de Jarvis."
    }
}

function Update-PathFromRegistry {
    $env:Path = [Environment]::ExpandEnvironmentVariables(
        [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User'))
}

# Un python.exe real de 3.10 a 3.13 (OpenJarvis aún no va con 3.14; se ignora el acceso directo de la Store)
function Find-Python {
    $candidates = @()
    $py = (Get-Command py -ErrorAction SilentlyContinue).Source
    if ($py) {
        foreach ($v in '3.13', '3.12', '3.11', '3.10') {
            $exe = & { $ErrorActionPreference = 'Continue'; & $py "-$v" -c 'import sys; print(sys.executable)' 2>$null }
            if ($LASTEXITCODE -eq 0 -and $exe) { $candidates += [string]$exe }
        }
    }
    $candidates += @(Get-Command python, python3 -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source)
    $candidates += @(Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python31[0-3]\python.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName)
    foreach ($exe in ($candidates | Where-Object { $_ -and $_ -notmatch 'WindowsApps' } | Select-Object -Unique)) {
        $v = & { $ErrorActionPreference = 'Continue'; & $exe -c 'import sys; print(*sys.version_info[:2], sep=chr(46))' 2>$null }
        if ($LASTEXITCODE -eq 0 -and $v -match '^3\.1[0-3]$') { return $exe }
    }
}

# 0. Parar el asistente para poder tocar su entorno
Stop-JarvisAssistant

# 1. Python
$python = Find-Python
if (-not $python) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'Hace falta Python 3.13 (python.org) y no hay winget para instalarlo solo.' }
    Write-Log 'Instalando Python 3.13 para este usuario...'
    Invoke-Native 'winget' @('install', '--id', 'Python.Python.3.13', '--scope', 'user', '--silent', '--accept-source-agreements', '--accept-package-agreements') 'Instalar Python'
    Update-PathFromRegistry
    $python = Find-Python
    if (-not $python) { throw 'Python se ha instalado pero no se encuentra. Prueba a instalar Jarvis otra vez.' }
}
Write-Log "Python: $python"

# 2. Entorno con OpenJarvis, voces locales y, con gráfica NVIDIA, CUDA para Whisper
#    (se rehace si cambia algo de lo fijado o si el entorno está roto)
$nvidia   = [bool](Get-CimInstance Win32_VideoController | Where-Object Name -match 'NVIDIA')
$packages = @($script:OpenJarvisSpec) + $script:JarvisPipExtras + $(if ($nvidia) { $script:JarvisPipCuda })
$wanted   = $packages -join ' '
$marker   = Join-Path $script:JarvisVenv 'pctoolkit-packages.txt'
$current  = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() }
$healthy  = $false
if (Test-Path $script:JarvisPython) {
    & { $ErrorActionPreference = 'Continue'; & $script:JarvisPython -c 'import openjarvis.speech.elevenlabs_tts, faster_whisper, sounddevice, piper, kokoro_onnx' 2>$null }
    $healthy = $LASTEXITCODE -eq 0
}
if (-not $healthy -or $current -ne $wanted) {
    if (-not (Test-Path $script:JarvisPython)) {
        Write-Log 'Creando el entorno de Python...'
        Invoke-Native $python @('-m', 'venv', $script:JarvisVenv) 'Crear el entorno de Python'
    }
    Write-Log "Instalando OpenJarvis ($($script:OpenJarvisRef.Substring(0, 7))) y las voces locales$(if ($nvidia) { ', con CUDA para la gráfica NVIDIA' })..."
    Invoke-Native $script:JarvisPython @('-m', 'pip', 'install', '--disable-pip-version-check', '-q', '--upgrade', 'pip') 'Actualizar pip'
    Invoke-Native $script:JarvisPython (@('-m', 'pip', 'install', '--disable-pip-version-check', '-q') + $packages) 'Instalar OpenJarvis'
    Set-Content $marker $wanted -Encoding ASCII
    Write-Log 'Entorno listo'
}

# 2b. Modelos de las voces locales (unos 470 MB la primera vez)
$ProgressPreference = 'SilentlyContinue'   # en PowerShell 5.1 la barra hace las descargas 30 veces más lentas
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
foreach ($f in $script:JarvisVoiceFiles) {
    $dest = Join-Path $script:JarvisData "voices\$($f.Path)"
    if (Test-Path $dest) { continue }
    Write-Log "Descargando la voz $(Split-Path $f.Path -Leaf)..."
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Invoke-WebRequest $f.Url -OutFile "$dest.part" -UseBasicParsing
    Move-Item "$dest.part" $dest -Force
}

# 3. Ollama (instalador oficial, para este usuario) y un modelo si no hay ninguno
if (-not (Get-OllamaExe)) {
    Write-Log 'Instalando Ollama...'
    $setup = Join-Path $env:TEMP 'OllamaSetup.exe'
    Invoke-WebRequest 'https://ollama.com/download/OllamaSetup.exe' -OutFile $setup -UseBasicParsing
    Start-Process $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-' -Wait
    Remove-Item $setup -ErrorAction SilentlyContinue
    Update-PathFromRegistry
    if (-not (Get-OllamaExe)) { throw 'No se ha podido instalar Ollama. Instálalo desde ollama.com y vuelve a instalar Jarvis.' }
}
if (Start-Ollama) {
    if (-not (Get-OllamaModels)) {
        Write-Log 'Descargando el modelo qwen3:8b (unos 5 GB)...'
        Invoke-Native (Get-OllamaExe) @('pull', 'qwen3:8b') 'Descargar el modelo qwen3:8b'
    }
} else {
    Write-Log 'Ollama no arranca: el modelo se elegirá cuando esté en marcha'
}

# 4. Configuración de OpenJarvis y modelo de Whisper (para que la primera pregunta no tarde)
$cfg = Get-JarvisConfig
Save-JarvisConfig $cfg
Set-JarvisEnvironment
$whisper = "from faster_whisper import WhisperModel; WhisperModel('$($cfg.SttModel)', device='cpu', compute_type='int8')"
Invoke-Native $script:JarvisPython @('-c', $whisper) 'Descargar el modelo de Whisper'

# 5. Tarea programada: lanza el asistente oculto al iniciar sesión
$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'Jarvis.ps1')
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User (Get-CurrentUserId)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName 'PcToolkitJarvis' -Action $action -Trigger $trigger -Settings $settings `
    -Description 'PC Toolkit: asistente de voz Jarvis (OpenJarvis + ElevenLabs)' -Force | Out-Null
Write-Log 'Instalación terminada'
