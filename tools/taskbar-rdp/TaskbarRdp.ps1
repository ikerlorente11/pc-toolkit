# TaskbarRdp.ps1 - Barra de tareas siempre visible en sesiones de Escritorio Remoto y autoocultable en local.
# Lanzado por la tarea programada "TaskbarRdp" (inicio de sesion, conexion remota y conexion local).

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Taskbar {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct APPBARDATA {
        public int cbSize; public IntPtr hWnd; public uint uCallbackMessage;
        public uint uEdge; public RECT rc; public IntPtr lParam;
    }
    [DllImport("shell32.dll")] public static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string name);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);

    public static void SetAutoHide(bool autoHide) {
        APPBARDATA d = new APPBARDATA();
        d.cbSize = Marshal.SizeOf(d);
        d.hWnd = FindWindow("Shell_TrayWnd", null);
        d.lParam = (IntPtr)(autoHide ? 1 : 2);   // ABS_AUTOHIDE : ABS_ALWAYSONTOP
        SHAppBarMessage(0xA, ref d);             // ABM_SETSTATE
    }
    public static bool IsRemote() { return GetSystemMetrics(0x1000) != 0; }  // SM_REMOTESESSION
}
"@

# -AlwaysVisible desactiva el autoocultado (lo usa disable.ps1)
if ($args -contains '-AlwaysVisible') { [Taskbar]::SetAutoHide($false); return }

# Al iniciar sesion, Explorer puede tardar en tener la barra lista
for ($i = 0; $i -lt 30 -and -not [Taskbar]::FindWindow("Shell_TrayWnd", $null); $i++) { Start-Sleep -Seconds 1 }
Start-Sleep -Seconds 2

$remote = [Taskbar]::IsRemote()
[Taskbar]::SetAutoHide(-not $remote)

$dataDir = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\taskbar-rdp'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$log = Join-Path $dataDir 'TaskbarRdp.log'
if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Clear-Content $log }
"$(Get-Date -Format s) remoto=$remote autoocultar=$(-not $remote)" | Add-Content $log
