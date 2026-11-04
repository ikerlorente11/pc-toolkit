# common.ps1 - Funciones compartidas de Jarvis (install, lanzador, settings, home, atajo y chat).
# Se cargan con "."; las funciones son "script:" para que sigan vivas en los botones del gestor.

$script:JarvisDir    = $PSScriptRoot
$script:JarvisData   = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\jarvis'
$script:JarvisVenv   = Join-Path $script:JarvisData 'venv'
$script:JarvisHome   = Join-Path $script:JarvisData 'openjarvis'   # OPENJARVIS_HOME (config.toml, memoria...)
$script:JarvisPython = Join-Path $script:JarvisVenv 'Scripts\python.exe'
$script:JarvisPythonW = Join-Path $script:JarvisVenv 'Scripts\pythonw.exe'

# OpenJarvis fijado a un commit de GitHub: la versión de PyPI aún no trae la voz de ElevenLabs.
# Se instala desde el .zip (no hace falta git) y sin la extensión de Rust (no hace falta Visual Studio).
$script:OpenJarvisRef  = '324c9c3ac61bff07a0d99b715a7511dcd78600c4'
$script:OpenJarvisSpec = "openjarvis[speech] @ https://github.com/open-jarvis/OpenJarvis/archive/$script:OpenJarvisRef.zip"

# Paquetes extra del entorno: voces locales y, con gráfica NVIDIA, CUDA para Whisper (sin instalar CUDA)
$script:JarvisPipExtras = @('piper-tts==1.8.0', 'kokoro-onnx==0.6.1')
$script:JarvisPipCuda   = @('nvidia-cublas-cu12==12.9.2.10', 'nvidia-cudnn-cu12==9.28.0.42')

# Voces locales: gratis, sin internet y en castellano (los modelos los descarga install.ps1)
$script:DefaultJarvisVoice = 'piper:es_ES-davefx-medium'
$script:JarvisLocalVoices = [ordered]@{
    'piper:es_ES-davefx-medium'     = @{ Name = 'Dave';     Detail = 'Hombre, acento de España. Clara y rápida (Piper).' }
    'piper:es_ES-sharvard-medium#1' = @{ Name = 'Sharvard'; Detail = 'Mujer, acento de España (Piper).' }
    'piper:es_ES-sharvard-medium#0' = @{ Name = 'Sharvard (hombre)'; Detail = 'Hombre, acento de España (Piper).' }
    'kokoro:ef_dora'                = @{ Name = 'Dora';     Detail = 'Mujer, más expresiva (Kokoro).' }
    'kokoro:em_alex'                = @{ Name = 'Alex';     Detail = 'Hombre, más expresiva (Kokoro).' }
}
$jarvisPiperBase = 'https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES'
$jarvisKokoroBase = 'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0'
$script:JarvisVoiceFiles = @(
    @{ Path = 'piper\es_ES-davefx-medium.onnx';        Url = "$jarvisPiperBase/davefx/medium/es_ES-davefx-medium.onnx" }
    @{ Path = 'piper\es_ES-davefx-medium.onnx.json';   Url = "$jarvisPiperBase/davefx/medium/es_ES-davefx-medium.onnx.json" }
    @{ Path = 'piper\es_ES-sharvard-medium.onnx';      Url = "$jarvisPiperBase/sharvard/medium/es_ES-sharvard-medium.onnx" }
    @{ Path = 'piper\es_ES-sharvard-medium.onnx.json'; Url = "$jarvisPiperBase/sharvard/medium/es_ES-sharvard-medium.onnx.json" }
    @{ Path = 'kokoro\kokoro-v1.0.onnx';               Url = "$jarvisKokoroBase/kokoro-v1.0.onnx" }
    @{ Path = 'kokoro\voices-v1.0.bin';                Url = "$jarvisKokoroBase/voices-v1.0.bin" }
)

function script:Test-LocalVoice([string]$Voice) { $Voice -match '^(piper|kokoro):' }

# Voces de ElevenLabs que salen en el panel (cualquier otra se puede poner por su ID o enlace)
$script:JarvisVoices = [ordered]@{
    'gD1IexrzCvsXPHUuT0s3' = @{ Name = 'Sara Martin'; Detail = 'Castellano, joven y natural. De la biblioteca: necesita un plan de pago.' }
    'onwK4e9ZLuTAKqWW03F9' = @{ Name = 'Daniel';      Detail = 'Locutor británico y formal, el JARVIS de las películas.' }
    'JBFqnCBsd6RMkjVDRZzb' = @{ Name = 'George';      Detail = 'Británico, cálido y narrador.' }
    'nPczCjzI2devNBz1zQrb' = @{ Name = 'Brian';       Detail = 'Grave, resonante y tranquila.' }
    'pFZP5JQG7iQjIQuC4Bku' = @{ Name = 'Lily';        Detail = 'Británica y aterciopelada, al estilo FRIDAY.' }
}
$script:JarvisTtsModels = [ordered]@{
    'eleven_multilingual_v2' = @{ Name = 'Multilingüe v2'; Detail = 'La más natural en castellano.' }
    'eleven_flash_v2_5'      = @{ Name = 'Flash v2.5';     Detail = 'Responde antes y gasta la mitad de créditos.' }
}

function script:Get-JarvisConfig {
    $path = Join-Path $script:JarvisData 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    [ordered]@{
        Voice    = if ($c.Voice) { [string]$c.Voice } else { $script:DefaultJarvisVoice }
        TtsModel = if ($script:JarvisTtsModels.Contains([string]$c.TtsModel)) { [string]$c.TtsModel } else { 'eleven_multilingual_v2' }
        Model    = [string]$c.Model      # modelo de Ollama; vacío = el primero instalado
        ApiKey   = [string]$c.ApiKey     # cifrada con DPAPI (solo la lee este usuario en este PC)
        SttModel = if ($c.SttModel) { [string]$c.SttModel } else { 'small' }
    }
}

function script:Save-JarvisConfig($Config) {
    New-Item -ItemType Directory -Force -Path $script:JarvisData | Out-Null
    $Config | ConvertTo-Json | Set-Content (Join-Path $script:JarvisData 'config.json') -Encoding UTF8
    Write-JarvisToml $Config
}

function script:Set-JarvisApiKey([string]$Key) {
    $c = Get-JarvisConfig
    $c.ApiKey = if ($Key.Trim()) { ConvertTo-SecureString $Key.Trim() -AsPlainText -Force | ConvertFrom-SecureString } else { '' }
    Save-JarvisConfig $c
}

function script:Get-JarvisApiKey {
    $enc = (Get-JarvisConfig).ApiKey
    if (-not $enc) { return '' }
    try {
        $secure = ConvertTo-SecureString $enc
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { '' }
}

# Acepta el ID o el enlace de la web (elevenlabs.io/voices/<id> o .../voice-lab/share/...)
function script:ConvertTo-VoiceId([string]$Text) {
    $m = [regex]::Matches($Text, '[A-Za-z0-9]{20}')
    if ($m.Count) { $m[$m.Count - 1].Value }
}

# --- Ollama ---

function script:Get-OllamaExe {
    $cmd = (Get-Command ollama -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($cmd) { return $cmd }
    $local = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path $local) { $local }
}

# Modelos instalados en Ollama (vacío si no está en marcha). Rápido: pregunta a su API local.
function script:Get-OllamaModels {
    try {
        $r = Invoke-RestMethod 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2 -UseBasicParsing
        @($r.models | Sort-Object name | ForEach-Object { [pscustomobject]@{ Name = $_.name; Size = [Math]::Round($_.size / 1GB, 1) } })
    } catch { $null }
}

function script:Test-OllamaRunning {
    $tcp = New-Object Net.Sockets.TcpClient
    try { $tcp.ConnectAsync('127.0.0.1', 11434).Wait(500) -and $tcp.Connected } catch { $false } finally { $tcp.Dispose() }
}

# Arranca Ollama oculto si no está en marcha (su app de bandeja si existe; si no, "ollama serve")
function script:Start-Ollama {
    if (Test-OllamaRunning) { return $true }
    $exe = Get-OllamaExe
    if (-not $exe) { return $false }
    $app = Join-Path (Split-Path $exe) 'ollama app.exe'
    if (Test-Path $app) { Start-Process $app } else { Start-Process $exe -ArgumentList 'serve' -WindowStyle Hidden }
    for ($i = 0; $i -lt 30; $i++) { if (Test-OllamaRunning) { return $true }; Start-Sleep -Seconds 1 }
    $false
}

# Modelo a usar: el elegido o, si no, el primero instalado (prefiriendo qwen3)
function script:Get-JarvisModel($Config) {
    if ($Config.Model) { return $Config.Model }
    $models = Get-OllamaModels
    $pick = @($models | Where-Object Name -like 'qwen3*') + @($models) | Select-Object -First 1
    if ($pick) { $pick.Name } else { 'qwen3:8b' }
}

# --- OpenJarvis ---

# config.toml de OpenJarvis (lo usan el asistente y "jarvis chat --voice"): Ollama, voz y castellano
function script:Write-JarvisToml($Config) {
    New-Item -ItemType Directory -Force -Path $script:JarvisHome | Out-Null
    $model = Get-JarvisModel $Config
    $prompt = 'Eres Jarvis, un asistente personal que habla castellano de España, cercano y con un punto de humor elegante. Responde de forma breve y clara.'
    # Sin BOM: el lector de TOML de Python no lo admite (Set-Content -Encoding UTF8 lo pone en PowerShell 5.1)
    $toml = @"
# Generado por PC Toolkit (Jarvis). Se reescribe al cambiar los ajustes en el panel.
[engine]
default = "ollama"

[intelligence]
default_model = "$model"

[agent]
default_agent = "simple"
tools = ""
system_prompt = "$prompt"

[tools]
enabled = []

[speech]
backend = "faster-whisper"
model = "$($Config.SttModel)"
language = "es"
device = "cpu"
compute_type = "int8"
tts_backend = "$(if (Test-LocalVoice $Config.Voice) { 'pctoolkit_local' } else { 'elevenlabs' })"
voice_id = "$($Config.Voice)"
"@
    [IO.File]::WriteAllText((Join-Path $script:JarvisHome 'config.toml'), $toml, (New-Object Text.UTF8Encoding $false))
}

# Variables de entorno del asistente y del chat (la clave de ElevenLabs solo si se pide)
function script:Set-JarvisEnvironment([switch]$WithKey) {
    $env:OPENJARVIS_HOME = $script:JarvisHome
    $env:HF_HOME = Join-Path $script:JarvisData 'models'   # modelo de Whisper, dentro de la herramienta
    $env:HF_HUB_DISABLE_TELEMETRY = '1'
    $env:HF_HUB_DISABLE_SYMLINKS_WARNING = '1'
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    if ($WithKey) { $env:ELEVENLABS_API_KEY = Get-JarvisApiKey }
}

function script:Get-JarvisStatus {
    $path = Join-Path $script:JarvisData 'status.json'
    if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
}

# Procesos de Python del asistente (el lanzador de PowerShell lo cierra el gestor por "process")
function script:Stop-JarvisAssistant {
    Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" |
        Where-Object { $_.CommandLine -match 'jarvis_voice\.py' -and $_.CommandLine -notmatch '--say' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# Reproduce un texto con la voz elegida, sin bloquear el panel
function script:Start-JarvisSay([string]$Text) {
    if (-not (Test-Path $script:JarvisPythonW)) { throw 'Jarvis no está instalado del todo: reinstálalo.' }
    Set-JarvisEnvironment
    Start-Process $script:JarvisPythonW -ArgumentList "`"$(Join-Path $script:JarvisDir 'jarvis_voice.py')`"", '--data', "`"$script:JarvisData`"", '--say', "`"$($Text -replace '"', '')`""
}
