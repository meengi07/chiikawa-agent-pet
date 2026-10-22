using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Windows.Interop;
using Microsoft.Win32;

namespace ChiikawaPet;

internal enum StartupRegistration { Missing, CurrentExecutable, OtherExecutable, Unavailable }

internal sealed class WindowsFeatures : IDisposable
{
    private const int HotkeyId = 0x4350;
    private const string StartupKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string StartupName = "ChiikawaAgentPet";
    private readonly IntPtr handle;
    private readonly Action openPanel;
    private readonly HwndSource? source;
    private bool registered;
    private uint registeredModifiers;
    private uint registeredKey;
    public bool HotkeyRegistered => registered;
    private bool disposed;
    private bool sourceDisposed;

    public WindowsFeatures(IntPtr handle, Action openPanel)
    {
        this.handle = handle;
        this.openPanel = openPanel;
        source = handle == IntPtr.Zero ? null : HwndSource.FromHwnd(handle);
        if (source != null)
        {
            source.AddHook(WindowMessage);
            source.Disposed += SourceDisposed;
        }
    }

    public string? ConfigureHotkey(uint modifiers, uint key)
    {
        if (disposed || sourceDisposed) return "The shortcut cannot be changed after the window has closed.";
        if (source == null) return "The shortcut is unavailable until the app window has loaded.";
        if (key != 0 && ((modifiers & ~0x400Fu) != 0 || key > 0xFE || key == 0x7B
            || key is 0x10 or 0x11 or 0x12 or 0x5B or 0x5C or >= 0xA0 and <= 0xA5))
            return "Choose a valid shortcut key other than a modifier or F12 (reserved by Windows).";

        modifiers |= 0x4000u;
        bool hadPrevious = registered;
        if (registered && key == registeredKey && modifiers == registeredModifiers) return null;
        if (registered)
        {
            if (!UnregisterHotKey(handle, HotkeyId))
                return NativeFailure("The previous shortcut could not be released");
            registered = false;
        }
        if (key == 0) return null;
        if (!RegisterHotKey(handle, HotkeyId, modifiers, key))
        {
            string failure = NativeFailure("The shortcut could not be registered. It may already be in use; choose another shortcut");
            if (!hadPrevious) return failure;
            if (RegisterHotKey(handle, HotkeyId, registeredModifiers, registeredKey))
            {
                registered = true;
                return failure + " The previous shortcut remains active.";
            }
            string restorationFailure = NativeFailure("The previous shortcut could not be restored");
            return failure + " " + restorationFailure + " The shortcut is now disabled.";
        }
        registered = true;
        registeredModifiers = modifiers;
        registeredKey = key;
        return null;
    }

    public string? SetStartup(bool enabled)
    {
        if (disposed) return "Startup preferences cannot be changed after the app has closed.";
        try
        {
            if (!enabled)
            {
                using var existing = Registry.CurrentUser.OpenSubKey(StartupKey, writable: true);
                existing?.DeleteValue(StartupName, throwOnMissingValue: false);
                return null;
            }

            string? executable = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(executable) || !Path.IsPathFullyQualified(executable)
                || executable.IndexOfAny(['"', '\r', '\n']) >= 0)
                return "Startup could not be enabled because the current executable path is unavailable.";
            string command = "\"" + executable + "\"";
            if (command.Length > 260)
                return "Startup could not be enabled because the executable path exceeds the Windows Run limit.";
            using var startup = Registry.CurrentUser.CreateSubKey(StartupKey, writable: true);
            if (startup == null) return "Windows did not allow access to this user's startup preferences.";
            startup.SetValue(StartupName, command, RegistryValueKind.String);
            return null;
        }
        catch (Exception error) when (error is UnauthorizedAccessException or SecurityException or IOException)
        {
            return "Windows did not allow the startup preference to be changed. Check your account permissions or startup policy.";
        }
    }

    public StartupRegistration ReadStartupRegistration(out string? failure)
    {
        failure = null;
        try
        {
            string? executable = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(executable) || !Path.IsPathFullyQualified(executable))
            {
                failure = "Cannot determine the current executable's startup registration.";
                return StartupRegistration.Unavailable;
            }
            using var startup = Registry.CurrentUser.OpenSubKey(StartupKey, writable: false);
            object? configured = startup?.GetValue(StartupName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            if (configured != null && configured is not string)
            {
                failure = "The startup entry has an unsupported format and was left unchanged.";
                return StartupRegistration.Unavailable;
            }
            return ClassifyStartupRegistration(configured as string, executable);
        }
        catch (Exception error) when (error is UnauthorizedAccessException or SecurityException or IOException)
        {
            failure = "Windows did not allow the app's startup registration to be read.";
            return StartupRegistration.Unavailable;
        }
    }

    internal static StartupRegistration ClassifyStartupRegistration(string? configured, string executable)
    {
        if (string.IsNullOrWhiteSpace(configured)) return StartupRegistration.Missing;
        string command = "\"" + executable + "\"";
        return string.Equals(configured, command, StringComparison.OrdinalIgnoreCase)
            ? StartupRegistration.CurrentExecutable : StartupRegistration.OtherExecutable;
    }

    private IntPtr WindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (!disposed && registered && message == 0x0312 && wParam.ToInt64() == HotkeyId)
        {
            handled = true;
            openPanel();
        }
        return IntPtr.Zero;
    }

    private void SourceDisposed(object? sender, EventArgs arguments)
    {
        sourceDisposed = true;
        registered = false;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (registered)
        {
            UnregisterHotKey(handle, HotkeyId);
            registered = false;
        }
        if (source != null)
        {
            if (!sourceDisposed) source.RemoveHook(WindowMessage);
            source.Disposed -= SourceDisposed;
        }
    }

    private static string NativeFailure(string message)
    {
        int code = Marshal.GetLastWin32Error();
        string detail = new Win32Exception(code).Message;
        return $"{message}. {detail} (Windows error {code}).";
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
