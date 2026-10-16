using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;

internal static class ExecutableSmoke
{
    private const string MutexName = "Local\\ChiikawaAgentPet";
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ChiikawaPet", "settings.json");
    private static string stage = "launch";

    public static int Run(string executable)
    {
        try
        {
            RunIsolated(Path.GetFullPath(executable));
            Console.WriteLine("PASS executable: ordinary mode, live animation/refresh, isolated missing-login state.");
            return 0;
        }
        catch (Exception error)
        {
            string detail = error is SmokeFailure ? error.Message : error.GetType().Name + " (details redacted)";
            Console.Error.WriteLine($"FAIL executable {stage}: {detail}");
            return 1;
        }
    }

    private static void RunIsolated(string executable)
    {
        Require(File.Exists(executable), "Executable does not exist.");
        Require(MutexAvailable(), "Close the running pet before the executable smoke; settings were not changed.");
        byte[]? original = File.Exists(SettingsPath) ? File.ReadAllBytes(SettingsPath) : null;
        string isolation = Path.Combine(Path.GetTempPath(), "chiikawa-executable-" + Guid.NewGuid().ToString("N"));
        Process? child = null;
        try
        {
            string claude = Path.Combine(isolation, "claude");
            string codex = Path.Combine(isolation, "codex");
            Directory.CreateDirectory(claude);
            Directory.CreateDirectory(codex);
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            File.WriteAllText(SettingsPath,
                "{\"Language\":\"en\",\"Character\":\"chiikawa\",\"Visible\":true,\"Wanders\":true,\"X\":160,\"Y\":160,\"Scale\":0.65}");
            var start = new ProcessStartInfo(executable)
            {
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(executable)!
            };
            start.Environment["CLAUDE_CONFIG_DIR"] = claude;
            start.Environment["CODEX_HOME"] = codex;
            child = Process.Start(start);
            Require(child != null, "Windows did not start the executable.");
            Exercise(child!);
        }
        finally
        {
            mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
            try
            {
                if (child != null)
                {
                    try
                    {
                        if (!child.HasExited)
                        {
                            child.Kill();
                            Require(child.WaitForExit(5000), "Launched process could not be stopped; settings restoration is unsafe.");
                        }
                    }
                    finally { child.Dispose(); }
                }
            }
            finally
            {
                if (original != null) File.WriteAllBytes(SettingsPath, original);
                else File.Delete(SettingsPath);
                if (Directory.Exists(isolation)) Directory.Delete(isolation, recursive: true);
            }
        }
    }

    private static void Exercise(Process child)
    {
        Console.WriteLine("executable launch: waiting for ordinary-mode pet (empty credential directories).");
        IntPtr pet = IntPtr.Zero;
        var timer = Stopwatch.StartNew();
        while (pet == IntPtr.Zero && timer.ElapsedMilliseconds < 15000)
        {
            CheckHealth(child);
            foreach (IntPtr window in Windows(child.Id))
            {
                string title = Text(window);
                if (title is "Chiikawa Pet" or "Chiikawa pet" or "치이카와 펫") pet = window;
            }
            if (pet == IntPtr.Zero) Thread.Sleep(50);
        }
        Require(pet != IntPtr.Zero, "Visible pet window was not found; an interactive Windows desktop is required.");
        Move(OpaqueTarget(pet));
        Pause(child, 500);
        Console.WriteLine("PASS executable launch: visible pet, process alive, no error dialog.");

        stage = "click";
        Console.WriteLine("executable click: injecting native left press/release.");
        Move(OpaqueTarget(pet));
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        try { Pause(child, 100); }
        finally { mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); }
        IntPtr panel = IntPtr.Zero;
        timer.Restart();
        while (panel == IntPtr.Zero && timer.ElapsedMilliseconds < 5000)
        {
            CheckHealth(child);
            panel = UsagePanel(child.Id);
            if (panel == IntPtr.Zero) Thread.Sleep(50);
        }
        Require(panel != IntPtr.Zero, "Native click did not show the usage panel.");
        Pause(child, 500);
        Require(IsWindowVisible(panel), "Usage panel disappeared after the click.");
        Console.WriteLine("PASS executable click: usage panel visible without error or process exit.");
        Require(PostMessage(panel, 0x0010, IntPtr.Zero, IntPtr.Zero), "Could not natively close the usage panel.");
        timer.Restart();
        while (IsWindowVisible(panel) && timer.ElapsedMilliseconds < 3000) Pause(child, 50);
        Require(!IsWindowVisible(panel), "Usage panel did not close before drag.");

        stage = "drag";
        Console.WriteLine("executable drag: injecting native movement with left button held.");
        NativePoint target = OpaqueTarget(pet);
        Move(target);
        Pause(child, 100);
        Require(GetWindowRect(pet, out NativeRect before), "Could not read pet geometry before drag.");
        uint dpi = GetDpiForWindow(pet);
        Require(dpi != 0, "Could not read pet DPI.");
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        try
        {
            Pause(child, 100);
            for (int step = 1; step <= 8; step++)
            {
                Move(new NativePoint(target.X + step * 8, target.Y + step * 5));
                Pause(child, 50);
            }
        }
        finally { mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); }
        Pause(child, 250);
        Require(GetWindowRect(pet, out NativeRect after), "Could not read pet geometry after drag.");
        Require(Math.Abs(after.Left - before.Left - 64) <= 3 && Math.Abs(after.Top - before.Top - 40) <= 3,
            $"Native drag displacement mismatch: before=({before.Left},{before.Top}), after=({after.Left},{after.Top}), target=({target.X},{target.Y}), DPI={dpi}; expected (+64,+40).");
        Require(UsagePanel(child.Id) == IntPtr.Zero, "Drag incorrectly opened the usage panel.");
        Console.WriteLine("PASS executable drag: actual pet window moved, no panel/error/exit.");

        stage = "persist";
        Console.WriteLine("executable persist: reading actual settings saved by mouse release.");
        using (var saved = JsonDocument.Parse(File.ReadAllBytes(SettingsPath)))
        {
            double x = saved.RootElement.GetProperty("X").GetDouble();
            double y = saved.RootElement.GetProperty("Y").GetDouble();
            double scale = dpi / 96.0;
            Require(double.IsFinite(x) && double.IsFinite(y)
                && Math.Abs(x * scale - after.Left) <= 3 && Math.Abs(y * scale - after.Top) <= 3,
                "Persisted drag coordinates do not match the actual native window position.");
            Require(Math.Abs(x - 160) > 3 || Math.Abs(y - 160) > 3, "Drag did not change the persisted fixture position.");
            Require(saved.RootElement.GetProperty("Wanders").GetBoolean(), "Wandering was not retained in ordinary mode.");
        }
        Pause(child, 500);
        Console.WriteLine("PASS executable persist: changed coordinates match the DPI-aware window position.");

        stage = "close";
        Console.WriteLine("executable close: posting native WM_CLOSE to the pet window.");
        Require(PostMessage(pet, 0x0010, IntPtr.Zero, IntPtr.Zero), "Could not post native WM_CLOSE to pet.");
        timer.Restart();
        while (!child.HasExited && timer.ElapsedMilliseconds < 10000)
        {
            CheckDialogs(child.Id);
            Thread.Sleep(50);
        }
        Require(child.HasExited, "Process did not exit after native close.");
        Require(child.ExitCode == 0, $"Native close returned process exit code {child.ExitCode}.");
        Require(MutexAvailable(), "Single-instance mutex was not released after native close.");
        Console.WriteLine("PASS executable close: process exited normally and single-instance mutex released.");
    }

    private static NativePoint OpaqueTarget(IntPtr pet)
    {
        Require(GetWindowRect(pet, out NativeRect bounds), "Could not read visible pet geometry.");
        int centerX = (bounds.Left + bounds.Right) / 2;
        int centerY = (bounds.Top + bounds.Bottom) / 2;
        // Layered-window hit testing skips fully transparent rendered pixels, unlike the button's bounding box.
        for (int radius = 0; radius < Math.Min(bounds.Right - bounds.Left, bounds.Bottom - bounds.Top) / 3; radius += 2)
            for (int y = centerY - radius; y <= centerY + radius; y += 2)
                for (int x = centerX - radius; x <= centerX + radius; x += 2)
                {
                    bool solid = true;
                    for (int dy = -2; dy <= 2 && solid; dy += 2)
                        for (int dx = -2; dx <= 2; dx += 2)
                            if (GetAncestor(WindowFromPoint(new NativePoint(x + dx, y + dy)), 2) != pet) { solid = false; break; }
                    if (solid) return new NativePoint(x, y);
                }
        throw new SmokeFailure("No opaque native hit-test target found on the rendered pet; check desktop visibility.");
    }

    private static void Move(NativePoint point) => Require(SetCursorPos(point.X, point.Y), "Could not move the native cursor.");

    private static void Pause(Process child, int milliseconds)
    {
        var timer = Stopwatch.StartNew();
        do { CheckHealth(child); Thread.Sleep(25); } while (timer.ElapsedMilliseconds < milliseconds);
    }

    private static void CheckHealth(Process child)
    {
        CheckDialogs(child.Id);
        Require(!child.HasExited, "Executable exited before native close.");
    }

    private static IntPtr UsagePanel(int processId)
    {
        foreach (IntPtr window in Windows(processId))
            if (Text(window) is "Chiikawa usage" or "치이카와 사용량") return window;
        return IntPtr.Zero;
    }

    private static void CheckDialogs(int processId)
    {
        foreach (IntPtr window in Windows(processId))
        {
            var className = new StringBuilder(64);
            GetClassName(window, className, className.Capacity);
            if (className.ToString() != "#32770") continue;
            string safeText = "Unrecognized product dialog (text redacted).";
            EnumChildWindows(window, (control, _) =>
            {
                var message = new StringBuilder(256);
                SendMessageTimeout(control, 0x000D, (UIntPtr)(uint)message.Capacity, message, 0x0002, 200, out UIntPtr result);
                string text = message.ToString();
                if (text is "An application error occurred. Restart the pet."
                    or "앱 실행 중 오류가 발생했습니다. 펫을 다시 실행하세요."
                    or "Cannot read pet resources or settings. Extract the app again and check its settings file."
                    or "펫 리소스 또는 설정을 읽을 수 없습니다. 실행 파일을 다시 압축 해제하고 설정 파일을 확인하세요."
                    or "Cannot save settings. Check write access to %LOCALAPPDATA%\\ChiikawaPet."
                    or "펫 설정을 저장할 수 없습니다. %LOCALAPPDATA%\\ChiikawaPet 폴더의 쓰기 권한을 확인하세요."
                    or "Already running. Click the pet icon in the notification area."
                    or "이미 실행 중입니다. 알림 영역의 펫 아이콘을 클릭하세요.") safeText = text;
                return true;
            }, IntPtr.Zero);
            throw new SmokeFailure("Product error dialog: " + safeText);
        }
    }

    private static List<IntPtr> Windows(int processId)
    {
        var windows = new List<IntPtr>();
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out uint owner);
            if (owner == (uint)processId && IsWindowVisible(window)) windows.Add(window);
            return true;
        }, IntPtr.Zero);
        return windows;
    }

    private static string Text(IntPtr window)
    {
        var text = new StringBuilder(256);
        GetWindowText(window, text, text.Capacity);
        return text.ToString();
    }

    private static bool MutexAvailable()
    {
        using var guard = new Mutex(false, MutexName);
        bool acquired;
        try { acquired = guard.WaitOne(0); }
        catch (AbandonedMutexException) { acquired = true; }
        if (acquired) guard.ReleaseMutex();
        return acquired;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new SmokeFailure(message);
    }

    private sealed class SmokeFailure(string message) : Exception(message) { }
    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint(int x, int y) { public int X = x, Y = y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }
    private delegate bool WindowCallback(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(
        IntPtr window, uint message, UIntPtr wParam, StringBuilder text, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out NativeRect bounds);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(NativePoint point);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
