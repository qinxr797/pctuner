// =====================================================================
//  电脑调优助手 —— 启动器
//
//  它只干三件事，不碰任何业务逻辑：
//    1. 带管理员权限启动（权限靠 app.manifest 里的 requireAdministrator，
//       双击就弹 UAC，不用再在 PowerShell 里自己提权一遍）
//    2. 清掉「网络来源」锁定（Zone.Identifier 数据流）
//    3. 拉起 PCTuner.ps1，控制台窗口藏起来
//
//  ★ 为什么不用 PS2EXE ★
//    那类工具把脚本加密成一段 base64 塞进 exe 里再运行时解出来 ——
//    这个行为特征和恶意软件一模一样，Defender 和国内杀软经常直接报毒。
//    这个启动器只是个几 KB 的壳，源码就在旁边，编译脚本也在，
//    谁都能自己重编一份对比。
//
//  编译：Launcher\build.ps1（用 Windows 自带的 csc.exe，不装任何东西）
// =====================================================================
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

static class Launcher
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool DeleteFileW(string name);

    const string Title = "电脑调优助手";

    [STAThread]
    static int Main(string[] args)
    {
        string dir = Path.GetDirectoryName(Application.ExecutablePath);
        string script = Path.Combine(dir, "PCTuner.ps1");

        if (!File.Exists(script))
        {
            MessageBox.Show(
                "找不到主程序 PCTuner.ps1。\n\n" +
                "这个 exe 必须和 PCTuner.ps1、Modules、Lib 放在同一个文件夹里 ——\n" +
                "多半是只把 exe 单独拷出来了，或者解压时漏了文件。\n\n" +
                "当前位置：\n" + dir,
                Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        // 解除「网络来源」锁定。
        // 从微信 / QQ / 浏览器拿到的压缩包，解压出来的每个文件都带一条
        // 叫 Zone.Identifier 的隐藏数据流，PowerShell 读它会报
        // 「对路径的访问被拒绝」—— 文件明明在那儿，就是读不了。
        // 删掉这条流就等于右键属性里勾「解除锁定」，失败了也无所谓。
        try
        {
            foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
            {
                try { DeleteFileW(f + ":Zone.Identifier"); } catch { }
            }
        }
        catch { }

        string ps = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps)) ps = "powershell.exe";

        var psi = new ProcessStartInfo
        {
            FileName = ps,
            // -STA 是 WPF 必需的；-NoProfile 避免用户自己的 profile 干扰
            Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + script + "\"",
            WorkingDirectory = dir,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };

        try
        {
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "启动失败：\n\n" + ex.Message + "\n\n" +
                "可以改用「诊断启动.bat」，它不藏窗口，能看见完整报错。",
                Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
