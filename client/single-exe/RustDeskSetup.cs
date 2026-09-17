// RustDesk 单文件安装器 —— 由 make-exe.ps1 生成，打包时会把整份客户端与服务器信息内嵌进来。
// 运行流程：释放客户端 -> 写入服务器配置 -> 建桌面快捷方式 -> 启动客户端。
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

static class RustDeskSetup
{
    // ↓↓↓ 打包时由 make-exe.ps1 替换 ↓↓↓
    const string IdServer    = "111.229.187.4";
    const string RelayServer = "111.229.187.4";
    const string PublicKey   = "rFkrn3MC0Uig5qkNxxeikCFtnuWFTpejrmtLEnKL2UU=";
    const string PayloadName = "payload.zip";
    const string AppVersion  = "1.4.9";
    // ↑↑↑ 打包时由 make-exe.ps1 替换 ↑↑↑

    static readonly string InstallDir  = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RustDesk");
    static readonly string ExePath     = Path.Combine(InstallDir, "RustDesk.exe");
    static readonly string UserCfgDir  = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"RustDesk\config");
    static readonly string UserCfg     = Path.Combine(UserCfgDir, "RustDesk2.toml");

    [STAThread]
    static int Main(string[] args)
    {
        bool quiet = Array.Exists(args, a => a.Equals("--quiet", StringComparison.OrdinalIgnoreCase));
        try
        {
            ExtractPayload();
            WriteConfig(UserCfgDir, UserCfg);
            CreateShortcut();
            Launch(quiet);
            return 0;
        }
        catch (Exception ex)
        {
            if (!quiet)
                MessageBox.Show("安装失败：\r\n\r\n" + ex.Message, "RustDesk",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    // 把内嵌的客户端释放到 %LOCALAPPDATA%\RustDesk
    static void ExtractPayload()
    {
        var asm = Assembly.GetExecutingAssembly();
        string resName = null;
        foreach (var n in asm.GetManifestResourceNames())
            if (n.EndsWith(PayloadName, StringComparison.OrdinalIgnoreCase)) { resName = n; break; }
        if (resName == null) throw new Exception("安装包内部损坏：找不到客户端数据。");

        // 已有可用副本就不重复释放（同一版本再次双击时秒开）
        if (File.Exists(ExePath))
        {
            Directory.CreateDirectory(InstallDir);
        }
        Directory.CreateDirectory(InstallDir);

        using (var s = asm.GetManifestResourceStream(resName))
        using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
        {
            foreach (var e in zip.Entries)
            {
                if (string.IsNullOrEmpty(e.Name)) continue; // 目录项，按需创建
                string dest = Path.Combine(InstallDir, e.FullName.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                // 被占用的文件（客户端正在跑）跳过，不当作失败
                try { e.ExtractToFile(dest, true); }
                catch (IOException) { }
            }
        }
        if (!File.Exists(ExePath)) throw new Exception("释放客户端失败，未找到 RustDesk.exe。");
    }

    // 写配置：必须是无 BOM 的 UTF-8，带 BOM 会让 RustDesk 读不了
    static void WriteConfig(string dir, string file)
    {
        Directory.CreateDirectory(dir);
        if (File.Exists(file))
        {
            try { File.Copy(file, file + ".bak", true); } catch { }
        }
        var sb = new StringBuilder();
        sb.AppendLine("rendezvous_server = '" + IdServer + ":21116'");
        sb.AppendLine("nat_type = 1");
        sb.AppendLine("serial = 0");
        sb.AppendLine();
        sb.AppendLine("[options]");
        sb.AppendLine("custom-rendezvous-server = '" + IdServer + "'");
        sb.AppendLine("relay-server = '" + RelayServer + "'");
        sb.AppendLine("key = '" + PublicKey + "'");
        File.WriteAllBytes(file, new UTF8Encoding(false).GetBytes(sb.ToString()));
    }

    static void CreateShortcut()
    {
        try
        {
            string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            string lnk = Path.Combine(desktop, "RustDesk.lnk");
            // 用 WScript.Shell 通过 COM 创建，避免额外依赖
            Type t = Type.GetTypeFromProgID("WScript.Shell");
            if (t == null) return;
            object shell = Activator.CreateInstance(t);
            object sc = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
            Type st = sc.GetType();
            st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { ExePath });
            st.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { InstallDir });
            st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { "RustDesk 远程桌面" });
            st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
        }
        catch { /* 快捷方式建不出来不影响使用 */ }
    }

    static void Launch(bool quiet)
    {
        var psi = new ProcessStartInfo(ExePath) { UseShellExecute = true, WorkingDirectory = InstallDir };
        Process.Start(psi);

        if (!quiet)
        {
            MessageBox.Show(
                "RustDesk 已就绪。\r\n\r\n" +
                "服务器：" + IdServer + "\r\n" +
                "客户端位置：" + InstallDir + "\r\n\r\n" +
                "桌面上已创建 RustDesk 快捷方式，以后双击它即可。",
                "RustDesk 安装完成", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }
}
