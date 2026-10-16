using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace ChiikawaPet;

internal sealed record UpdateRequest(string Target, string CurrentVersion, string Version, bool Installed, int ProcessId, long ProcessStart, string Package)
{
    internal void Write(string path)
    {
        using var stream = File.Create(path);
        using var json = new Utf8JsonWriter(stream);
        json.WriteStartObject();
        json.WriteString("target", Target);
        json.WriteString("currentVersion", CurrentVersion);
        json.WriteString("version", Version);
        json.WriteBoolean("installed", Installed);
        json.WriteNumber("processId", ProcessId);
        json.WriteNumber("processStart", ProcessStart);
        json.WriteString("package", Package);
        json.WriteEndObject();
    }

    internal static UpdateRequest Read(string path)
    {
        if (new FileInfo(path).Length > 8192) throw new InvalidDataException("Invalid update request.");
        using var document = JsonDocument.Parse(File.ReadAllBytes(path));
        var root = document.RootElement;
        return new UpdateRequest(root.GetProperty("target").GetString()!, root.GetProperty("currentVersion").GetString()!,
            root.GetProperty("version").GetString()!, root.GetProperty("installed").GetBoolean(),
            root.GetProperty("processId").GetInt32(), root.GetProperty("processStart").GetInt64(), root.GetProperty("package").GetString()!);
    }
}

internal static class UpdateApply
{
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet";

    internal static void RejectReparse(string path)
    {
        var current = new DirectoryInfo(Path.GetFullPath(path));
        while (current != null)
        {
            if (current.Exists && (current.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Updates do not support symbolic links or junctions in the app path.");
            current = current.Parent;
        }
    }

    internal static void ValidateTarget(string target, string expected, bool installed)
    {
        target = Path.GetFullPath(target).TrimEnd(Path.DirectorySeparatorChar);
        if (target == Path.GetPathRoot(target) || Directory.GetParent(target) == null) throw new IOException("Unsafe app directory.");
        RejectReparse(target);
        ValidatePayload(target, expected);
        ValidateTree(target);
        if (installed)
        {
            string fixedTarget = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "ChiikawaPet");
            using var entry = Registry.CurrentUser.OpenSubKey(UninstallKey);
            if (!target.Equals(fixedTarget, StringComparison.OrdinalIgnoreCase)
                || !target.Equals(entry?.GetValue("InstallLocation") as string, StringComparison.OrdinalIgnoreCase)
                || !File.Exists(Path.Combine(target, "Uninstall.exe")))
                throw new IOException("The installed app location does not match its Windows uninstall entry.");
        }
        else if (File.Exists(Path.Combine(target, "Uninstall.exe")))
            throw new IOException("Cannot identify this installed app. Reinstall the official setup package first.");
    }

    private static void ValidateTree(string directory)
    {
        foreach (string item in Directory.EnumerateFileSystemEntries(directory))
        {
            var attributes = File.GetAttributes(item);
            if ((attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("App contains a symbolic link or junction.");
            if ((attributes & FileAttributes.Directory) != 0) ValidateTree(item);
        }
    }

    private static bool UnsafeSegment(string part)
    {
        if (part.Length == 0 || part is "." or ".." || part.EndsWith('.') || part.EndsWith(' ')) return true;
        foreach (char character in part)
            if (character < 32 || "<>\"|?*".Contains(character)) return true;
        int dot = part.IndexOf('.');
        var stem = part.AsSpan(0, dot < 0 ? part.Length : dot);
        return stem.Equals("CON", StringComparison.OrdinalIgnoreCase) || stem.Equals("PRN", StringComparison.OrdinalIgnoreCase)
            || stem.Equals("AUX", StringComparison.OrdinalIgnoreCase) || stem.Equals("NUL", StringComparison.OrdinalIgnoreCase)
            || (stem.Length == 4 && stem[3] is >= '1' and <= '9'
                && (stem[..3].Equals("COM", StringComparison.OrdinalIgnoreCase) || stem[..3].Equals("LPT", StringComparison.OrdinalIgnoreCase)));
    }

    internal static void ValidatePayload(string directory, string expected)
    {
        UpdateProtocol.ParseVersion(expected);
        string executable = Path.Combine(directory, "ChiikawaPet.exe");
        if (!File.Exists(executable) || (File.GetAttributes(executable) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("The target is not a Chiikawa Pet app.");
        var info = FileVersionInfo.GetVersionInfo(executable);
        string version = $"{info.FileMajorPart}.{info.FileMinorPart}.{info.FileBuildPart}";
        if (version != expected || info.ProductName != "ChiikawaPet") throw new IOException("The app identity or version does not match.");
    }

    internal static void ExtractPortable(string package, string stage, string expected)
    {
        using var zip = ZipFile.OpenRead(package);
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long expanded = 0;
        if (zip.Entries.Count > 25000) throw new InvalidDataException("Too many files in update ZIP.");
        foreach (var entry in zip.Entries)
        {
            string name = entry.FullName;
            string[] segments = name.TrimEnd('/').Split('/');
            if (name.Length == 0 || name.Contains('\\') || name.Contains(':') || name.StartsWith('/')
                || Array.Exists(segments, UnsafeSegment)
                || !names.Add(name.TrimEnd('/')) || ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000
                || (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Unsafe path in update ZIP.");
            expanded = checked(expanded + entry.Length);
            if (expanded > 2L * 1024 * 1024 * 1024) throw new InvalidDataException("Expanded update exceeds its limit.");
            string destination = Path.GetFullPath(Path.Combine(stage, name.Replace('/', Path.DirectorySeparatorChar)));
            if (!destination.StartsWith(stage + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Update ZIP escapes its staging directory.");
            if (name.EndsWith('/')) { Directory.CreateDirectory(destination); continue; }
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            entry.ExtractToFile(destination, overwrite: false);
        }
        ValidatePayload(stage, expected);
        if (!File.Exists(Path.Combine(stage, "ChiikawaPet.Updater.exe"))) throw new InvalidDataException("The update helper is missing from the ZIP.");
    }

    internal static string SessionDirectory(string requestPath)
    {
        string full = Path.GetFullPath(requestPath);
        string session = Path.GetDirectoryName(full)!;
        string cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ChiikawaPet", "Updates");
        if (!string.Equals(Path.GetDirectoryName(session), cache, StringComparison.OrdinalIgnoreCase)
            || !Guid.TryParseExact(Path.GetFileName(session), "N", out _)
            || Path.GetFileName(full) != "request.json"
            || !string.Equals(Path.GetDirectoryName(Environment.ProcessPath), session, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The update helper must run from its private cache session.");
        RejectReparse(session);
        return session;
    }

    internal static async Task Run(string requestPath)
    {
        string session = SessionDirectory(requestPath);
        var request = UpdateRequest.Read(requestPath);
        string target = Path.GetFullPath(request.Target).TrimEnd(Path.DirectorySeparatorChar);
        string package = Path.GetFullPath(request.Package);
        if (Path.GetDirectoryName(package) != session || (File.GetAttributes(package) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("The package must be in the private update session.");
        if (session.StartsWith(target + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The update helper cannot run inside the app being replaced.");
        byte[] manifest = await ReadBounded(Path.Combine(session, "updates.json"), 65536);
        byte[] signature = await ReadBounded(Path.Combine(session, "updates.sig"), 1024);
        var update = UpdateProtocol.Verify(manifest, signature, request.Version, request.CurrentVersion, request.Installed);
        using var packageLock = new FileStream(package, FileMode.Open, FileAccess.Read, FileShare.Read);
        await UpdateProtocol.VerifyPackage(package, update.Asset);
        ValidateTarget(target, request.CurrentVersion, request.Installed);
        using var old = Process.GetProcessById(request.ProcessId);
        if (old.StartTime.ToUniversalTime().Ticks != request.ProcessStart
            || !string.Equals(old.MainModule?.FileName, Path.Combine(target, "ChiikawaPet.exe"), StringComparison.OrdinalIgnoreCase))
            throw new IOException("The running app identity changed.");
        string parent = Path.GetDirectoryName(target)!;
        string token = Guid.NewGuid().ToString("N");
        string stage = Path.Combine(parent, ".ChiikawaPet-stage-" + token);
        string backup = Path.Combine(parent, ".ChiikawaPet-backup-" + token);
        Directory.CreateDirectory(stage);
        bool moved = false;
        Process? restarted = null;
        PortableUpdate? portable = null;
        var registry = new List<(string Name, object Value, RegistryValueKind Kind)>();
        if (request.Installed)
        {
            using var entry = Registry.CurrentUser.OpenSubKey(UninstallKey)!;
            foreach (string name in entry.GetValueNames()) registry.Add((name, entry.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames)!, entry.GetValueKind(name)));
        }
        try
        {
            if (!request.Installed)
            {
                ExtractPortable(package, stage, request.Version);
                portable = new PortableUpdate(target, stage, backup);
            }
            File.WriteAllText(Path.Combine(session, "prepared"), "prepared");
            using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(2));
            while (!File.Exists(Path.Combine(session, "commit")))
            {
                if (File.Exists(Path.Combine(session, "cancel"))) throw new IOException("Update cancelled before applying.");
                await Task.Delay(100, deadline.Token);
            }
            using (var exitDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
                await old.WaitForExitAsync(exitDeadline.Token);
            if (File.Exists(Path.Combine(session, "cancel"))) throw new IOException("Update cancelled.");
            ValidateTarget(target, request.CurrentVersion, request.Installed);
            if (request.Installed)
            {
                Directory.Move(target, backup);
                moved = true;
                var start = new ProcessStartInfo(package) { UseShellExecute = false, CreateNoWindow = true };
                start.ArgumentList.Add("/S");
                using var installer = Process.Start(start) ?? throw new IOException("Cannot start the verified installer.");
                using var installDeadline = new CancellationTokenSource(TimeSpan.FromMinutes(3));
                try { await installer.WaitForExitAsync(installDeadline.Token); }
                catch { if (!installer.HasExited) { installer.Kill(entireProcessTree: true); await installer.WaitForExitAsync(); } throw; }
                if (installer.ExitCode != 0) throw new IOException("The installer could not apply the update.");
            }
            else
            {
                moved = true;
                portable!.Apply();
            }
            RejectReparse(target);
            ValidatePayload(target, request.Version);
            restarted = await Launch(target, session);
            File.WriteAllText(Path.Combine(session, "result"), "updated " + request.Version);
            moved = false;
            try { Directory.Delete(backup, recursive: true); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
        }
        catch
        {
            if (moved)
            {
                if (restarted != null && !restarted.HasExited) { restarted.Kill(entireProcessTree: true); await restarted.WaitForExitAsync(); }
                if (request.Installed)
                {
                    if (Directory.Exists(target)) { RejectReparse(target); Directory.Delete(target, recursive: true); }
                    Directory.Move(backup, target);
                    Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, throwOnMissingSubKey: false);
                    using var restored = Registry.CurrentUser.CreateSubKey(UninstallKey);
                    foreach (var item in registry) restored.SetValue(item.Name, item.Value, item.Kind);
                }
                else portable!.Rollback();
                File.Delete(Path.Combine(session, "started"));
                using var restoredApp = await Launch(target, session, requireAcknowledgement: false);
                File.WriteAllText(Path.Combine(session, "result"), "rolled back");
            }
            else if (old.HasExited && Directory.Exists(target))
            {
                using var unchangedApp = await Launch(target, session, requireAcknowledgement: false);
            }
            throw;
        }
        finally
        {
            restarted?.Dispose();
            if (Directory.Exists(stage)) Directory.Delete(stage, recursive: true);
        }
    }

    private static async Task<byte[]> ReadBounded(string path, int limit)
    {
        if (new FileInfo(path).Length > limit || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Invalid update metadata file.");
        return await File.ReadAllBytesAsync(path);
    }

    private static async Task<Process> Launch(string target, string session, bool requireAcknowledgement = true)
    {
        string ready = Path.Combine(session, "started");
        File.Delete(ready);
        var start = new ProcessStartInfo(Path.Combine(target, "ChiikawaPet.exe")) { UseShellExecute = false, WorkingDirectory = target };
        start.Environment["CHIIKAWA_UPDATE_READY"] = ready;
        if (!requireAcknowledgement) start.Environment["CHIIKAWA_UPDATE_FAILED"] = "1";
        var launched = Process.Start(start) ?? throw new IOException("Cannot restart Chiikawa Pet.");
        try
        {
            for (int tick = 0; tick < 200; tick++)
            {
                if (launched.HasExited) throw new IOException("The updated app exited during startup.");
                if ((requireAcknowledgement && tick >= 10 && File.Exists(ready)) || (!requireAcknowledgement && tick >= 20)) return launched;
                await Task.Delay(100);
            }
            throw new IOException("The updated app did not become ready.");
        }
        catch
        {
            if (!launched.HasExited) { launched.Kill(entireProcessTree: true); await launched.WaitForExitAsync(); }
            launched.Dispose();
            throw;
        }
    }
}
