// HdrNative.cs - Lee y cambia el HDR de las pantallas con la API DisplayConfig de Windows.
// En Windows 11 24H2+ usa GET_ADVANCED_COLOR_INFO_2 / SET_HDR_STATE (distingue HDR de la gestión
// automática del color); en versiones anteriores, GET_ADVANCED_COLOR_INFO / SET_ADVANCED_COLOR_STATE.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace PcToolkit.Hdr {
    public class Display {
        public uint AdapterLow;
        public int AdapterHigh;
        public uint TargetId;
        public string Name;
        public string GdiName;   // nombre de Windows de la pantalla (\\.\DISPLAY1), como Screen.DeviceName
        public bool Supported;
        public bool Enabled;
        public string Key { get { return TargetId.ToString(); } }
    }

    public static class Native {
        [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }

        [StructLayout(LayoutKind.Sequential)]
        struct PathInfo {
            public LUID SourceAdapter; public uint SourceId; public uint SourceModeIdx; public uint SourceFlags;
            public LUID TargetAdapter; public uint TargetId; public uint TargetModeIdx;
            public int OutputTechnology; public int Rotation; public int Scaling;
            public uint RefreshNum; public uint RefreshDen; public int ScanLine; public int TargetAvailable; public uint TargetFlags;
            public uint Flags;
        }

        [StructLayout(LayoutKind.Sequential, Size = 64)] struct ModeInfo { public int InfoType; }

        [StructLayout(LayoutKind.Sequential)]
        struct Header { public int Type; public int Size; public LUID Adapter; public uint Id; }

        [StructLayout(LayoutKind.Sequential)]
        struct ColorInfo { public Header H; public uint Value; public int Encoding; public uint Bits; }

        [StructLayout(LayoutKind.Sequential)]
        struct ColorInfo2 { public Header H; public uint Value; public int Encoding; public uint Bits; public int ActiveMode; }

        [StructLayout(LayoutKind.Sequential)]
        struct SetState { public Header H; public uint Value; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct TargetName {
            public Header H; public uint Flags; public int OutputTechnology; public ushort ManufacturerId; public ushort ProductCodeId;
            public uint ConnectorInstance;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string FriendlyName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DevicePath;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct SourceName { public Header H; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string GdiName; }

        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] PathInfo[] pathArray, ref uint modes, [Out] ModeInfo[] modeArray, IntPtr topology);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref ColorInfo info);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref ColorInfo2 info);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TargetName info);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SourceName info);
        [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(ref SetState info);

        const uint QDC_ONLY_ACTIVE_PATHS = 2;
        const int GET_SOURCE_NAME = 1, GET_TARGET_NAME = 2, GET_ADVANCED_COLOR_INFO = 9, SET_ADVANCED_COLOR_STATE = 10,
                  GET_ADVANCED_COLOR_INFO_2 = 15, SET_HDR_STATE = 16;

        static bool? newApi;

        static Header MakeHeader(int type, int size, LUID adapter, uint id) {
            Header h; h.Type = type; h.Size = size; h.Adapter = adapter; h.Id = id; return h;
        }

        static PathInfo[] GetPaths() {
            for (int attempt = 0; attempt < 3; attempt++) {
                uint np, nm;
                if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out np, out nm) != 0) break;
                PathInfo[] paths = new PathInfo[np];
                ModeInfo[] modes = new ModeInfo[nm];
                int r = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero);
                if (r == 0) { Array.Resize(ref paths, (int)np); return paths; }
                if (r != 122) break;   // ERROR_INSUFFICIENT_BUFFER: la configuración cambió, otra vez
            }
            return new PathInfo[0];
        }

        static void Read(LUID adapter, uint id, out bool supported, out bool enabled) {
            if (newApi != false) {
                ColorInfo2 c2 = new ColorInfo2();
                c2.H = MakeHeader(GET_ADVANCED_COLOR_INFO_2, Marshal.SizeOf(typeof(ColorInfo2)), adapter, id);
                if (DisplayConfigGetDeviceInfo(ref c2) == 0) {
                    newApi = true;
                    supported = (c2.Value & 0x10) != 0;   // highDynamicRangeSupported
                    enabled   = (c2.Value & 0x20) != 0;   // highDynamicRangeUserEnabled
                    return;
                }
                newApi = false;
            }
            ColorInfo c = new ColorInfo();
            c.H = MakeHeader(GET_ADVANCED_COLOR_INFO, Marshal.SizeOf(typeof(ColorInfo)), adapter, id);
            if (DisplayConfigGetDeviceInfo(ref c) != 0) { supported = false; enabled = false; return; }
            supported = (c.Value & 0x1) != 0 && (c.Value & 0x8) == 0;   // soportado y no bloqueado por política
            enabled   = (c.Value & 0x2) != 0;
        }

        static string ReadName(LUID adapter, uint id) {
            TargetName t = new TargetName();
            t.H = MakeHeader(GET_TARGET_NAME, Marshal.SizeOf(typeof(TargetName)), adapter, id);
            if (DisplayConfigGetDeviceInfo(ref t) == 0 && !string.IsNullOrEmpty(t.FriendlyName)) return t.FriendlyName;
            return "Pantalla " + id;
        }

        static string ReadGdiName(LUID adapter, uint sourceId) {
            SourceName s = new SourceName();
            s.H = MakeHeader(GET_SOURCE_NAME, Marshal.SizeOf(typeof(SourceName)), adapter, sourceId);
            return DisplayConfigGetDeviceInfo(ref s) == 0 ? s.GdiName : null;
        }

        // Pantallas activas (una por salida, aunque estén duplicadas)
        public static Display[] List() {
            List<Display> list = new List<Display>();
            HashSet<string> seen = new HashSet<string>();
            foreach (PathInfo p in GetPaths()) {
                string key = p.TargetAdapter.Low + ":" + p.TargetAdapter.High + ":" + p.TargetId;
                if (!seen.Add(key)) continue;
                bool supported, enabled;
                Read(p.TargetAdapter, p.TargetId, out supported, out enabled);
                Display d = new Display();
                d.AdapterLow = p.TargetAdapter.Low; d.AdapterHigh = p.TargetAdapter.High; d.TargetId = p.TargetId;
                d.Name = ReadName(p.TargetAdapter, p.TargetId);
                d.GdiName = ReadGdiName(p.SourceAdapter, p.SourceId);
                d.Supported = supported; d.Enabled = enabled;
                list.Add(d);
            }
            return list.ToArray();
        }

        public static bool Set(Display d, bool on) {
            if (newApi == null) Read(MakeLuid(d), d.TargetId, out d.Supported, out d.Enabled);
            SetState s = new SetState();
            s.H = MakeHeader(newApi == true ? SET_HDR_STATE : SET_ADVANCED_COLOR_STATE, Marshal.SizeOf(typeof(SetState)), MakeLuid(d), d.TargetId);
            s.Value = on ? 1u : 0u;
            return DisplayConfigSetDeviceInfo(ref s) == 0;
        }

        static LUID MakeLuid(Display d) { LUID l; l.Low = d.AdapterLow; l.High = d.AdapterHigh; return l; }
    }
}
