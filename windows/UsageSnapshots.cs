using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;

namespace ChiikawaPet;

internal sealed class UsageSnapshots
{
    private readonly string directory;
    internal UsageSnapshots(string? directory = null)
    {
        this.directory = directory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChiikawaPet", "usage-cache");
    }

    internal async Task<Reading?> Load(UsageAccount account, UsageCredential credential, DateTimeOffset now)
    {
        try
        {
            if (LinkedDirectory()) return null;
            var path = SnapshotPath(account);
            if (IsLink(path)) return null;
            var json = await UsageCredentials.ReadLimited(path, 1048576);
            if (json == null) return null;
            var snapshot = JsonSerializer.Deserialize<Snapshot>(json);
            if (snapshot == null || snapshot.Version != 1 || snapshot.Provider != account.Provider
                || snapshot.Binding != Usage.Binding(account) || snapshot.Fingerprint != credential.Fingerprint
                || snapshot.Reading == null || snapshot.Reading.CredentialFingerprint != credential.Fingerprint
                || !Valid(snapshot.Reading, now)) return null;
            var reading = snapshot.Reading;
            UsageCredentials.VerifyIdentity(account, reading.AccountID, reading.AccountLabel, reading.OrganizationID, reading.UserID);
            if (credential.AccountID != null && !UsageCredentials.Equal(credential.AccountID, reading.AccountID)) return null;
            if (credential.Email != null && !UsageCredentials.Equal(credential.Email, reading.AccountLabel)) return null;
            if (credential.UserID != null && !UsageCredentials.Equal(credential.UserID, reading.UserID)) return null;
            return reading with { Source = "diskCache", RetryAt = null, Warning = "이전 정상 측정값입니다. 실시간 표정과 알림에는 사용하지 않습니다." };
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException
            or InvalidOperationException or ArgumentException) { return null; }
    }

    internal async Task<string?> Save(UsageAccount account, Reading reading, DateTimeOffset now)
    {
        if (!Valid(reading, now)) return "현재 측정값의 나이/리셋/범위를 검증할 수 없어 디스크에 저장하지 않았습니다.";
        string? temporary = null;
        try
        {
            if (LinkedDirectory()) return "사용량 캐시 폴더가 링크여서 저장하지 않았습니다.";
            System.IO.Directory.CreateDirectory(directory);
            var path = SnapshotPath(account);
            if (IsLink(path)) return "사용량 캐시 파일이 링크여서 저장하지 않았습니다.";
            temporary = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".tmp");
            var snapshot = new Snapshot(1, account.Provider, Usage.Binding(account), reading.CredentialFingerprint!, reading);
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                4096, FileOptions.Asynchronous))
            {
                await JsonSerializer.SerializeAsync(stream, snapshot);
                await stream.FlushAsync();
            }
            File.Move(temporary, path, true);
            return null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException
            or InvalidOperationException or ArgumentException)
        { return "정상 사용량은 조회했지만 앱의 로컬 캐시를 저장할 수 없습니다."; }
        finally
        {
            if (temporary != null)
            {
                try { File.Delete(temporary); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }

    internal string SnapshotPath(UsageAccount account) => Path.Combine(directory, Usage.Binding(account) + ".json");
    private bool LinkedDirectory()
    {
        var parent = Path.GetDirectoryName(directory);
        return IsLink(directory) || (parent != null && IsLink(parent));
    }
    private static bool IsLink(string path)
    {
        try { return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    internal static bool Valid(Reading reading, DateTimeOffset now)
    {
        if (reading.Source is not ("live" or "swapCache") || reading.FetchedAt < DateTimeOffset.UnixEpoch
            || reading.FetchedAt > now || now - reading.FetchedAt > TimeSpan.FromHours(24)
            || reading.Windows == null || reading.Windows.Length is 0 or > 64 || reading.Extras == null || reading.Extras.Length > 64
            || reading.CredentialFingerprint is not { Length: 64 } fingerprint || !fingerprint.All(char.IsAsciiHexDigit)
            || (reading.AccountIdentity != null && (reading.AccountIdentity.Length != 64 || !reading.AccountIdentity.All(char.IsAsciiHexDigit)))
            || !OptionalText(reading.AccountID) || !OptionalText(reading.AccountLabel) || !OptionalText(reading.OrganizationID)
            || !OptionalText(reading.UserID) || !OptionalText(reading.Plan) || !OptionalText(reading.AuthSource)
            || !OptionalText(reading.Warning, 1024)) return false;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var quota in reading.Windows)
        {
            if (quota == null || !Text(quota.Id, 160) || !Text(quota.Title, 160) || !ids.Add(quota.Id)
                || !double.IsFinite(quota.Remaining) || quota.Remaining is < 0 or > 100) return false;
            if (quota.DurationSeconds is double duration && (!double.IsFinite(duration) || duration <= 0
                || duration > 31536000 || duration != Math.Floor(duration))) return false;
            if (quota.ResetsAt is { } reset && (reset <= now || reset <= reading.FetchedAt
                || (reset - reading.FetchedAt).TotalDays > 366)) return false;
        }
        ids.Clear();
        foreach (var extra in reading.Extras)
        {
            if (extra == null || !Text(extra.Id, 160) || !Text(extra.Title, 160) || !ids.Add(extra.Id)
                || extra.Unit is not ("USD" or "credits" or "resets") || !double.IsFinite(extra.Amount) || extra.Amount < 0
                || (extra.Limit is double limit && (!double.IsFinite(limit) || limit < 0))) return false;
            if (extra.Unit == "resets" && (extra.Amount != Math.Floor(extra.Amount) || extra.Amount > int.MaxValue)) return false;
        }
        return true;
    }
    private static bool OptionalText(string? text, int maximum = 320) => text == null || Text(text, maximum);
    private static bool Text(string? text, int maximum) => !string.IsNullOrWhiteSpace(text)
        && text.Length <= maximum && !text.Any(char.IsControl);

    // EdenGibson/claudeswitch 7586506 usage_store.py: schema 2 rows bind email + organization, never a slot alone.
    internal static async Task<Reading?> SwapCache(string path, ClaudeIdentity identity, DateTimeOffset now)
    {
        try
        {
            var json = await UsageCredentials.ReadLimited(path, 1048576);
            if (json == null) return null;
            return DecodeSwapCache(json, identity, now);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException
            or InvalidOperationException or ArgumentException)
        { throw new InvalidOperationException("cswap 캐시의 신원/버전/측정값을 확인할 수 없어 사용하지 않았습니다. 실시간 조회를 시도합니다."); }
    }

    internal static Reading? DecodeSwapCache(string json, ClaudeIdentity identity, DateTimeOffset now)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (Usage.Number(root, "schemaVersion") != 2) throw new InvalidOperationException();
        var accounts = Usage.Object(root, "accounts") ?? throw new InvalidOperationException();
        if (string.IsNullOrWhiteSpace(identity.Email) || string.IsNullOrWhiteSpace(identity.OrganizationID)) return null;
        JsonElement? match = null;
        foreach (var row in accounts.EnumerateObject())
        {
            if (row.Value.ValueKind != JsonValueKind.Object) continue;
            if (!UsageCredentials.Equal(Usage.Text(row.Value, "email"), identity.Email)
                || !UsageCredentials.Equal(Usage.Text(row.Value, "organizationUuid"), identity.OrganizationID)) continue;
            if (match != null) throw new InvalidOperationException();
            match = row.Value;
        }
        if (match is not { } account) return null;
        var epoch = Usage.Number(account, "fetchedAt");
        var usage = Usage.Object(account, "lastGood");
        if (epoch == null || epoch < 0 || usage == null) return null;
        DateTimeOffset fetched;
        try { fetched = DateTimeOffset.UnixEpoch.AddSeconds(epoch.Value); }
        catch (ArgumentOutOfRangeException) { throw new InvalidOperationException(); }
        if (fetched > now || now - fetched > TimeSpan.FromHours(1)) return null;
        var windows = new List<Quota>();
        foreach (var (key, title, id, duration) in new[] { ("five_hour", "5시간", "session", 18000d), ("seven_day", "주간", "weekly", 604800d) })
        {
            var window = Usage.Object(usage.Value, key);
            if (window is { } measured) windows.Add(SwapWindow(measured, title, id, duration, now));
        }
        foreach (var measured in Usage.Array(usage.Value, "scoped"))
        {
            var name = Usage.Text(measured, "name");
            if (!Text(name, 120)) throw new InvalidOperationException();
            windows.Add(SwapWindow(measured, name + " 주간", "model:" + name!.ToLowerInvariant() + ":weekly", 604800, now));
        }
        if (windows.Count == 0 || windows.Count > 64 || windows.Select(window => window.Id).Distinct().Count() != windows.Count)
            throw new InvalidOperationException();
        var extras = new List<UsageExtra>();
        var spend = Usage.Object(usage.Value, "spend");
        if (spend is { } balance && Usage.Number(balance, "used") is double amount)
        {
            Usage.RequireNonnegative(amount);
            var limit = Usage.Number(balance, "limit");
            if (limit is double cap) Usage.RequireNonnegative(cap);
            var currency = Usage.Text(balance, "currency");
            if (currency is "USD" or "$" or null) extras.Add(new("extra-usage", "추가 사용액", amount, "USD", limit is > 0 ? limit : null));
        }
        return new Reading(windows.ToArray(), fetched) { Source = "swapCache", AccountID = identity.AccountID,
            OrganizationID = identity.OrganizationID, AccountLabel = identity.Email, Extras = extras.ToArray() };
    }
    private static Quota SwapWindow(JsonElement measured, string title, string id, double duration, DateTimeOffset now)
    {
        var used = Usage.Number(measured, "pct") ?? throw new InvalidOperationException();
        var reset = Usage.Reset(measured, "resets_at");
        if (reset is { } date && (date <= now || (date - now).TotalDays > 366)) throw new InvalidOperationException();
        return Usage.MakeQuota(title, used, reset, id, duration);
    }

    private sealed record Snapshot(int Version, string Provider, string Binding, string Fingerprint, Reading Reading);
}
