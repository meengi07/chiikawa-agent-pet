using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.IO.Compression;
using ChiikawaPet;

internal static class UpdateChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Check(bool condition, string reason)
        {
            if (!condition) throw new Exception(reason);
            checks++;
        }
        void Reject(Action action, string reason)
        {
            try { action(); }
            catch (Exception error) when (error is IOException or InvalidDataException or JsonException or CryptographicException or FormatException or InvalidOperationException or KeyNotFoundException or HttpRequestException) { checks++; return; }
            throw new Exception(reason);
        }
        foreach (string version in new[] { "1.2.0", "0.0.0", "65535.65535.65535" })
            Check(UpdateProtocol.ParseVersion(version).ToString() == version, "Stable numeric version accepted");
        foreach (string version in new[] { "v1.2.0", "01.2.0", "1.2", "1.2.3.4", "1.2.3-beta", "65536.0.0", "-1.0.0", "1.2.0\n" })
            Reject(() => UpdateProtocol.ParseVersion(version), "Invalid stable version accepted: " + version);
        Check(UpdateProtocol.ParseVersion("1.10.0") > UpdateProtocol.ParseVersion("1.9.9"), "Versions compare numerically");
        foreach (string uri in new[] { "http://github.com/release", "https://evil.invalid/release", "https://github.com.evil.invalid/", "https://github.com:8443/", "https://user@github.com/" })
            Check(!UpdateProtocol.AllowedReleaseUri(new Uri(uri)), "Unsafe package redirect accepted");
        Check(UpdateProtocol.AllowedReleaseUri(new Uri("https://release-assets.githubusercontent.com/file")), "GitHub release redirect accepted");
        using var signing = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        string key = signing.ExportSubjectPublicKeyInfoPem();
        string name = "ChiikawaPet-1.2.0-win-x64.zip";
        string hash = new string('a', 64);
        string asset = JsonSerializer.Serialize(new { name, url = UpdateProtocol.ReleaseBase + "1.2.0/" + name, sha256 = hash, size = 4 });
        byte[] Manifest(string assets, string version = "1.2.0") => Encoding.UTF8.GetBytes($"{{\"schemaVersion\":1,\"version\":\"{version}\",\"assets\":[{assets}]}}");
        byte[] Sign(byte[] bytes) => Encoding.ASCII.GetBytes(Convert.ToBase64String(signing.SignData(bytes, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)) + "\n");
        VerifiedUpdate Verify(byte[] bytes, string current = "1.1.6", bool installed = false) => UpdateProtocol.Verify(bytes, Sign(bytes), "1.2.0", current, installed, key);
        var manifest = Manifest(asset);
        Check(Verify(manifest).Asset.Name == name, "DER signature over raw manifest accepted");
        Reject(() => UpdateProtocol.Verify(manifest, Sign(manifest), "1.2.0", "1.1.6", false), "Fixture signer must not match production pin");
        byte[] changed = (byte[])manifest.Clone();
        changed[0] = (byte)' ';
        Reject(() => UpdateProtocol.Verify(changed, Sign(manifest), "1.2.0", "1.1.6", false, key), "Altered raw bytes accepted");
        Reject(() => UpdateProtocol.Verify(manifest, Encoding.ASCII.GetBytes("invalid"), "1.2.0", "1.1.6", false, key), "Malformed signature accepted");
        Reject(() => Verify(manifest, "1.2.0"), "Equal release accepted");
        Reject(() => Verify(manifest, "2.0.0"), "Downgrade accepted");
        Reject(() => Verify(manifest, installed: true), "Wrong package kind accepted");
        Reject(() => Verify(Manifest(asset + "," + asset)), "Duplicate asset accepted");
        Reject(() => Verify(Manifest(asset, "1.2.1")), "Mismatched signed version accepted");
        Reject(() => Verify(Manifest(asset.Replace("https://github.com", "https://evil.invalid"))), "Noncanonical signed package URL accepted");
        Reject(() => Verify(Manifest(asset.Replace(hash, hash.ToUpperInvariant()))), "Noncanonical SHA accepted");
        Reject(() => Verify(Manifest(asset.Replace("\"size\":4", "\"size\":536870913"))), "Oversized signed package accepted");
        Reject(() => Verify(Manifest(asset).Concat(new byte[65536]).ToArray()), "Oversized manifest accepted");
        Reject(() => Updates.LatestVersion(Encoding.UTF8.GetBytes("{\"draft\":false,\"prerelease\":true,\"tag_name\":\"v1.2.0\"}")), "Prerelease feed accepted");
        Reject(() => Updates.LatestVersion(Encoding.UTF8.GetBytes("{\"draft\":true,\"prerelease\":false,\"tag_name\":\"v1.2.0\"}")), "Draft feed accepted");
        Reject(() => Updates.LatestVersion(Encoding.UTF8.GetBytes("{\"draft\":false,\"prerelease\":false,\"tag_name\":\"v01.2.0\"}")), "Malformed feed tag accepted");
        using (var output = new MemoryStream())
        {
            var failed = new UpdateTransport(fail: true);
            Reject(() => UpdateProtocol.Download(UpdateProtocol.ReleaseBase + "1.2.0/package", output, 100, CancellationToken.None, transport: failed).GetAwaiter().GetResult(), "Network failure was swallowed");
            Check(output.Length == 0 && failed.Requests == 1, "Network failure wrote no package and did not retry");
        }
        using (var output = new MemoryStream())
        {
            var redirected = new UpdateTransport(fail: false);
            Reject(() => UpdateProtocol.Download(UpdateProtocol.ReleaseBase + "1.2.0/package", output, 100, CancellationToken.None, transport: redirected).GetAwaiter().GetResult(), "Unsafe HTTP redirect was followed");
            Check(output.Length == 0 && redirected.Requests == 1, "Unsafe redirect never contacted another host");
        }
        string temporary = Path.Combine(Path.GetTempPath(), "chiikawa-update-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        try
        {
            string file = Path.Combine(temporary, "package");
            File.WriteAllBytes(file, [1, 2, 3, 4]);
            string digest = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(file)));
            var package = new UpdateAsset(name, "", digest, 4);
            UpdateProtocol.VerifyPackage(file, package).GetAwaiter().GetResult();
            Reject(() => UpdateProtocol.VerifyPackage(file, package with { Size = 3 }).GetAwaiter().GetResult(), "Truncation accepted");
            Reject(() => UpdateProtocol.VerifyPackage(file, package with { Sha256 = hash }).GetAwaiter().GetResult(), "Wrong package digest accepted");
            foreach (string entryName in new[] { "../outside", "/absolute", "a\\b", "folder/../escape", "file:stream", "trailing. /file" })
            {
                string zipPath = Path.Combine(temporary, "bad.zip");
                using (var zip = ZipFile.Open(zipPath, ZipArchiveMode.Create)) zip.CreateEntry(entryName);
                string stage = Path.Combine(temporary, "stage");
                Directory.CreateDirectory(stage);
                Reject(() => UpdateApply.ExtractPortable(zipPath, stage, "1.2.0"), "ZIP traversal accepted: " + entryName);
                File.Delete(zipPath);
            }
            string target = Path.Combine(temporary, "portable");
            string replacement = Path.Combine(temporary, "replacement");
            string backup = Path.Combine(temporary, "backup");
            Directory.CreateDirectory(target);
            Directory.CreateDirectory(replacement);
            File.WriteAllText(Path.Combine(target, "ChiikawaPet.exe"), "old app");
            File.WriteAllText(Path.Combine(target, "obsolete.dll"), "old library");
            File.WriteAllText(Path.Combine(target, "unrelated.txt"), "user data");
            File.WriteAllText(Path.Combine(target, PortableUpdate.InventoryName), JsonSerializer.Serialize(new[] { "ChiikawaPet.exe", "obsolete.dll", PortableUpdate.InventoryName }));
            File.WriteAllText(Path.Combine(replacement, "ChiikawaPet.exe"), "new app");
            File.WriteAllText(Path.Combine(replacement, "new.dll"), "new library");
            File.WriteAllText(Path.Combine(replacement, PortableUpdate.InventoryName), JsonSerializer.Serialize(new[] { "ChiikawaPet.exe", "new.dll", PortableUpdate.InventoryName }));
            var transaction = new PortableUpdate(target, replacement, backup);
            transaction.Apply();
            Check(File.ReadAllText(Path.Combine(target, "ChiikawaPet.exe")) == "new app" && !File.Exists(Path.Combine(target, "obsolete.dll")), "Managed files replaced and obsolete file removed");
            Check(File.ReadAllText(Path.Combine(target, "unrelated.txt")) == "user data", "Portable apply preserves unrelated files");
            transaction.Rollback();
            Check(File.ReadAllText(Path.Combine(target, "ChiikawaPet.exe")) == "old app" && File.Exists(Path.Combine(target, "obsolete.dll")) && !File.Exists(Path.Combine(target, "new.dll")), "Portable rollback restores old files and removes only new managed files");
            Check(File.ReadAllText(Path.Combine(target, "unrelated.txt")) == "user data", "Portable rollback preserves unrelated files");
            File.WriteAllText(Path.Combine(replacement, "ChiikawaPet.exe"), "new app");
            File.WriteAllText(Path.Combine(replacement, "unrelated.txt"), "would overwrite");
            File.WriteAllText(Path.Combine(replacement, PortableUpdate.InventoryName), JsonSerializer.Serialize(new[] { "ChiikawaPet.exe", "new.dll", "unrelated.txt", PortableUpdate.InventoryName }));
            Reject(() => new PortableUpdate(target, replacement, backup), "New managed file overwrote unowned user file");
            File.WriteAllText(Path.Combine(replacement, PortableUpdate.InventoryName), "[\"../outside\"]");
            Reject(() => new PortableUpdate(target, replacement, backup), "Managed inventory escaped target folder");
            string settings = Path.Combine(temporary, "settings.json");
            Check(!Settings.Load(settings).AutomaticUpdates, "Automatic updates default off");
            new Settings { AutomaticUpdates = true, Character = "usagi", Language = "ko" }.Save(settings);
            var restored = Settings.Load(settings);
            Check(restored.AutomaticUpdates && restored.Character == "usagi" && restored.Language == "ko", "Opt-in and preferences persist together");
            if (OperatingSystem.IsWindows())
            {
                CheckMappedExecutableRollback(temporary, Check);
                string cache = Path.Combine(temporary, "cache");
                string abandoned = Path.Combine(cache, Guid.NewGuid().ToString("N"));
                string live = Path.Combine(cache, Guid.NewGuid().ToString("N"));
                string unrelated = Path.Combine(cache, "unrelated-directory");
                Directory.CreateDirectory(abandoned);
                Directory.CreateDirectory(live);
                Directory.CreateDirectory(unrelated);
                File.WriteAllText(Path.Combine(abandoned, "package"), "cancelled download");
                using (var lease = new FileStream(Path.Combine(live, "active.lock"), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                {
                    UpdateApply.CleanupSessions(cache, DateTime.UtcNow.AddMinutes(1));
                    Check(!Directory.Exists(abandoned), "Abandoned update downloads are reclaimed");
                    Check(Directory.Exists(live), "A live helper's session is never deleted");
                    Check(Directory.Exists(unrelated), "Cache cleanup leaves unowned directories alone");
                }
                UpdateApply.CleanupSessions(cache, DateTime.UtcNow.AddMinutes(1));
                Check(!Directory.Exists(live), "Completed helper sessions are reclaimed after lease release");
            }
        }
        finally { Directory.Delete(temporary, recursive: true); }
        return checks;
    }

    private static void CheckMappedExecutableRollback(string temporary, Action<bool, string> check)
    {
        string target = Path.Combine(temporary, "mapped-target");
        string stage = Path.Combine(temporary, "mapped-stage");
        string backup = Path.Combine(temporary, "mapped-backup");
        Directory.CreateDirectory(target);
        Directory.CreateDirectory(stage);
        string inventory = JsonSerializer.Serialize(new[] { "ChiikawaPet.exe", PortableUpdate.InventoryName });
        File.WriteAllText(Path.Combine(target, "ChiikawaPet.exe"), "previous app");
        File.WriteAllText(Path.Combine(target, PortableUpdate.InventoryName), inventory);
        File.WriteAllText(Path.Combine(target, "personal.txt"), "personal data");
        File.Copy(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"), Path.Combine(stage, "ChiikawaPet.exe"));
        File.WriteAllText(Path.Combine(stage, PortableUpdate.InventoryName), inventory);
        var transaction = new PortableUpdate(target, stage, backup);
        transaction.Apply();
        var start = new ProcessStartInfo(Path.Combine(target, "ChiikawaPet.exe"), "/d /c set /p pet_update_hold=")
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true
        };
        using var mapped = Process.Start(start) ?? throw new Exception("Cannot launch the mapped-image rollback fixture.");
        try
        {
            if (mapped.HasExited) throw new Exception("Mapped-image fixture exited before rollback.");
            transaction.Rollback();
            check(File.ReadAllText(Path.Combine(target, "ChiikawaPet.exe")) == "previous app", "Rollback restores the old executable even while Windows retains the failed image mapping");
            check(File.ReadAllText(Path.Combine(target, "personal.txt")) == "personal data", "Mapped-image rollback preserves personal files");
        }
        finally
        {
            mapped.StandardInput.Close();
            if (!mapped.WaitForExit(5000)) { mapped.Kill(entireProcessTree: true); mapped.WaitForExit(); }
        }
    }

    private sealed class UpdateTransport(bool fail) : HttpMessageHandler
    {
        internal int Requests { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            Requests++;
            if (request.Headers.Authorization != null || request.Headers.UserAgent.Count == 0)
                throw new Exception("Update transport leaked credentials or omitted User-Agent.");
            if (fail) throw new HttpRequestException("Fixture network unavailable.");
            var response = new HttpResponseMessage(System.Net.HttpStatusCode.Found);
            response.Headers.Location = new Uri("http://evil.invalid/package");
            return Task.FromResult(response);
        }
    }
}
