// KeyboardSound.cs - Escucha el teclado de todo el sistema y reproduce un sonido en cada pulsación.
// Reproducción con MCI (winmm, sin dependencias) con varias "voces" para que al teclear rápido los
// sonidos se solapen en vez de cortarse. Lo cargan con Add-Type el vigilante y la página de ajustes.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace PcToolkit.KeyboardSound {

    public class Player : IDisposable {
        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        static extern int mciSendString(string command, System.Text.StringBuilder result, int length, IntPtr callback);

        static int counter;
        readonly List<string> voices = new List<string>();
        int next;

        public Player(string file, int voiceCount) {
            for (int i = 0; i < voiceCount; i++) {
                string alias = "pctoolkitks" + System.Threading.Interlocked.Increment(ref counter);
                if (mciSendString("open \"" + file + "\" type mpegvideo alias " + alias, null, 0, IntPtr.Zero) == 0) voices.Add(alias);
            }
        }

        public bool Ready { get { return voices.Count > 0; } }

        // 0-100 (volumen del propio sonido, no el del sistema)
        public void SetVolume(int percent) {
            int v = Math.Max(0, Math.Min(100, percent)) * 10;
            foreach (string alias in voices) mciSendString("setaudio " + alias + " volume to " + v, null, 0, IntPtr.Zero);
        }

        public void Play() {
            if (voices.Count == 0) return;
            string alias = voices[next];
            next = (next + 1) % voices.Count;
            mciSendString("play " + alias + " from 0", null, 0, IntPtr.Zero);
        }

        public void Dispose() {
            foreach (string alias in voices) mciSendString("close " + alias, null, 0, IntPtr.Zero);
            voices.Clear();
        }
    }

    // Gancho de teclado de bajo nivel (WH_KEYBOARD_LL). Necesita un bucle de mensajes en el mismo hilo.
    public static class KeyboardHook {
        delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

        static readonly HookProc callback = OnKey;   // referencia viva para que el recolector no la libere
        static readonly HashSet<int> pressed = new HashSet<int>();
        static IntPtr hook;

        public static Player Player;

        public static bool Start() {
            if (hook == IntPtr.Zero) hook = SetWindowsHookEx(13 /* WH_KEYBOARD_LL */, callback, GetModuleHandle(null), 0);
            return hook != IntPtr.Zero;
        }

        public static void Stop() {
            if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }

        static IntPtr OnKey(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0) {
                int vk = Marshal.ReadInt32(lParam);
                int msg = wParam.ToInt32();
                if (msg == 0x100 || msg == 0x104) {           // WM_KEYDOWN / WM_SYSKEYDOWN
                    if (pressed.Add(vk) && Player != null) Player.Play();   // mantener pulsada no repite
                } else if (msg == 0x101 || msg == 0x105) {    // WM_KEYUP / WM_SYSKEYUP
                    pressed.Remove(vk);
                }
            }
            return CallNextHookEx(hook, code, wParam, lParam);
        }
    }
}
