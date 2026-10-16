using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

internal static class Program
{
    private const string MutexName = "Local\\ChiikawaAgentPet";
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ChiikawaPet", "settings.json");
    private static readonly Type PetType = typeof(ChiikawaPet.PetApp);
    private static int childExitCode;

    [STAThread]
    private static int Main(string[] arguments)
    {
        if (arguments.Length > 0 && (arguments[0] == "--installer" || arguments[0] == "--uninstaller"))
        {
            if (arguments.Length == 3)
                return InstallerSmoke.Run(arguments[1], arguments[2], arguments[0] == "--uninstaller");
            Console.Error.WriteLine("Usage: --installer <setup.exe> <screenshots-dir> | --uninstaller <Uninstall.exe> <screenshots-dir>");
            return 1;
        }
        if (arguments.Length > 0 && arguments[0] == "--executable")
        {
            if (arguments.Length == 2) return ExecutableSmoke.Run(arguments[1]);
            Console.Error.WriteLine("Usage: --executable <ChiikawaPet.exe>");
            return 1;
        }
        if (arguments.Length == 1) return RunChild(arguments[0]);
        using (var guard = new Mutex(false, MutexName))
        {
            bool acquired;
            try { acquired = guard.WaitOne(0); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) { Console.Error.WriteLine("Close the running pet before the UI smoke."); return 1; }
            guard.ReleaseMutex();
        }
        byte[]? original = File.Exists(SettingsPath) ? File.ReadAllBytes(SettingsPath) : null;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            File.WriteAllText(SettingsPath,
                "{\"Language\":\"en\",\"Visible\":true,\"Wanders\":false,\"X\":80,\"Y\":80,\"Scale\":0.65}");
            bool passed = RunScenario("interaction");
            passed = RunScenario("native-panel-close") && passed;
            passed = RunScenario("native-close") && passed;
            passed = RunScenario("relaunch") && passed;
            var previewSettings = ChiikawaPet.Settings.Load(SettingsPath);
            previewSettings.AutomaticUpdates = true;
            previewSettings.Save(SettingsPath);
            passed = RunScenario("preview-updates") && passed;
            return passed ? 0 : 1;
        }
        finally
        {
            mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
            if (original != null) File.WriteAllBytes(SettingsPath, original);
            else File.Delete(SettingsPath);
        }
    }

    private static bool RunScenario(string scenario)
    {
        var start = new ProcessStartInfo("dotnet") { UseShellExecute = false };
        start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
        start.ArgumentList.Add(scenario);
        using var child = Process.Start(start)!;
        if (!child.WaitForExit(20000))
        {
            child.Kill(entireProcessTree: true);
            child.WaitForExit();
            Console.Error.WriteLine($"FAIL {scenario}: process did not terminate after native close.");
            return false;
        }
        using var instance = new Mutex(false, MutexName);
        bool released;
        try { released = instance.WaitOne(0); }
        catch (AbandonedMutexException) { released = true; }
        if (released) instance.ReleaseMutex();
        bool passed = child.ExitCode == 0 && released;
        Console.WriteLine($"{(passed ? "PASS" : "FAIL")} {scenario}: exit and single-instance mutex release.");
        return passed;
    }

    private static int RunChild(string scenario)
    {
        Dispatcher.CurrentDispatcher.UnhandledExceptionFilter += (_, error) =>
        {
            childExitCode = 1;
            Console.Error.WriteLine($"FAIL dispatcher: {error.Exception.GetType().FullName}");
            foreach (var frame in new StackTrace(error.Exception, false).GetFrames())
            {
                var method = frame.GetMethod();
                Console.Error.WriteLine($"  {method?.DeclaringType?.FullName}.{method?.Name}");
            }
        };
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(async () =>
        {
            try
            {
                var window = Application.Current.MainWindow;
                Require(window != null && window.IsVisible, "Pet main window was not shown (including on relaunch).");
                using var saved = JsonDocument.Parse(File.ReadAllText(SettingsPath));
                Near(window!.Left, saved.RootElement.GetProperty("X").GetDouble(), "Reloaded X");
                Near(window.Top, saved.RootElement.GetProperty("Y").GetDouble(), "Reloaded Y");
                if (scenario == "interaction") await CheckInteraction(window);
                if (scenario == "preview-updates")
                    Require(!((DispatcherTimer)Field("updateTimer").GetValue(window)!).IsEnabled
                        && !(bool)Field("updating").GetValue(window)!
                        && (string)Field("updateStatus").GetValue(window)! == "업데이트를 확인하지 않았습니다",
                        "Preview started updater I/O with persisted automatic updates enabled.");
                if (scenario == "native-panel-close")
                {
                    await Move(new Point(SystemParameters.WorkArea.Right - 5, SystemParameters.WorkArea.Bottom - 5));
                    ((Button)window.Content).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    await Task.Delay(100);
                    var usage = Field("panel").GetValue(window) as Window;
                    Require(usage?.IsVisible == true && !window.IsMouseOver, "Usage close fixture was not visible and outside the pet.");
                    Require(PostMessage(new WindowInteropHelper(usage!).Handle, 0x0010, IntPtr.Zero, IntPtr.Zero), "Could not natively close usage.");
                    await Task.Delay(300);
                    Require(childExitCode == 0 && window.IsVisible && Field("panel").GetValue(window) == null,
                        "Native usage close raised an exception or closed the pet.");
                }
                Require(PostMessage(new WindowInteropHelper(window).Handle, 0x0010, IntPtr.Zero, IntPtr.Zero),
                    "Could not post native WM_CLOSE.");
            }
            catch (Exception error)
            {
                childExitCode = 1;
                mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
                Console.Error.WriteLine($"FAIL {scenario}: {error.GetType().Name}: {error.Message}");
                Application.Current.Shutdown();
            }
        }));
        // Preview prevents credential access at startup; the fixture stops refresh before enabling settings writes.
        PetType.GetMethod("Main")!.Invoke(null, new object[] { new[] { "--preview", "0" } });
        return childExitCode;
    }

    private static async Task CheckInteraction(Window window)
    {
        ((DispatcherTimer)Field("animation").GetValue(window)!).Stop();
        ((DispatcherTimer)Field("refreshTimer").GetValue(window)!).Stop();
        Field("refreshing").SetValue(window, true);
        Field("preview").SetValue(window, null);
        var button = (Button)window.Content;
        var origin = new Point(window.Left, window.Top);
        var cursor = OpaquePoint(window);
        await Move(cursor);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        await Task.Delay(100);
        Require(button.IsMouseCaptured, "Native press did not capture the pet button; an interactive desktop is required.");
        await Move(cursor + new Vector(1, 0));
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        await Task.Delay(100);
        Require(Field("panel").GetValue(window) is Window, "Sub-threshold click did not open usage.");
        Near(window.Left, origin.X, "Click X");
        Near(window.Top, origin.Y, "Click Y");
        Call(window, "ClosePanel");

        cursor = OpaquePoint(window);
        await Move(cursor);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        await Task.Delay(100);
        Require(button.IsMouseCaptured, "Drag press did not capture the pet button.");
        await Move(cursor + new Vector(48, 30));
        var transform = PresentationSource.FromVisual(window)!.CompositionTarget!.TransformFromDevice;
        var delta = transform.Transform(new Vector(48, 30));
        Near(window.Left, origin.X + delta.X, "DPI-aware drag X");
        Near(window.Top, origin.Y + delta.Y, "DPI-aware drag Y");
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        await Task.Delay(100);
        Require(Field("panel").GetValue(window) == null, "Drag incorrectly opened usage.");
        using (var saved = JsonDocument.Parse(File.ReadAllText(SettingsPath)))
        {
            Near(saved.RootElement.GetProperty("X").GetDouble(), window.Left, "Persisted drag X");
            Near(saved.RootElement.GetProperty("Y").GetDouble(), window.Top, "Persisted drag Y");
        }

        cursor = OpaquePoint(window);
        await Move(cursor);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        await Task.Delay(100);
        Require(button.IsMouseCaptured, "Capture-loss press did not capture.");
        Mouse.Capture(null);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        await Task.Delay(100);
        Require(Field("panel").GetValue(window) == null, "Lost capture produced a click.");

        window.Activate();
        Require(button.Focus(), "Pet button could not receive keyboard focus.");
        var source = PresentationSource.FromVisual(button)!;
        button.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, Environment.TickCount, Key.Space)
            { RoutedEvent = Keyboard.KeyDownEvent });
        button.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, Environment.TickCount, Key.Space)
            { RoutedEvent = Keyboard.KeyUpEvent });
        Require(Field("panel").GetValue(window) is Window, "WPF Space key did not retain native button click behavior.");
        Call(window, "ClosePanel");

        var tray = (Forms.NotifyIcon)Field("tray").GetValue(window)!;
        var visibility = (Forms.ToolStripMenuItem)tray.ContextMenuStrip!.Items[3];
        visibility.PerformClick();
        await Task.Delay(100);
        Require(!window.IsVisible && tray.Visible, "Explicit hide did not retain the live tray.");
        tray.ContextMenuStrip.Items[0].PerformClick();
        Require(Field("panel").GetValue(window) is Window, "Hidden pet tray could not open usage.");
        Call(window, "ClosePanel");
        visibility.PerformClick();
        Require(window.IsVisible && tray.Visible, "Tray could not show the hidden pet again.");
        Field("updating").SetValue(window, true);
        Call(window, "ToggleAutomaticUpdates");
        var updateTimer = (DispatcherTimer)Field("updateTimer").GetValue(window)!;
        Require(updateTimer.IsEnabled && updateTimer.Interval == TimeSpan.FromHours(6), "Automatic update cadence is not six hours.");
        using (var saved = JsonDocument.Parse(File.ReadAllText(SettingsPath)))
            Require(saved.RootElement.GetProperty("AutomaticUpdates").GetBoolean(), "Automatic update opt-in did not persist.");
        using var automaticCancellation = new CancellationTokenSource();
        Field("automaticUpdate").SetValue(window, true);
        Field("updateCancellation").SetValue(window, automaticCancellation);
        Call(window, "ToggleAutomaticUpdates");
        Require(!updateTimer.IsEnabled, "Disabling automatic updates did not stop the timer.");
        Require(automaticCancellation.IsCancellationRequested, "Disabling automatic updates did not cancel an in-flight automatic update.");
        Field("automaticUpdate").SetValue(window, false);
        Field("updateCancellation").SetValue(window, null);
        Field("updating").SetValue(window, false);
        Require(tray.ContextMenuStrip.Items.ContainsKey("update-check"), "Manual update action missing from tray.");
        Console.WriteLine("PASS native drag/click, persisted coordinates, capture loss, routed Space key, hide/tray/show.");
    }

    private static Point OpaquePoint(Window window)
    {
        int width = (int)Math.Ceiling(window.ActualWidth), height = (int)Math.Ceiling(window.ActualHeight);
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var pixels = new byte[width * height * 4];
        bitmap.CopyPixels(pixels, width * 4, 0);
        for (int radius = 0; radius < Math.Max(width, height); radius++)
            for (int y = Math.Max(0, height / 2 - radius); y <= Math.Min(height - 1, height / 2 + radius); y++)
                for (int x = Math.Max(0, width / 2 - radius); x <= Math.Min(width - 1, width / 2 + radius); x++)
                    if (pixels[(y * width + x) * 4 + 3] > 240)
                        return window.PointToScreen(new Point(x + 0.5, y + 0.5));
        throw new InvalidOperationException("Pet did not render an opaque mouse target.");
    }

    private static async Task Move(Point point)
    {
        Require(SetCursorPos((int)Math.Round(point.X), (int)Math.Round(point.Y)), "Could not move the native cursor.");
        await Task.Delay(100);
    }

    private static FieldInfo Field(string name) => PetType.GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!;
    private static void Call(Window window, string name) => PetType.GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, null);
    private static void Near(double actual, double expected, string label) => Require(Math.Abs(actual - expected) < 1.5, $"{label}: expected {expected:F2}, got {actual:F2}.");
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(IntPtr handle, uint message, IntPtr wParam, IntPtr lParam);
}
