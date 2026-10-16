using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

internal static class InstallerSmoke
{
    private const string UninstallKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\ChiikawaPet";
    private static readonly string InstallDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "ChiikawaPet");

    public static int Run(string executable, string screenshots, bool uninstall)
    {
        Process? launcher = null;
        Process? wizardProcess = null;
        IntPtr wizard = IntPtr.Zero;
        try
        {
            executable = Path.GetFullPath(executable);
            screenshots = Path.GetFullPath(screenshots);
            Require(File.Exists(executable), "Installer executable does not exist.");
            Require(MutexAvailable(), "Close the running pet before the installer smoke.");
            Require(FindWizard() == IntPtr.Zero, "Another Chiikawa installation wizard is open.");
            if (!uninstall) Require(!Directory.Exists(InstallDirectory), "Installation requires a clean app directory.");
            Directory.CreateDirectory(screenshots);
            launcher = Process.Start(new ProcessStartInfo(executable) { UseShellExecute = false });
            Require(launcher != null, "Could not start the native wizard.");
            WaitUntil(() => { wizard = FindWizard(); return wizard != IntPtr.Zero; }, "Native wizard did not appear.");
            GetWindowThreadProcessId(wizard, out uint owner);
            wizardProcess = Process.GetProcessById((int)owner);
            WaitUntil(() => Ready(wizard, finish: false), "Welcome/confirmation page did not become interactive.");
            Capture(wizard, Path.Combine(screenshots, uninstall ? "uninstall-confirm.png" : "welcome.png"));
            ClickNext(wizard);
            WaitUntil(() => Ready(wizard, finish: true), "Installation/removal did not reach the completion page.", 120000);
            if (!uninstall)
            {
                VerifyInstallation(executable);
                IntPtr launch = LaunchCheckbox(wizard);
                Require(launch != IntPtr.Zero && SendMessage(launch, 0x00F0, IntPtr.Zero, IntPtr.Zero) == (IntPtr)1,
                    "Completion page did not offer a checked launch option.");
            }
            Capture(wizard, Path.Combine(screenshots, uninstall ? "uninstall-finish.png" : "finish.png"));
            ClickNext(wizard);
            Require(wizardProcess.WaitForExit(15000), "Wizard did not exit after Finish.");
            Require(wizardProcess.ExitCode == 0, "Wizard returned a failure exit code.");
            Require(launcher.WaitForExit(15000) && launcher.ExitCode == 0, "Installer launcher did not exit successfully.");
            if (uninstall)
            {
                WaitUntil(() => !Directory.Exists(InstallDirectory) && !RegistryExists(),
                    "Uninstall left the app directory or registry entry behind.");
                string shortcuts = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Chiikawa Pet");
                Require(!Directory.Exists(shortcuts), "Uninstall left Start menu shortcuts behind.");
            }
            else CheckFinishLaunch();
            Require(MutexAvailable(), "Pet single-instance mutex was not released.");
            Console.WriteLine(uninstall
                ? "PASS native uninstall: rendered confirmation/completion, normal exit, app/registry/shortcuts removed."
                : "PASS native installer: rendered welcome/completion, installed version/files, finish launch and clean pet exit.");
            return 0;
        }
        catch (Exception error)
        {
            if (wizard != IntPtr.Zero && IsWindowVisible(wizard))
            {
                try { Capture(wizard, Path.Combine(screenshots, uninstall ? "uninstall-failure.png" : "install-failure.png")); }
                catch { }
            }
            Console.Error.WriteLine("FAIL native installer: " + error);
            return 1;
        }
        finally
        {
            Stop(wizardProcess);
            Stop(launcher);
        }
    }

    private static void VerifyInstallation(string setup)
    {
        foreach (string name in new[] { "ChiikawaPet.exe", "README.md", "README.ko.md", "LICENSE", "ARTWORK-NOTICE.md", "Uninstall.exe" })
            Require(File.Exists(Path.Combine(InstallDirectory, name)), "Installed file missing: " + name);
        var setupVersion = FileVersionInfo.GetVersionInfo(setup);
        var appVersion = FileVersionInfo.GetVersionInfo(Path.Combine(InstallDirectory, "ChiikawaPet.exe"));
        string expected = $"{setupVersion.FileMajorPart}.{setupVersion.FileMinorPart}.{setupVersion.FileBuildPart}";
        string actual = $"{appVersion.FileMajorPart}.{appVersion.FileMinorPart}.{appVersion.FileBuildPart}";
        Require(actual == expected, "Installed executable version does not match setup.");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using var entry = hive.OpenSubKey(UninstallKey);
        Require(entry?.GetValue("DisplayVersion") as string == expected, "Installed registry version does not match setup.");
        Require(entry?.GetValue("InstallLocation") as string == InstallDirectory, "Installer did not use the fixed per-user directory.");
        string uninstaller = Path.Combine(InstallDirectory, "Uninstall.exe");
        Require(entry?.GetValue("UninstallString") as string == "\"" + uninstaller + "\"", "Uninstall command is not quoted.");
    }

    private static void CheckFinishLaunch()
    {
        Process? pet = null;
        try
        {
            WaitUntil(() =>
            {
                foreach (var candidate in Process.GetProcessesByName("ChiikawaPet"))
                {
                    if (pet == null && string.Equals(candidate.MainModule?.FileName,
                        Path.Combine(InstallDirectory, "ChiikawaPet.exe"), StringComparison.OrdinalIgnoreCase)) pet = candidate;
                    else candidate.Dispose();
                }
                return pet != null;
            }, "Finish did not launch the installed pet.");
            IntPtr window = IntPtr.Zero;
            WaitUntil(() =>
            {
                Require(!pet!.HasExited, "Finish-launched pet exited before showing its window.");
                EnumWindows((candidate, _) =>
                {
                    GetWindowThreadProcessId(candidate, out uint owner);
                    if (owner == (uint)pet.Id && IsWindowVisible(candidate))
                    {
                        Require(ClassName(candidate) != "#32770", "Finish-launched pet showed an error dialog.");
                        window = candidate;
                    }
                    return true;
                }, IntPtr.Zero);
                return window != IntPtr.Zero;
            }, "Finish-launched pet did not show a native window.");
            Require(PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero), "Could not close the finish-launched pet.");
            Require(pet!.WaitForExit(10000) && pet.ExitCode == 0, "Finish-launched pet did not exit normally.");
        }
        finally { Stop(pet); }
    }

    private static bool RegistryExists()
    {
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using var entry = hive.OpenSubKey(UninstallKey);
        return entry != null;
    }

    private static IntPtr FindWizard()
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, _) =>
        {
            if (IsWindowVisible(window) && ClassName(window) == "#32770")
            {
                var title = new StringBuilder(256);
                GetWindowText(window, title, title.Capacity);
                if (title.ToString().StartsWith("Chiikawa Pet", StringComparison.Ordinal)) found = window;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    private static bool Ready(IntPtr wizard, bool finish)
    {
        IntPtr next = GetDlgItem(wizard, 1);
        IntPtr cancel = GetDlgItem(wizard, 2);
        if (!IsWindowVisible(wizard) || !IsWindowEnabled(next) || IsWindowEnabled(cancel) == finish) return false;
        foreach (IntPtr child in Children(wizard))
            if (IsWindowVisible(child) && ClassName(child) == "msctls_progress32") return false;
        return true;
    }

    private static IntPtr LaunchCheckbox(IntPtr wizard)
    {
        foreach (IntPtr child in Children(wizard))
            if (IsWindowVisible(child) && ClassName(child) == "Button" && (GetWindowLong(child, -16) & 0xF) is 2 or 3)
                return child;
        return IntPtr.Zero;
    }

    private static List<IntPtr> Children(IntPtr parent)
    {
        var children = new List<IntPtr>();
        EnumChildWindows(parent, (window, _) => { children.Add(window); return true; }, IntPtr.Zero);
        return children;
    }

    private static string ClassName(IntPtr window)
    {
        var name = new StringBuilder(64);
        GetClassName(window, name, name.Capacity);
        return name.ToString();
    }

    private static void ClickNext(IntPtr wizard)
    {
        IntPtr next = GetDlgItem(wizard, 1);
        Require(IsWindowVisible(next) && IsWindowEnabled(next), "Wizard navigation button is unavailable.");
        Require(PostMessage(next, 0x00F5, IntPtr.Zero, IntPtr.Zero), "Could not click the native wizard button.");
    }

    private static void Capture(IntPtr window, string path)
    {
        ShowWindow(window, 9);
        SetForegroundWindow(window);
        Thread.Sleep(300);
        Require(GetWindowRect(window, out NativeRect bounds), "Could not read wizard geometry.");
        Require(bounds.Right > bounds.Left && bounds.Bottom > bounds.Top, "Wizard has no visible screenshot area.");
        using var bitmap = new Bitmap(bounds.Right - bounds.Left, bounds.Bottom - bounds.Top);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            IntPtr context = graphics.GetHdc();
            bool printed;
            try { printed = PrintWindow(window, context, 2); }
            finally { graphics.ReleaseHdc(context); }
            if (!printed) graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bitmap.Size);
        }
        bitmap.Save(path, ImageFormat.Png);
    }

    private static bool MutexAvailable()
    {
        using var mutex = new Mutex(false, "Local\\ChiikawaAgentPet");
        bool acquired;
        try { acquired = mutex.WaitOne(0); }
        catch (AbandonedMutexException) { acquired = true; }
        if (acquired) mutex.ReleaseMutex();
        return acquired;
    }

    private static void WaitUntil(Func<bool> condition, string failure, int milliseconds = 20000)
    {
        var timer = Stopwatch.StartNew();
        do
        {
            if (condition()) return;
            Thread.Sleep(50);
        } while (timer.ElapsedMilliseconds < milliseconds);
        throw new SmokeFailure(failure);
    }

    private static void Stop(Process? process)
    {
        if (process == null) return;
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(10000);
            }
        }
        finally { process.Dispose(); }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new SmokeFailure(message);
    }

    private sealed class SmokeFailure(string message) : Exception(message) { }
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }
    private delegate bool WindowCallback(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr window, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out NativeRect bounds);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr window, IntPtr context, uint flags);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
}
