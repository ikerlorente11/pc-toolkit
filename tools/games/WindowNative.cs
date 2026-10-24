// WindowNative.cs - Busca las ventanas de un proceso y las convierte en ventanas sin bordes que
// ocupan una pantalla entera (como la pantalla completa, pero sin dejar de ser una ventana).
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace PcToolkit.GameWindows {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

        const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
        const long WS_CAPTION = 0xC00000, WS_THICKFRAME = 0x40000, WS_SYSMENU = 0x80000,
                   WS_MINIMIZEBOX = 0x20000, WS_MAXIMIZEBOX = 0x10000;
        const long WS_EX_DLGMODALFRAME = 0x1, WS_EX_WINDOWEDGE = 0x100, WS_EX_CLIENTEDGE = 0x200, WS_EX_STATICEDGE = 0x20000;
        const long FRAME = WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
        const long EX_FRAME = WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE | WS_EX_STATICEDGE;
        const uint GW_OWNER = 4;
        const uint SWP_NOZORDER = 0x4, SWP_NOOWNERZORDER = 0x200, SWP_FRAMECHANGED = 0x20, SWP_NOACTIVATE = 0x10;

        // Coordenadas reales de las pantallas aunque Windows tenga escalado
        public static void Init() { SetProcessDPIAware(); }

        // Ventanas principales visibles del proceso (sin dueño y con un tamaño razonable)
        public static IntPtr[] GetWindows(int pid) {
            List<IntPtr> list = new List<IntPtr>();
            EnumWindows(delegate (IntPtr h, IntPtr l) {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                if (owner != pid || !IsWindowVisible(h) || GetWindow(h, GW_OWNER) != IntPtr.Zero) return true;
                RECT r;
                if (GetWindowRect(h, out r) && r.Right - r.Left >= 200 && r.Bottom - r.Top >= 150) list.Add(h);
                return true;
            }, IntPtr.Zero);
            return list.ToArray();
        }

        // Ya está sin bordes y ocupando justo ese rectángulo (o minimizada: no se toca)
        public static bool IsPlaced(IntPtr hwnd, int x, int y, int w, int h) {
            if (IsIconic(hwnd)) return true;
            RECT r;
            if (!GetWindowRect(hwnd, out r)) return true;
            long style = GetWindowLongPtr(hwnd, GWL_STYLE).ToInt64();
            return (style & FRAME) == 0 && r.Left == x && r.Top == y && r.Right - r.Left == w && r.Bottom - r.Top == h;
        }

        // Rectángulo de la ventana si está sin bordes y sin minimizar (x, y, ancho, alto); si no, null
        public static int[] GetBorderlessRect(IntPtr hwnd) {
            RECT r;
            if (IsIconic(hwnd) || !GetWindowRect(hwnd, out r)) return null;
            if ((GetWindowLongPtr(hwnd, GWL_STYLE).ToInt64() & FRAME) != 0) return null;
            return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
        }

        public static bool Place(IntPtr hwnd, int x, int y, int w, int h) {
            if (IsZoomed(hwnd)) ShowWindow(hwnd, 9);   // SW_RESTORE: maximizada no se puede mover
            long style = GetWindowLongPtr(hwnd, GWL_STYLE).ToInt64();
            long ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
            SetWindowLongPtr(hwnd, GWL_STYLE, new IntPtr(style & ~FRAME));
            SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(ex & ~EX_FRAME));
            return SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE);
        }
    }
}
