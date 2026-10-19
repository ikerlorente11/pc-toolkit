// Setup.cs - Instalador gráfico de PC Toolkit (PCToolkit-Setup.exe).
// Descarga la última versión de GitHub, deja elegir las herramientas y ejecuta install.ps1.
// Se compila con setup\build.ps1 (csc de .NET Framework, que ya viene con Windows).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Instalador de PC Toolkit")]
[assembly: AssemblyProduct("PC Toolkit")]
[assembly: AssemblyCompany("ikerlorente11")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

static class Program {
    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new SetupForm());
    }
}

class Tool {
    public string Id, Name, Description, Task;
}

class SetupForm : Form {
    const string ZipUrl = "https://github.com/ikerlorente11/pc-toolkit/archive/refs/heads/main.zip";

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    readonly string workDir = Path.Combine(Path.GetTempPath(), "pc-toolkit-setup-" + Guid.NewGuid().ToString("N"));
    string srcDir;
    readonly List<Tool> tools = new List<Tool>();
    readonly List<CheckBox> checks = new List<CheckBox>();
    bool hadWarnings;

    readonly bool dark;
    readonly Color bg, card, text, sub, border, ok, bad;
    readonly float scale;

    Label status;
    ProgressBar bar;
    Panel toolsPanel;
    TextBox log;
    Button btnInstall, btnClose;

    int S(int v) { return (int)Math.Round(v * scale); }

    public SetupForm() {
        object light = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1);
        dark = light is int && (int)light == 0;
        bg     = dark ? Color.FromArgb(0x20, 0x20, 0x20) : Color.FromArgb(0xf3, 0xf3, 0xf3);
        card   = dark ? Color.FromArgb(0x2b, 0x2b, 0x2b) : Color.White;
        text   = dark ? Color.White : Color.FromArgb(0x1a, 0x1a, 0x1a);
        sub    = dark ? Color.FromArgb(0xa6, 0xa6, 0xa6) : Color.FromArgb(0x5f, 0x5f, 0x5f);
        border = dark ? Color.FromArgb(0x3a, 0x3a, 0x3a) : Color.FromArgb(0xe5, 0xe5, 0xe5);
        ok     = dark ? Color.FromArgb(0x6c, 0xcb, 0x5f) : Color.FromArgb(0x0f, 0x7b, 0x0f);
        bad    = dark ? Color.FromArgb(0xff, 0x99, 0xa4) : Color.FromArgb(0xc4, 0x2b, 0x1c);
        using (Graphics g = CreateGraphics()) scale = g.DpiX / 96f;

        Text = "Instalar PC Toolkit";
        Font = new Font("Segoe UI", 9.5f);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = bg;
        ForeColor = text;
        ClientSize = new Size(S(520), S(470));

        Stream iconStream = Assembly.GetExecutingAssembly().GetManifestResourceStream("PcToolkit.ico");
        Icon = new Icon(iconStream);
        iconStream.Position = 0;
        PictureBox logo = new PictureBox();
        logo.Image = new Icon(iconStream, S(48), S(48)).ToBitmap();
        logo.SizeMode = PictureBoxSizeMode.AutoSize;
        logo.Location = new Point(S(24), S(22));

        Label title = new Label();
        title.Text = "PC Toolkit";
        title.Font = new Font("Segoe UI Semibold", 16f);
        title.AutoSize = true;
        title.Location = new Point(S(84), S(18));
        Label subtitle = new Label();
        subtitle.Text = "Utilidades para Windows. No necesita permisos de administrador.";
        subtitle.ForeColor = sub;
        subtitle.AutoSize = true;
        subtitle.Location = new Point(S(86), S(50));

        status = new Label();
        status.Text = "Descargando la última versión de GitHub...";
        status.AutoSize = false;
        status.Location = new Point(S(24), S(96));
        status.Size = new Size(S(472), S(24));

        bar = new ProgressBar();
        bar.Style = ProgressBarStyle.Marquee;
        bar.Location = new Point(S(24), S(124));
        bar.Size = new Size(S(472), S(6));

        toolsPanel = new Panel();
        toolsPanel.Location = new Point(S(24), S(128));
        toolsPanel.Size = new Size(S(472), S(270));
        toolsPanel.AutoScroll = true;
        toolsPanel.Visible = false;

        log = new TextBox();
        log.Multiline = true;
        log.ReadOnly = true;
        log.ScrollBars = ScrollBars.Vertical;
        log.BackColor = card;
        log.ForeColor = text;
        log.BorderStyle = BorderStyle.FixedSingle;
        log.Font = new Font("Consolas", 9f);
        log.Location = new Point(S(24), S(128));
        log.Size = new Size(S(472), S(270));
        log.Visible = false;

        btnInstall = MakeButton("Instalar", S(290));
        btnInstall.Enabled = false;
        btnInstall.Click += delegate { if (srcDir == null) StartDownload(); else StartInstall(); };
        btnClose = MakeButton("Cancelar", S(396));
        btnClose.Click += delegate { Close(); };
        AcceptButton = btnInstall;

        Controls.AddRange(new Control[] { logo, title, subtitle, status, bar, toolsPanel, log, btnInstall, btnClose });

        HandleCreated += delegate { int v = dark ? 1 : 0; DwmSetWindowAttribute(Handle, 20, ref v, 4); };
        Shown += delegate { StartDownload(); };
        FormClosed += delegate { try { Directory.Delete(workDir, true); } catch { } };
    }

    Button MakeButton(string caption, int x) {
        Button b = new Button();
        b.Text = caption;
        b.Location = new Point(x, S(418));
        b.Size = new Size(S(100), S(32));
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderColor = border;
        b.BackColor = card;
        b.ForeColor = text;
        return b;
    }

    void SetStatus(string message, Color color) {
        status.Text = message;
        status.ForeColor = color;
    }

    // --- 1. Descargar y descomprimir el repo ---

    void StartDownload() {
        SetStatus("Descargando la última versión de GitHub...", text);
        bar.Visible = true;
        btnInstall.Enabled = false;
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;   // TLS 1.2
        Directory.CreateDirectory(workDir);
        string zip = Path.Combine(workDir, "pc-toolkit.zip");
        WebClient web = new WebClient();
        web.DownloadFileCompleted += delegate(object s, System.ComponentModel.AsyncCompletedEventArgs e) {
            web.Dispose();
            bar.Visible = false;
            if (e.Error != null) {
                SetStatus("No se pudo descargar: " + e.Error.Message, bad);
                btnInstall.Text = "Reintentar";
                btnInstall.Enabled = true;
                return;
            }
            try {
                string extract = Path.Combine(workDir, "src");
                if (Directory.Exists(extract)) Directory.Delete(extract, true);
                ZipFile.ExtractToDirectory(zip, extract);
                srcDir = Path.Combine(extract, "pc-toolkit-main");
                LoadTools();
            } catch (Exception ex) {
                SetStatus("No se pudo preparar la instalación: " + ex.Message, bad);
            }
        };
        web.DownloadFileAsync(new Uri(ZipUrl), zip);
    }

    // --- 2. Elegir herramientas ---

    void LoadTools() {
        JavaScriptSerializer json = new JavaScriptSerializer();
        foreach (string dir in Directory.GetDirectories(Path.Combine(srcDir, "tools"))) {
            string manifest = Path.Combine(dir, "tool.json");
            if (!File.Exists(manifest)) continue;
            Dictionary<string, object> m = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(manifest, Encoding.UTF8));
            Tool t = new Tool();
            t.Id = (string)m["id"];
            t.Name = (string)m["name"];
            t.Description = (string)m["description"];
            t.Task = (string)m["task"];
            tools.Add(t);
        }

        bool anyInstalled = false;
        bool[] installed = new bool[tools.Count];
        for (int i = 0; i < tools.Count; i++) { installed[i] = TaskExists(tools[i].Task); anyInstalled |= installed[i]; }

        int y = 0;
        for (int i = 0; i < tools.Count; i++) {
            CheckBox cb = new CheckBox();
            cb.Text = tools[i].Name + (installed[i] ? "  (ya instalada: se actualizará)" : "");
            cb.Font = new Font("Segoe UI Semibold", 10f);
            cb.AutoSize = true;
            cb.Location = new Point(0, y);
            cb.Checked = anyInstalled ? installed[i] : true;
            Label desc = new Label();
            desc.Text = tools[i].Description;
            desc.ForeColor = sub;
            desc.AutoSize = false;
            desc.Location = new Point(S(20), y + S(26));
            desc.Size = new Size(S(440), S(40));
            toolsPanel.Controls.Add(cb);
            toolsPanel.Controls.Add(desc);
            checks.Add(cb);
            y += S(76);
        }
        Label hint = new Label();
        hint.Text = "Si instalas Audio AutoSwitch, ten los auriculares encendidos: se abrirá una ventana para elegirlos.";
        hint.ForeColor = sub;
        hint.AutoSize = false;
        hint.Location = new Point(0, y);
        hint.Size = new Size(S(460), S(40));
        toolsPanel.Controls.Add(hint);

        SetStatus("Elige qué herramientas quieres en este PC:", text);
        toolsPanel.Visible = true;
        btnInstall.Text = "Instalar";
        btnInstall.Enabled = true;
    }

    static bool TaskExists(string task) {
        ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe", "/query /tn \"\\" + task + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        using (Process p = Process.Start(psi)) {
            p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            p.WaitForExit();
            return p.ExitCode == 0;
        }
    }

    // --- 3. Instalar con install.ps1 mostrando su salida ---

    void StartInstall() {
        List<string> ids = new List<string>();
        for (int i = 0; i < tools.Count; i++) if (checks[i].Checked) ids.Add(tools[i].Id);

        toolsPanel.Visible = false;
        log.Visible = true;
        bar.Visible = true;
        btnInstall.Enabled = false;
        btnClose.Enabled = false;
        SetStatus("Instalando...", text);

        int oem = CultureInfo.CurrentCulture.TextInfo.OEMCodePage;
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(srcDir, "install.ps1") + "\" -Tools " +
            (ids.Count > 0 ? string.Join(",", ids.ToArray()) : "none"));
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.GetEncoding(oem);
        psi.StandardErrorEncoding = Encoding.GetEncoding(oem);
        psi.WorkingDirectory = workDir;

        Process p = new Process();
        p.StartInfo = psi;
        p.EnableRaisingEvents = true;
        p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { AppendLog(e.Data); };
        p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { AppendLog(e.Data); };
        p.Exited += delegate { BeginInvoke(new Action(delegate { Finish(p.ExitCode); })); };
        p.Start();
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
    }

    void AppendLog(string line) {
        if (line == null) return;
        if (line.StartsWith("ADVERTENCIA") || line.StartsWith("WARNING")) hadWarnings = true;
        BeginInvoke(new Action(delegate { log.AppendText(line + Environment.NewLine); }));
    }

    void Finish(int exitCode) {
        bar.Visible = false;
        btnClose.Enabled = true;
        btnClose.Text = "Cerrar";
        AcceptButton = btnClose;
        btnInstall.Visible = false;
        if (exitCode != 0)
            SetStatus("La instalación ha fallado. Revisa el detalle de abajo.", bad);
        else if (hadWarnings)
            SetStatus("Instalado, pero alguna herramienta ha dado un aviso (detalle abajo).", bad);
        else
            SetStatus("¡Listo! PC Toolkit está en el menú Inicio y en la bandeja del sistema.", ok);
    }
}
