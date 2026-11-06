// Everything.cs - Cliente del IPC de Everything (voidtools) para la ventana de búsqueda de PC Toolkit.
// Habla directamente con la ventana de Everything por WM_COPYDATA (protocolo QUERY2 del SDK oficial,
// everything_ipc.h), así que no hace falta su DLL. La respuesta llega a una ventana oculta de solo
// mensajes en el hilo del gestor: la búsqueda no bloquea nada y el resultado se avisa con Completed.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PcToolkit.Everything {
    public class Item {
        public string Name { get; set; }
        public string Folder { get; set; }     // carpeta que lo contiene
        public string FullPath { get; set; }
        public bool IsFolder { get; set; }
        public bool IsDrive { get; set; }
        public long Size = -1;
        public DateTime? Modified;

        public string Location { get { return IsDrive ? "Unidad" : Folder; } }

        // Tamaño (solo archivos) y fecha de modificación, a la derecha de cada resultado
        public string Detail {
            get {
                List<string> parts = new List<string>();
                if (!IsFolder && Size >= 0) parts.Add(FormatSize(Size));
                if (Modified.HasValue) parts.Add(Modified.Value.ToString("d MMM yyyy", CultureInfo.CurrentCulture));
                return string.Join("  ·  ", parts.ToArray());
            }
        }

        ImageSource icon;
        public ImageSource Icon { get { if (icon == null) icon = Icons.Get(FullPath, IsFolder, IsDrive); return icon; } }

        public static string FormatSize(long size) {
            if (size < 1024) return size + " bytes";
            string[] units = { "KB", "MB", "GB", "TB" };
            double v = size / 1024.0;
            int u = 0;
            while (v >= 1024 && u < units.Length - 1) { v /= 1024; u++; }
            return (u == 0 ? Math.Ceiling(v).ToString("N0") : v.ToString(v < 10 ? "N1" : "N0")) + " " + units[u];
        }
    }

    // Iconos del sistema (los del Explorador). Por extensión, que es instantáneo y se reutiliza; los
    // ejecutables, accesos directos e iconos llevan el suyo propio, si están en un disco local.
    public static class Icons {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct SHFILEINFO {
            public IntPtr hIcon; public int iIcon; public uint dwAttributes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
        }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SHGetFileInfo(string path, uint attributes, ref SHFILEINFO info, uint size, uint flags);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);

        const uint SHGFI_ICON = 0x100, SHGFI_USEFILEATTRIBUTES = 0x10;
        const uint ATTR_DIRECTORY = 0x10, ATTR_NORMAL = 0x80;
        static readonly Dictionary<string, ImageSource> Cache = new Dictionary<string, ImageSource>(StringComparer.OrdinalIgnoreCase);
        static readonly HashSet<string> OwnIcon = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            ".exe", ".lnk", ".ico", ".url", ".appref-ms", ".msc", ".cpl", ".scr"
        };

        public static ImageSource Get(string path, bool folder, bool drive) {
            if (string.IsNullOrEmpty(path)) return null;
            string ext = Extension(path);
            bool local = path.Length > 2 && path[1] == ':';
            bool own = local && (drive || (!folder && OwnIcon.Contains(ext)));
            string key = own ? path : (folder ? "<carpeta>" : (ext.Length > 0 ? ext : "<archivo>"));
            ImageSource img;
            if (Cache.TryGetValue(key, out img)) return img;
            if (Cache.Count > 3000) Cache.Clear();

            SHFILEINFO info = new SHFILEINFO();
            uint flags = SHGFI_ICON;   // icono grande (32 px): se ve nítido al reducirlo en pantallas con escala
            string query = path;
            uint attr = 0;
            if (!own) { flags |= SHGFI_USEFILEATTRIBUTES; attr = folder ? ATTR_DIRECTORY : ATTR_NORMAL; query = folder ? "carpeta" : "archivo" + ext; }
            img = null;
            try {
                if (SHGetFileInfo(query, attr, ref info, (uint)Marshal.SizeOf(info), flags) != IntPtr.Zero && info.hIcon != IntPtr.Zero) {
                    BitmapSource b = Imaging.CreateBitmapSourceFromHIcon(info.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    b.Freeze();
                    img = b;
                }
            } catch { }
            finally { if (info.hIcon != IntPtr.Zero) DestroyIcon(info.hIcon); }
            Cache[key] = img;
            return img;
        }

        static string Extension(string path) {
            int dot = path.LastIndexOf('.');
            int slash = path.LastIndexOf('\\');
            return dot > slash && dot < path.Length - 1 ? path.Substring(dot) : "";
        }
    }

    public class Client {
        [StructLayout(LayoutKind.Sequential)]
        struct COPYDATASTRUCT { public IntPtr dwData; public int cbData; public IntPtr lpData; }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
        [DllImport("user32.dll")]
        static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr wParam, ref COPYDATASTRUCT lParam, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll")]
        static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll")] static extern bool ChangeWindowMessageFilterEx(IntPtr hwnd, uint msg, uint action, IntPtr info);

        const uint WM_COPYDATA = 0x004A, WM_USER = 0x0400, SMTO_ABORTIFHUNG = 0x2;
        const int COPYDATA_QUERY2W = 18;
        // Nombre, carpeta, ruta completa, tamaño y fecha de modificación
        const uint REQUEST = 0x1 | 0x2 | 0x4 | 0x10 | 0x40;

        public const uint MatchPath = 0x4;
        public const uint SortName = 1, SortPath = 3, SortSizeDesc = 6, SortModifiedDesc = 14;

        readonly HwndSource source;
        uint queryId = 1000;   // dwData de la respuesta: cada búsqueda usa uno nuevo y las respuestas viejas se descartan

        public List<Item> Results = new List<Item>();
        public long Total;
        public event EventHandler Completed;

        public Client() {
            HwndSourceParameters p = new HwndSourceParameters("PcToolkitEverything");
            p.ParentWindow = new IntPtr(-3);   // HWND_MESSAGE
            p.WindowStyle = 0;
            source = new HwndSource(p);
            source.AddHook(Hook);
            // Por si Everything se ejecuta como administrador: que pueda enviarnos la respuesta
            try { ChangeWindowMessageFilterEx(source.Handle, WM_COPYDATA, 1, IntPtr.Zero); } catch { }
        }

        static IntPtr FindEverything() {
            IntPtr h = FindWindow("EVERYTHING_TASKBAR_NOTIFICATION", null);
            if (h == IntPtr.Zero) h = FindWindow("EVERYTHING_TASKBAR_NOTIFICATION_(1.5a)", null);
            return h;
        }

        public static bool IsRunning { get { return FindEverything() != IntPtr.Zero; } }

        // Orden EVERYTHING_WM_IPC (versión, índice cargado...). -1 si Everything no está o no responde.
        public static int Command(int command) {
            IntPtr h = FindEverything();
            if (h == IntPtr.Zero) return -1;
            IntPtr result;
            if (SendMessageTimeout(h, WM_USER, new IntPtr(command), IntPtr.Zero, SMTO_ABORTIFHUNG, 1000, out result) == IntPtr.Zero) return -1;
            return result.ToInt32();
        }

        public static string Version {
            get {
                int major = Command(0);
                return major < 0 ? null : major + "." + Command(1) + "." + Command(2) + "." + Command(3);
            }
        }

        public static bool IsDbLoaded { get { return Command(401) == 1; } }

        // Lanza la búsqueda (no espera). false si Everything no está en marcha o no la acepta.
        public bool Search(string text, uint searchFlags, uint sort, uint maxResults) {
            IntPtr h = FindEverything();
            if (h == IntPtr.Zero) return false;
            queryId++;
            byte[] search = Encoding.Unicode.GetBytes(text + "\0");
            byte[] buf = new byte[28 + search.Length];
            BitConverter.GetBytes((uint)source.Handle.ToInt64()).CopyTo(buf, 0);   // reply_hwnd (32 bits también en x64)
            BitConverter.GetBytes(queryId).CopyTo(buf, 4);                         // reply_copydata_message
            BitConverter.GetBytes(searchFlags).CopyTo(buf, 8);
            BitConverter.GetBytes(0u).CopyTo(buf, 12);                             // offset
            BitConverter.GetBytes(maxResults).CopyTo(buf, 16);
            BitConverter.GetBytes(REQUEST).CopyTo(buf, 20);
            BitConverter.GetBytes(sort).CopyTo(buf, 24);
            search.CopyTo(buf, 28);
            GCHandle pin = GCHandle.Alloc(buf, GCHandleType.Pinned);
            try {
                COPYDATASTRUCT cds = new COPYDATASTRUCT();
                cds.dwData = new IntPtr(COPYDATA_QUERY2W);
                cds.cbData = buf.Length;
                cds.lpData = pin.AddrOfPinnedObject();
                IntPtr result;
                return SendMessageTimeout(h, WM_COPYDATA, source.Handle, ref cds, SMTO_ABORTIFHUNG, 2000, out result) != IntPtr.Zero
                       && result != IntPtr.Zero;
            } finally { pin.Free(); }
        }

        IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
            if (msg != WM_COPYDATA) return IntPtr.Zero;
            handled = true;
            COPYDATASTRUCT cds = (COPYDATASTRUCT)Marshal.PtrToStructure(lParam, typeof(COPYDATASTRUCT));
            if ((uint)cds.dwData.ToInt64() != queryId) return new IntPtr(1);   // de una búsqueda ya sustituida
            byte[] b = new byte[cds.cbData];
            Marshal.Copy(cds.lpData, b, 0, cds.cbData);
            try { Parse(b); } catch { Results = new List<Item>(); Total = 0; }
            // El aviso, después: Everything está esperando a que devolvamos este mensaje
            source.Dispatcher.BeginInvoke(new Action(delegate { if (Completed != null) Completed(this, EventArgs.Empty); }));
            return new IntPtr(1);
        }

        // EVERYTHING_IPC_LIST2: cabecera (5 DWORD), items[numitems] {flags, data_offset} y los datos de cada uno
        // en el orden de los bits de request_flags
        void Parse(byte[] b) {
            uint total = BitConverter.ToUInt32(b, 0);
            uint count = BitConverter.ToUInt32(b, 4);
            uint flags = BitConverter.ToUInt32(b, 12);
            List<Item> list = new List<Item>((int)count);
            for (int i = 0; i < count; i++) {
                uint itemFlags = BitConverter.ToUInt32(b, 20 + i * 8);
                int d = (int)BitConverter.ToUInt32(b, 24 + i * 8);
                Item it = new Item();
                it.IsFolder = (itemFlags & 1) != 0;
                it.IsDrive = (itemFlags & 2) != 0;
                if ((flags & 0x1) != 0) it.Name = ReadString(b, ref d);
                if ((flags & 0x2) != 0) it.Folder = ReadString(b, ref d);
                if ((flags & 0x4) != 0) it.FullPath = ReadString(b, ref d);
                if ((flags & 0x8) != 0) ReadString(b, ref d);   // extensión
                if ((flags & 0x10) != 0) { it.Size = BitConverter.ToInt64(b, d); d += 8; }
                if ((flags & 0x20) != 0) d += 8;                  // fecha de creación
                if ((flags & 0x40) != 0) {
                    long ft = BitConverter.ToInt64(b, d); d += 8;
                    if (ft > 0) { try { it.Modified = DateTime.FromFileTime(ft); } catch { } }
                }
                if (string.IsNullOrEmpty(it.FullPath)) {
                    it.FullPath = string.IsNullOrEmpty(it.Folder) ? it.Name : it.Folder.TrimEnd('\\') + "\\" + it.Name;
                }
                if (it.IsDrive && !it.FullPath.EndsWith("\\")) it.FullPath += "\\";
                list.Add(it);
            }
            Results = list;
            Total = total;
        }

        static string ReadString(byte[] b, ref int d) {
            int len = (int)BitConverter.ToUInt32(b, d);
            d += 4;
            string s = Encoding.Unicode.GetString(b, d, len * 2);
            d += (len + 1) * 2;
            return s;
        }
    }
}
