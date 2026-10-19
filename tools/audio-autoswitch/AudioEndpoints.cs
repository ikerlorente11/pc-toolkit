// AudioEndpoints.cs - Acceso directo a la API de audio de Windows (MMDevice + IPolicyConfig),
// sin modulos externos. Lo cargan con Add-Type el vigilante y la pagina de ajustes.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace PcToolkit.Audio {

    public class AudioDevice {
        public string Id { get; set; }
        public string Name { get; set; }
        public string ContainerId { get; set; }
        public string Enumerator { get; set; }
        public int FormFactor { get; set; }
        public bool IsDefault { get; set; }
        public bool IsActive { get; set; }

        // Auriculares/cascos Bluetooth o USB: cambian solos al encenderse salvo que se diga lo contrario.
        // Los HDMI de los monitores y los altavoces internos no (si no, al despertar el monitor se llevaria el sonido).
        public bool AutoByDefault {
            get {
                string e = (Enumerator ?? "").ToUpperInvariant();
                return e == "USB" || e.StartsWith("BTH") || FormFactor == 3 || FormFactor == 5;   // 3 = Headphones, 5 = Headset
            }
        }

        // Perfil "manos libres" de un Bluetooth: peor calidad, se prefiere el estereo del mismo dispositivo
        public bool IsHandsFree { get { return string.Equals(Enumerator, "BTHHFENUM", StringComparison.OrdinalIgnoreCase); } }
    }

    public static class Endpoints {
        public const int Render = 0, Capture = 1;

        static PropertyKey Key(string fmtid, int pid) { PropertyKey k; k.FormatId = new Guid(fmtid); k.PropertyId = pid; return k; }
        static readonly PropertyKey FriendlyNameKey = Key("a45c254e-df1c-4efd-8020-67d146a850e0", 14);
        static readonly PropertyKey EnumeratorKey   = Key("a45c254e-df1c-4efd-8020-67d146a850e0", 24);
        static readonly PropertyKey ContainerKey    = Key("8c7ed206-3f8a-4827-b3ab-ae9e1faefc6c", 2);
        static readonly PropertyKey FormFactorKey   = Key("1da5d803-d492-4edd-8c23-e0c0ffee7f0e", 0);

        // Dispositivos activos (conectados/encendidos) de salida (Render) o entrada (Capture)
        public static AudioDevice[] List(int flow) { return List(flow, false); }

        // Con includeDisconnected tambien los emparejados/conocidos pero apagados o desenchufados
        public static AudioDevice[] List(int flow, bool includeDisconnected) {
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            List<AudioDevice> list = new List<AudioDevice>();
            try {
                string def = DefaultId(en, flow);
                IMMDeviceCollection col;
                Marshal.ThrowExceptionForHR(en.EnumAudioEndpoints(flow, includeDisconnected ? 9 : 1 /* ACTIVE | UNPLUGGED */, out col));
                int count;
                col.GetCount(out count);
                for (int i = 0; i < count; i++) {
                    IMMDevice dev;
                    if (col.Item(i, out dev) != 0) continue;
                    try {
                        string id;
                        dev.GetId(out id);
                        IPropertyStore ps;
                        dev.OpenPropertyStore(0 /* STGM_READ */, out ps);
                        try {
                            AudioDevice a = new AudioDevice();
                            a.Id = id;
                            a.Name = ReadString(ps, FriendlyNameKey) ?? id;
                            a.Enumerator = ReadString(ps, EnumeratorKey);
                            a.ContainerId = ReadGuid(ps, ContainerKey);
                            a.FormFactor = ReadInt(ps, FormFactorKey);
                            a.IsDefault = id == def;
                            int state;
                            dev.GetState(out state);
                            a.IsActive = state == 1;
                            list.Add(a);
                        } finally { Marshal.ReleaseComObject(ps); }
                    } finally { Marshal.ReleaseComObject(dev); }
                }
                Marshal.ReleaseComObject(col);
            } finally { Marshal.ReleaseComObject(en); }
            return list.ToArray();
        }

        public static string GetDefaultId(int flow) {
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            try { return DefaultId(en, flow); } finally { Marshal.ReleaseComObject(en); }
        }

        // Pone el dispositivo como predeterminado y de comunicaciones (como el menu de sonido de Windows)
        public static void SetDefault(string id) {
            IPolicyConfig pc = (IPolicyConfig)new PolicyConfigClientCom();
            try {
                for (int role = 0; role < 3; role++) Marshal.ThrowExceptionForHR(pc.SetDefaultEndpoint(id, role));
            } finally { Marshal.ReleaseComObject(pc); }
        }

        static string DefaultId(IMMDeviceEnumerator en, int flow) {
            IMMDevice dev;
            if (en.GetDefaultAudioEndpoint(flow, 0 /* eConsole */, out dev) != 0 || dev == null) return null;
            try { string id; dev.GetId(out id); return id; } finally { Marshal.ReleaseComObject(dev); }
        }

        static string ReadString(IPropertyStore ps, PropertyKey key) {
            PropVariant v;
            if (ps.GetValue(ref key, out v) != 0) return null;
            try { return v.vt == 31 /* VT_LPWSTR */ ? Marshal.PtrToStringUni(v.p) : null; } finally { PropVariantClear(ref v); }
        }

        static string ReadGuid(IPropertyStore ps, PropertyKey key) {
            PropVariant v;
            if (ps.GetValue(ref key, out v) != 0) return null;
            try { return v.vt == 72 /* VT_CLSID */ ? ((Guid)Marshal.PtrToStructure(v.p, typeof(Guid))).ToString() : null; } finally { PropVariantClear(ref v); }
        }

        static int ReadInt(IPropertyStore ps, PropertyKey key) {
            PropVariant v;
            if (ps.GetValue(ref key, out v) != 0) return -1;
            try { return v.vt == 19 /* VT_UI4 */ ? (int)(v.p.ToInt64() & 0xFFFFFFFF) : -1; } finally { PropVariantClear(ref v); }
        }

        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant pvar);
    }

    // --- Interop COM ---

    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey { public Guid FormatId; public int PropertyId; }

    [StructLayout(LayoutKind.Sequential)]
    struct PropVariant { public ushort vt; ushort r1, r2, r3; public IntPtr p; public IntPtr p2; }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom { }
    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigClientCom { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    // Interfaz no documentada que usa el propio Windows para cambiar el dispositivo predeterminado
    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig {
        [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr format);
        [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, int isDefault, IntPtr format);
        [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, int isDefault, IntPtr defaultPeriod, IntPtr minPeriod);
        [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr period);
        [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
        [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
        [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key, IntPtr value);
        [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key, IntPtr value);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
        [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, int visible);
    }
}
