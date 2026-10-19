// TaskbarNative.cs - Acceso a la barra de tareas de Windows (autoocultar, sesión remota, avisar cambios).
// Lo cargan con Add-Type Taskbar.ps1, common.ps1 y las páginas del gestor.
using System;
using System.Runtime.InteropServices;

namespace PcToolkit.Taskbar {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int left, top, right, bottom; }

        [StructLayout(LayoutKind.Sequential)]
        struct APPBARDATA {
            public int cbSize; public IntPtr hWnd; public uint uCallbackMessage;
            public uint uEdge; public RECT rc; public IntPtr lParam;
        }

        [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string name);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);

        public static bool TrayReady { get { return FindWindow("Shell_TrayWnd", null) != IntPtr.Zero; } }

        // true si la sesión actual es de Escritorio Remoto (SM_REMOTESESSION)
        public static bool IsRemote { get { return GetSystemMetrics(0x1000) != 0; } }

        public static bool GetAutoHide() {
            APPBARDATA d = new APPBARDATA();
            d.cbSize = Marshal.SizeOf(d);
            return ((uint)SHAppBarMessage(0x4, ref d) & 0x1) != 0;   // ABM_GETSTATE & ABS_AUTOHIDE
        }

        // Borde en el que está la barra: 0 izquierda, 1 arriba, 2 derecha, 3 abajo
        public static int GetEdge() {
            APPBARDATA d = new APPBARDATA();
            d.cbSize = Marshal.SizeOf(d);
            SHAppBarMessage(0x5, ref d);   // ABM_GETTASKBARPOS
            return (int)d.uEdge;
        }

        public static void SetAutoHide(bool autoHide) {
            APPBARDATA d = new APPBARDATA();
            d.cbSize = Marshal.SizeOf(d);
            d.hWnd = FindWindow("Shell_TrayWnd", null);
            d.lParam = (IntPtr)(autoHide ? 1 : 2);   // ABS_AUTOHIDE : ABS_ALWAYSONTOP
            SHAppBarMessage(0xA, ref d);             // ABM_SETSTATE
        }

        // Avisa a Explorer de que han cambiado los ajustes de la barra (alineación, pantallas...)
        public static void NotifySettingsChanged() {
            UIntPtr r;
            SendMessageTimeout(new IntPtr(0xFFFF), 0x1A /* WM_SETTINGCHANGE */, UIntPtr.Zero, "TraySettings", 2 /* SMTO_ABORTIFHUNG */, 2000, out r);
        }
    }
}
