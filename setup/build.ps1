# build.ps1 - Compila setup\bin\PCToolkit-Setup.exe con el csc de .NET Framework (viene con Windows).
#   powershell -ExecutionPolicy Bypass -File .\setup\build.ps1
# Para publicarlo: gh release create vX.Y.Z .\setup\bin\PCToolkit-Setup.exe

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$csc  = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$bin  = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
$ico = Join-Path $root 'assets\pc-toolkit.ico'

& $csc /nologo /target:winexe /optimize+ `
    "/out:$(Join-Path $bin 'PCToolkit-Setup.exe')" `
    "/win32icon:$ico" `
    "/win32manifest:$(Join-Path $PSScriptRoot 'app.manifest')" `
    "/resource:$ico,PcToolkit.ico" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll `
    /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll `
    (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE) { throw "csc ha fallado ($LASTEXITCODE)" }
Get-Item (Join-Path $bin 'PCToolkit-Setup.exe')
