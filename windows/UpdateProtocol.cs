using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ChiikawaPet;

internal sealed record UpdateAsset(string Name, string Url, string Sha256, long Size);
internal sealed record VerifiedUpdate(string Version, UpdateAsset Asset, byte[] Manifest, byte[] Signature);

internal static class UpdateProtocol
{
    internal const long PackageLimit = 512L * 1024 * 1024;
    internal const string ReleaseBase = "https://github.com/meengi07/chiikawa-agent-pet/releases/download/v";
    private static readonly Regex VersionPattern = new("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\z", RegexOptions.CultureInvariant);
    private static readonly Regex HashPattern = new("^[0-9a-f]{64}\\z", RegexOptions.CultureInvariant);

    internal static Version ParseVersion(string text)
    {
        if (!VersionPattern.IsMatch(text)) throw new InvalidDataException("Invalid stable release version.");
        var parts = text.Split('.');
        var numbers = new int[3];
        for (int index = 0; index < 3; index++)
            if (!ushort.TryParse(parts[index], out var number)) throw new InvalidDataException("Release version is out of range.");
            else numbers[index] = number;
        return new Version(numbers[0], numbers[1], numbers[2]);
    }

    internal static string PinnedKey()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("UPDATE_PUBLIC_KEY")
            ?? throw new InvalidDataException("The pinned update key is missing.");
        using var reader = new StreamReader(stream, Encoding.ASCII);
        return reader.ReadToEnd();
    }

    internal static VerifiedUpdate Verify(byte[] manifest, byte[] signature, string version, string current, bool installed, string? fixtureKey = null)
    {
        if (manifest.Length == 0 || manifest.Length > 65536 || signature.Length == 0 || signature.Length > 1024)
            throw new InvalidDataException("Update metadata exceeds its limit.");
        using var key = ECDsa.Create();
        key.ImportFromPem(fixtureKey ?? PinnedKey());
        byte[] der;
        try { der = Convert.FromBase64String(Encoding.ASCII.GetString(signature)); }
        catch (FormatException error) { throw new InvalidDataException("Invalid update signature.", error); }
        if (key.KeySize != 256 || !key.VerifyData(manifest, der, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence))
            throw new InvalidDataException("Update signature verification failed.");
        if (ParseVersion(version) <= ParseVersion(current)) throw new InvalidDataException("The release is not newer than this app.");
        using var document = JsonDocument.Parse(manifest);
        var root = document.RootElement;
        RequireProperties(root, "schemaVersion", "version", "assets");
        if (root.GetProperty("schemaVersion").GetInt32() != 1 || root.GetProperty("version").GetString() != version)
            throw new InvalidDataException("Update manifest version does not match the release.");
        string selectedName = $"ChiikawaPet-{version}-win-x64{(installed ? "-setup.exe" : ".zip")}";
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        UpdateAsset? selected = null;
        var assets = root.GetProperty("assets");
        if (assets.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Invalid update assets.");
        foreach (var item in assets.EnumerateArray())
        {
            RequireProperties(item, "name", "url", "sha256", "size");
            string name = item.GetProperty("name").GetString() ?? "";
            if (name.Length == 0 || !names.Add(name)) throw new InvalidDataException("Duplicate or empty update asset.");
            if (name != selectedName) continue;
            string url = item.GetProperty("url").GetString() ?? "";
            string hash = item.GetProperty("sha256").GetString() ?? "";
            long size = item.GetProperty("size").GetInt64();
            if (url != ReleaseBase + version + "/" + selectedName || !HashPattern.IsMatch(hash) || size <= 0 || size > PackageLimit)
                throw new InvalidDataException("Invalid update package location, size, or hash.");
            selected = new UpdateAsset(name, url, hash, size);
        }
        if (selected == null) throw new InvalidDataException("This release has no Windows x64 update package.");
        return new VerifiedUpdate(version, selected, manifest, signature);
    }

    private static void RequireProperties(JsonElement item, params string[] expected)
    {
        if (item.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Invalid update object.");
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in item.EnumerateObject())
            if (!names.Add(property.Name) || Array.IndexOf(expected, property.Name) < 0)
                throw new InvalidDataException("Duplicate or unknown update field.");
        if (names.Count != expected.Length) throw new InvalidDataException("Missing update field.");
    }

    internal static async Task VerifyPackage(string path, UpdateAsset asset, CancellationToken cancellation = default)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
        if (stream.Length != asset.Size) throw new InvalidDataException("The update package size does not match.");
        byte[] hash = await SHA256.HashDataAsync(stream, cancellation);
        if (!Convert.ToHexStringLower(hash).Equals(asset.Sha256, StringComparison.Ordinal))
            throw new InvalidDataException("The update package hash does not match.");
    }

    internal static bool AllowedReleaseUri(Uri uri) => uri.Scheme == "https" && uri.IsDefaultPort
        && uri.UserInfo.Length == 0 && (uri.Host == "github.com" || uri.Host == "release-assets.githubusercontent.com" || uri.Host == "objects.githubusercontent.com");

    internal static async Task Download(string url, Stream destination, long limit, CancellationToken cancellation, bool api = false, HttpMessageHandler? transport = null)
    {
        using var handler = transport ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false };
        using var client = new HttpClient(handler, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("ChiikawaPet-Updater/1.0");
        var uri = new Uri(url);
        for (int redirects = 0; redirects <= 5; redirects++)
        {
            bool allowed = api && redirects == 0 && uri.AbsoluteUri == "https://api.github.com/repos/meengi07/chiikawa-agent-pet/releases/latest";
            if (!allowed && !AllowedReleaseUri(uri)) throw new InvalidDataException("Unsafe update redirect.");
            using var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if ((int)response.StatusCode is >= 300 and < 400)
            {
                var location = response.Headers.Location ?? throw new InvalidDataException("Missing update redirect location.");
                uri = location.IsAbsoluteUri ? location : new Uri(uri, location);
                continue;
            }
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("Update download is too large.");
            await using var input = await response.Content.ReadAsStreamAsync(cancellation);
            byte[] buffer = new byte[65536];
            long total = 0;
            int count;
            while ((count = await input.ReadAsync(buffer, cancellation)) != 0)
            {
                total += count;
                if (total > limit) throw new InvalidDataException("Update download exceeds its limit.");
                await destination.WriteAsync(buffer.AsMemory(0, count), cancellation);
            }
            return;
        }
        throw new InvalidDataException("Too many update redirects.");
    }

    internal static async Task<byte[]> DownloadBytes(string url, int limit, CancellationToken cancellation, bool api = false)
    {
        using var bytes = new MemoryStream();
        await Download(url, bytes, limit, cancellation, api);
        return bytes.ToArray();
    }
}
