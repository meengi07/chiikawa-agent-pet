using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace ChiikawaPet;

internal sealed class Updates
{
    internal static string CacheRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ChiikawaPet", "Updates");
    internal static string AppVersion => typeof(Updates).Assembly.GetName().Version is { } version ? $"{version.Major}.{version.Minor}.{version.Build}" : "0.0.0";
    internal static string TargetDirectory => Path.GetFullPath(AppContext.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar);
    internal static bool Installed
    {
        get
        {
            using var entry = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet");
            return string.Equals(entry?.GetValue("InstallLocation") as string, TargetDirectory, StringComparison.OrdinalIgnoreCase)
                && File.Exists(Path.Combine(TargetDirectory, "Uninstall.exe"));
        }
    }

    internal async Task<VerifiedUpdate?> Check(CancellationToken cancellation)
    {
        if (RuntimeInformation.OSArchitecture != Architecture.X64 || RuntimeInformation.ProcessArchitecture != Architecture.X64)
            throw new PlatformNotSupportedException("Automatic packages support Windows x64 only. Install the matching release manually on this architecture.");
        byte[] latest = await UpdateProtocol.DownloadBytes("https://api.github.com/repos/meengi07/chiikawa-agent-pet/releases/latest", 65536, cancellation, api: true);
        string version = LatestVersion(latest);
        if (UpdateProtocol.ParseVersion(version) <= UpdateProtocol.ParseVersion(AppVersion)) return null;
        string release = UpdateProtocol.ReleaseBase + version + "/";
        byte[] manifest = await UpdateProtocol.DownloadBytes(release + "updates.json", 65536, cancellation);
        byte[] signature = await UpdateProtocol.DownloadBytes(release + "updates.sig", 1024, cancellation);
        return UpdateProtocol.Verify(manifest, signature, version, AppVersion, Installed);
    }

    internal static string LatestVersion(byte[] bytes)
    {
        using var document = JsonDocument.Parse(bytes);
        var root = document.RootElement;
        if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean())
            throw new InvalidDataException("The latest release is not stable.");
        string tag = root.GetProperty("tag_name").GetString() ?? "";
        if (!tag.StartsWith('v')) throw new InvalidDataException("Invalid release tag.");
        string version = tag[1..];
        UpdateProtocol.ParseVersion(version);
        return version;
    }

    internal async Task Prepare(VerifiedUpdate update, CancellationToken cancellation)
    {
        await Task.Run(() => UpdateApply.ValidateTarget(TargetDirectory, AppVersion, Installed), cancellation);
        UpdateApply.RejectReparse(CacheRoot);
        Directory.CreateDirectory(CacheRoot);
        string session = Path.Combine(CacheRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(session);
        string package = Path.Combine(session, update.Asset.Name);
        try
        {
            await using (var output = new FileStream(package, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
                await UpdateProtocol.Download(update.Asset.Url, output, update.Asset.Size, cancellation);
            await UpdateProtocol.VerifyPackage(package, update.Asset, cancellation);
            await File.WriteAllBytesAsync(Path.Combine(session, "updates.json"), update.Manifest, cancellation);
            await File.WriteAllBytesAsync(Path.Combine(session, "updates.sig"), update.Signature, cancellation);
            string helper = Path.Combine(session, "ChiikawaPet.Updater.exe");
            File.Copy(Path.Combine(TargetDirectory, "ChiikawaPet.Updater.exe"), helper);
            var request = new UpdateRequest(TargetDirectory, AppVersion, update.Version, Installed,
                Environment.ProcessId, Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks, package);
            string requestPath = Path.Combine(session, "request.json");
            request.Write(requestPath);
            var start = new ProcessStartInfo(helper) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = session };
            start.ArgumentList.Add(requestPath);
            using var process = Process.Start(start) ?? throw new IOException("Cannot start the update helper.");
            string prepared = Path.Combine(session, "prepared");
            while (!File.Exists(prepared))
            {
                cancellation.ThrowIfCancellationRequested();
                if (process.HasExited) throw new IOException("The update helper could not prepare the update. The current app has not changed.");
                await Task.Delay(100, cancellation);
            }
            cancellation.ThrowIfCancellationRequested();
            File.WriteAllText(Path.Combine(session, "commit"), "apply");
        }
        catch
        {
            File.WriteAllText(Path.Combine(session, "cancel"), "cancel");
            throw;
        }
    }

    internal static void AcknowledgeStartup()
    {
        string? ready = Environment.GetEnvironmentVariable("CHIIKAWA_UPDATE_READY");
        Environment.SetEnvironmentVariable("CHIIKAWA_UPDATE_READY", null);
        if (ready == null) return;
        string full = Path.GetFullPath(ready);
        if (!full.StartsWith(CacheRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || Path.GetFileName(full) != "started") return;
        UpdateApply.RejectReparse(Path.GetDirectoryName(full)!);
        File.WriteAllText(full, "started");
    }
}
