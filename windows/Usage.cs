using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ChiikawaPet;

internal sealed record UsageAccount(string Id, string Provider, string Label, string Directory)
{
    public string? ExpectedAccountID { get; init; }
    public string? ExpectedOrganizationID { get; init; }
    public string? ExpectedEmail { get; init; }
    public string? ExpectedUserID { get; init; }
    public bool UseCredentialManager { get; init; }
    public string? CredentialFile { get; init; }
    public bool CredentialFileIsBase64 { get; init; }
    public string? SwapCacheFile { get; init; }
    public string? VaultFile { get; init; }
}

internal sealed record Quota(string Title, double Remaining, DateTimeOffset? ResetsAt,
    string Id = "", double? DurationSeconds = null)
{
    public string Id { get; init; } = string.IsNullOrEmpty(Id) ? Title : Id;
}

internal sealed record UsageExtra(string Id, string Title, double Amount, string Unit, double? Limit = null);

internal sealed record Reading(Quota[] Windows, DateTimeOffset FetchedAt)
{
    public string Source { get; init; } = "live";
    public string? AccountID { get; init; }
    public string? OrganizationID { get; init; }
    public string? UserID { get; init; }
    public string? AccountLabel { get; init; }
    public string? Plan { get; init; }
    public string? AuthSource { get; init; }
    public string? CredentialFingerprint { get; init; }
    public string? AccountIdentity { get; init; }
    public DateTimeOffset? RetryAt { get; init; }
    public UsageExtra[] Extras { get; init; } = [];
    public string? Warning { get; init; }
    public double Remaining => Windows.Length == 0 ? double.NaN : Windows.Min(window => window.Remaining);
    public bool IsCurrent(DateTimeOffset now) => Source is "live" or "swapCache"
        && FetchedAt <= now && now - FetchedAt <= TimeSpan.FromMinutes(15)
        && Windows.Length > 0 && Windows.All(window => double.IsFinite(window.Remaining)
            && window.Remaining is >= 0 and <= 100 && (window.ResetsAt == null || window.ResetsAt > now));
}

internal sealed class UsageCooldownException(DateTimeOffset retryAt)
    : InvalidOperationException("사용량 서버의 조회 제한으로 대기 중입니다. 다음 시도 시각까지 기다려 주세요.")
{
    public DateTimeOffset RetryAt { get; } = retryAt;
}

internal sealed class UsageIdentityException(DateTimeOffset? retryAt = null)
    : InvalidOperationException("로그인 신원이 선택한 계정과 일치하지 않습니다. 해당 계정으로 CLI에 다시 로그인하세요.")
{
    public DateTimeOffset? RetryAt { get; } = retryAt;
}

internal sealed class ProviderState
{
    public ProviderState(string name) : this(new UsageAccount(name.ToLowerInvariant(), name, name, "")) { }
    public ProviderState(UsageAccount account) { Account = account; }
    public UsageAccount Account { get; }
    public string Name => Account.Provider;
    public Reading? Reading { get; private set; }
    public string? Error { get; private set; }
    public DateTimeOffset? RetryAt { get; private set; }
    public void Succeed(Reading reading) { Reading = reading; Error = null; RetryAt = reading.RetryAt; }
    public void Fail(string message, DateTimeOffset? retryAt = null) { Error = message; RetryAt = retryAt; }
    public void Fail(Exception error) => Fail(error.Message, error switch
    {
        UsageCooldownException cooldown => cooldown.RetryAt,
        UsageIdentityException mismatch => mismatch.RetryAt,
        _ => null
    });
    public void Clear() { Reading = null; Error = null; RetryAt = null; }
    public void VerifyFingerprint(string? fingerprint)
    {
        if (Reading != null && (fingerprint == null || fingerprint != Reading.CredentialFingerprint)) Clear();
    }
    public double? Remaining => Error == null && Reading is { Windows.Length: > 0 } reading ? reading.Remaining : null;
}

internal static class Usage
{
    internal const string InvalidResponse = "사용량 응답에 유효한 한도가 없습니다.";
    private static readonly HttpClient Client = new(new HttpClientHandler
    {
        AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false
    }) { Timeout = TimeSpan.FromSeconds(20), MaxResponseContentBufferSize = 1024 * 1024 };
    private static readonly UsageReader Reader = new(Client);
    public static string[] DiscoveryWarnings { get; private set; } = [];
    public static Task<Reading> Fetch(UsageAccount account) => Reader.Fetch(account);
    public static Task<Reading?> Cached(UsageAccount account) => Reader.Cached(account);
    public static Task<string?> CurrentFingerprint(UsageAccount account) => Reader.CurrentFingerprint(account);

    public static UsageAccount[] DefaultAccounts(bool credentialManagerEnabled = false) =>
    [
        new("claude", "Claude", "Claude", ConfigDirectory("CLAUDE_CONFIG_DIR", ".claude")),
        new("codex", "Codex", "Codex", ConfigDirectory("CODEX_HOME", ".codex"))
            { UseCredentialManager = credentialManagerEnabled }
    ];

    public static UsageAccount[] Discover(bool includeSaved, IEnumerable<UsageAccount> additional,
        bool credentialManagerEnabled = false)
    {
        var accounts = new List<UsageAccount>(DefaultAccounts(credentialManagerEnabled));
        accounts.AddRange(additional.Select(account => account with
            { UseCredentialManager = account.Provider == "Codex" && credentialManagerEnabled }));
        var warnings = new List<string>();
        if (includeSaved) accounts.AddRange(UsageCredentials.DiscoverSaved(warnings, credentialManagerEnabled));
        DiscoveryWarnings = warnings.ToArray();
        return accounts.DistinctBy(SourceKey).DistinctBy(account => account.Id).ToArray();
    }

    public static double? Minimum(IEnumerable<ProviderState> providers) =>
        providers.Select(provider => provider.Remaining).Min();
    public static int MoodRow(double? remaining, double[]? thresholds = null)
    {
        if (remaining is not double measured || !double.IsFinite(measured)) return 5;
        var exhausted = thresholds is { Length: 4 } ? thresholds[0] : 10;
        var low = thresholds is { Length: 4 } ? thresholds[1] : 30;
        var medium = thresholds is { Length: 4 } ? thresholds[2] : 60;
        var high = thresholds is { Length: 4 } ? thresholds[3] : 95;
        return measured <= exhausted ? 4 : measured < low ? 3 : measured < medium ? 2 : measured < high ? 1 : 0;
    }
    public static string Caption(double? remaining) => MoodRow(remaining) switch
    {
        0 => "와아! 아직 한가득!", 1 => "오늘도 같이 힘내자", 2 => "조금씩 아껴 쓰자…",
        3 => "이제 얼마 안 남았어…", 4 => "울먹… 잠깐 쉬었다 가자", _ => "연결하면 기분을 알려줄게"
    };
    public static string Percent(double? remaining) => remaining is double number && double.IsFinite(number)
        ? $"{Math.Floor(number).ToString(CultureInfo.InvariantCulture)}%" : "—";
    public static string ConfigDirectory(string variable, string defaultName)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var configured = Environment.GetEnvironmentVariable(variable);
        return ExpandDirectory(string.IsNullOrWhiteSpace(configured) ? Path.Combine(home, defaultName) : configured, home);
    }
    internal static string ExpandDirectory(string configured, string home)
    {
        configured = Environment.ExpandEnvironmentVariables(configured);
        if (configured == "~") return home;
        if (configured.StartsWith("~/") || configured.StartsWith("~\\")) configured = Path.Combine(home, configured[2..]);
        return Path.GetFullPath(configured);
    }
    internal static string Hash(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        var digest = SHA256.HashData(bytes);
        return Convert.ToHexStringLower(digest);
    }
    internal static string? IdentityHash(string provider, string? accountID, string? organizationID, string? accessEmail)
    {
        var owner = provider == "Claude" ? organizationID : provider == "Codex" ? accessEmail : null;
        if (string.IsNullOrWhiteSpace(accountID) || string.IsNullOrWhiteSpace(owner)
            || accountID.Any(character => char.IsWhiteSpace(character) || char.IsControl(character))
            || owner.Any(character => char.IsWhiteSpace(character) || char.IsControl(character))) return null;
        return Hash(provider + "\0" + accountID.ToLowerInvariant() + "\0" + owner.ToLowerInvariant());
    }
    internal static string Binding(UsageAccount account)
    {
        var encoded = JsonSerializer.Serialize(account);
        return Hash(encoded);
    }
    internal static string SourceKey(UsageAccount account) => Binding(account with
    {
        Id = "", Label = "", Directory = NormalizeSourcePath(account.Directory)!,
        CredentialFile = NormalizeSourcePath(account.CredentialFile), VaultFile = NormalizeSourcePath(account.VaultFile),
        SwapCacheFile = NormalizeSourcePath(account.SwapCacheFile),
        UseCredentialManager = account.Provider == "Codex" && account.UseCredentialManager,
        ExpectedAccountID = account.ExpectedAccountID?.ToUpperInvariant(),
        ExpectedOrganizationID = account.ExpectedOrganizationID?.ToUpperInvariant(),
        ExpectedEmail = account.ExpectedEmail?.ToUpperInvariant(), ExpectedUserID = account.ExpectedUserID?.ToUpperInvariant()
    });
    internal static string? NormalizeSourcePath(string? path)
    {
        if (path == null) return null;
        if (UsageCredentials.IsWsl(path))
        {
            path = path.Replace('/', '\\');
            if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) path = @"\\" + path[8..];
            var segments = path.Split('\\', StringSplitOptions.RemoveEmptyEntries);
            if (segments.Length < 2) return path;
            segments[0] = "wsl.localhost";
            segments[1] = segments[1].ToLowerInvariant();
            var count = 2;
            for (var index = 2; index < segments.Length; index++)
            {
                if (segments[index] == ".") continue;
                if (segments[index] == "..") { if (count > 2) count--; continue; }
                segments[count++] = segments[index];
            }
            var normalized = @"\\" + string.Join("\\", segments, 0, count);
            return count == 2 ? normalized + "\\" : normalized;
        }
        try { path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException) { }
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) path = @"\\" + path[8..];
        else if (path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) path = path[4..];
        return path.ToUpperInvariant();
    }
    internal static string LoginMessage(string provider) => provider == "Claude"
        ? "선택한 Windows/WSL Claude Code 홈에서 /login 후 새로고침하세요. 저장 계정은 cswap run으로 갱신하세요."
        : "선택한 Windows/WSL Codex 홈에서 codex login 후 새로고침하세요. 저장 계정은 xswap login으로 갱신하세요. Credential Manager는 별도 허용이 필요합니다.";

    public static (string Token, string? Account) ParseCredentials(string provider, string json, DateTimeOffset now)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new InvalidOperationException(InvalidResponse);
            if (provider == "Claude")
            {
                var oauth = Object(root, "claudeAiOauth");
                if (oauth is null) throw new InvalidOperationException(LoginMessage(provider));
                var token = Header(oauth.Value, "accessToken");
                var expiry = Number(oauth.Value, "expiresAt");
                if (expiry is double milliseconds && (!double.IsFinite(milliseconds) || milliseconds <= now.ToUnixTimeMilliseconds()))
                    throw new InvalidOperationException("Claude 인증이 만료되었습니다. 해당 홈에서 /login 후 새로고침하세요.");
                return (token, null);
            }
            if (provider != "Codex") throw new InvalidOperationException("지원하지 않는 사용량 제공자입니다.");
            var mode = Text(root, "auth_mode");
            if (mode == "apikey") throw new InvalidOperationException("API 키는 구독 잔여량이 없습니다. codex login으로 ChatGPT 계정을 연결하세요.");
            var tokens = Object(root, "tokens");
            if (tokens is null)
            {
                if (!string.IsNullOrEmpty(Text(root, "OPENAI_API_KEY")))
                    throw new InvalidOperationException("API 키는 구독 잔여량이 없습니다. codex login으로 ChatGPT 계정을 연결하세요.");
                throw new InvalidOperationException(LoginMessage(provider));
            }
            return (Header(tokens.Value, "access_token"), Header(tokens.Value, "account_id"));
        }
        catch (JsonException) { throw new InvalidOperationException(LoginMessage(provider)); }
        catch (InvalidOperationException error) when (error.Message == InvalidResponse)
        { throw new InvalidOperationException(LoginMessage(provider)); }
    }

    public static Reading Decode(string provider, string json, DateTimeOffset now)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new InvalidOperationException(InvalidResponse);
            var windows = new List<Quota>();
            var extras = new List<UsageExtra>();
            string? warning = null;
            string? plan = null;
            if (provider == "Claude")
            {
                foreach (var (key, title, id, duration) in new[] {
                    ("five_hour", "5시간", "session", 18000d), ("seven_day", "주간", "weekly", 604800d),
                    ("seven_day_sonnet", "Sonnet 주간", "model:sonnet:weekly", 604800d),
                    ("seven_day_opus", "Opus 주간", "model:opus:weekly", 604800d) })
                {
                    var window = Object(root, key);
                    if (window is null || Number(window.Value, "utilization") is not double used) continue;
                    windows.Add(MakeQuota(title, used, Reset(window.Value, "resets_at"), id, duration));
                }
                foreach (var limit in Array(root, "limits"))
                {
                    if (limit.ValueKind != JsonValueKind.Object || Text(limit, "kind") != "weekly_scoped") continue;
                    var scope = Object(limit, "scope");
                    var model = scope is { } scoped ? Object(scoped, "model") : null;
                    var name = model is { } named ? Text(named, "display_name") : null;
                    if (string.IsNullOrWhiteSpace(name) || Number(limit, "percent") is not double used) continue;
                    var id = "model:" + name.Trim().ToLowerInvariant() + ":weekly";
                    windows.RemoveAll(window => window.Id == id);
                    windows.Add(MakeQuota(name + " 주간", used, Reset(limit, "resets_at"), id, 604800));
                }
                var extra = Object(root, "extra_usage");
                if (extra is { } spend && Boolean(spend, "is_enabled") == true && Number(spend, "used_credits") is double usedCents)
                {
                    var capCents = Number(spend, "monthly_limit");
                    RequireNonnegative(usedCents);
                    if (capCents is double cap) RequireNonnegative(cap);
                    extras.Add(new("extra-usage", "추가 사용액", usedCents / 100, "USD", capCents is > 0 ? capCents / 100 : null));
                }
                extras.AddRange(DecodeClaudeGrants(root, now));
            }
            else if (provider == "Codex")
            {
                AppendCodex(Object(root, "rate_limit"), null, windows, now);
                foreach (var limit in Array(root, "additional_rate_limits"))
                {
                    var previousCount = windows.Count;
                    try
                    {
                        if (limit.ValueKind != JsonValueKind.Object) throw new InvalidOperationException();
                        var model = Text(limit, "limit_name");
                        if (string.IsNullOrWhiteSpace(model)) model = Text(limit, "metered_feature");
                        if (string.IsNullOrWhiteSpace(model)) throw new InvalidOperationException();
                        AppendCodex(Object(limit, "rate_limit"), model, windows, now);
                    }
                    catch (InvalidOperationException)
                    {
                        windows.RemoveRange(previousCount, windows.Count - previousCount);
                        warning = "Codex 모델별 한도 일부의 형식이 올바르지 않아 제외했습니다.";
                    }
                }
                AppendCodex(Object(root, "code_review_rate_limit"), "code-review", windows, now);
                var credits = Object(root, "credits");
                if (credits is { } balance)
                {
                    if (Boolean(balance, "unlimited") == true)
                        warning = (warning == null ? "" : warning + " ") + "제공자가 추가 크레딧을 무제한으로 보고했습니다.";
                    var amount = NumericText(balance, "balance");
                    if (amount == null && Boolean(balance, "has_credits") == false) amount = 0;
                    if (amount is double count)
                    {
                        RequireNonnegative(count);
                        extras.Add(new("credits", "추가 크레딧", count, "credits"));
                    }
                }
                var resets = Object(root, "rate_limit_reset_credits");
                if (resets is { } reset && Number(reset, "available_count") is double available)
                {
                    RequireCount(available);
                    extras.Add(new("reset-credits", "사용량 초기화권", available, "resets"));
                }
                plan = Text(root, "plan_type");
            }
            else throw new InvalidOperationException(InvalidResponse);
            if (windows.Count == 0) throw new InvalidOperationException(InvalidResponse);
            if (windows.Select(window => window.Id).Distinct().Count() != windows.Count)
                throw new InvalidOperationException(InvalidResponse);
            return new Reading(windows.ToArray(), now) { Plan = plan, Extras = extras.ToArray(), Warning = warning };
        }
        catch (JsonException) { throw new InvalidOperationException(InvalidResponse); }
        catch (ArgumentOutOfRangeException) { throw new InvalidOperationException(InvalidResponse); }
        catch (InvalidOperationException) { throw new InvalidOperationException(InvalidResponse); }
    }

    internal static UsageExtra[] DecodeClaudeGrants(JsonElement root, DateTimeOffset now)
    {
        var block = Object(root, "cedar_ember");
        if (block is not { } program) return [];
        double count = 0;
        foreach (var grant in Array(program, "grants"))
        {
            if (string.IsNullOrWhiteSpace(Text(grant, "id"))) throw new InvalidOperationException(InvalidResponse);
            var remaining = Number(grant, "resets_left") ?? throw new InvalidOperationException(InvalidResponse);
            RequireCount(remaining);
            var expires = Reset(grant, "ends_at");
            if (Boolean(program, "eligible") == true && (expires == null || expires > now)) count += remaining;
        }
        RequireCount(count);
        return [new("reset-grants", "사용량 초기화권", count, "resets")];
    }

    private static void AppendCodex(JsonElement? limit, string? model, List<Quota> windows, DateTimeOffset now)
    {
        if (limit is not { } rate) return;
        foreach (var (key, fallback, slot) in new[] { ("primary_window", "첫 번째 한도", "primary"), ("secondary_window", "두 번째 한도", "secondary") })
        {
            var window = Object(rate, key);
            if (window is not { } measured || Number(measured, "used_percent") is not double used) continue;
            var duration = Number(measured, "limit_window_seconds");
            if (duration is double seconds && (!double.IsFinite(seconds) || seconds <= 0 || seconds != Math.Floor(seconds) || seconds > 31536000))
                throw new InvalidOperationException(InvalidResponse);
            var title = duration switch
            {
                604800 => "주간", 18000 => "5시간", double days when days % 86400 == 0 => $"{days / 86400}일 한도",
                double hours when hours % 3600 == 0 => $"{hours / 3600}시간", double other => $"{other}초 한도", _ => fallback
            };
            var kind = duration == 604800 ? "weekly" : duration == 18000 ? "session" : slot;
            var id = model == null ? kind : "model:" + model.Trim().ToLowerInvariant() + ":" + kind;
            var resets = Reset(measured, "reset_at");
            if (resets == null && Number(measured, "reset_after_seconds") is double after)
            {
                RequireNonnegative(after);
                resets = now.AddSeconds(after);
            }
            windows.Add(MakeQuota(model == null ? title : model + " · " + title, used, resets, id, duration));
        }
    }

    internal static Quota MakeQuota(string title, double used, DateTimeOffset? resets, string id, double? duration)
    {
        RequireNonnegative(used);
        return new Quota(title, Math.Max(0, 100 - used), resets, id, duration);
    }
    internal static void RequireNonnegative(double number)
    {
        if (!double.IsFinite(number) || number < 0) throw new InvalidOperationException(InvalidResponse);
    }
    internal static void RequireCount(double number)
    {
        RequireNonnegative(number);
        if (number != Math.Floor(number) || number > int.MaxValue) throw new InvalidOperationException(InvalidResponse);
    }
    internal static string Header(JsonElement root, string name)
    {
        var text = Text(root, name);
        if (string.IsNullOrEmpty(text) || text.Any(character => character < 33 || character > 126))
            throw new InvalidOperationException(InvalidResponse);
        return text;
    }
    internal static JsonElement? Object(JsonElement parent, string key)
    {
        if (parent.ValueKind != JsonValueKind.Object) throw new InvalidOperationException(InvalidResponse);
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidOperationException(InvalidResponse);
        return value;
    }
    internal static JsonElement[] Array(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return [];
        if (value.ValueKind != JsonValueKind.Array) throw new InvalidOperationException(InvalidResponse);
        return value.EnumerateArray().ToArray();
    }
    internal static string? Text(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.String) throw new InvalidOperationException(InvalidResponse);
        return value.GetString();
    }
    internal static bool? Boolean(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new InvalidOperationException(InvalidResponse);
        return value.GetBoolean();
    }
    internal static double? Number(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var number) || !double.IsFinite(number))
            throw new InvalidOperationException(InvalidResponse);
        return number;
    }
    internal static double? NumericText(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind == JsonValueKind.Number) return Number(parent, key);
        if (value.ValueKind == JsonValueKind.String && double.TryParse(value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var number)
            && double.IsFinite(number)) return number;
        throw new InvalidOperationException(InvalidResponse);
    }
    internal static DateTimeOffset? Reset(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind == JsonValueKind.String && value.TryGetDateTimeOffset(out var date)) return date;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var epoch) && double.IsFinite(epoch) && epoch >= 0)
            return DateTimeOffset.UnixEpoch.AddSeconds(epoch >= 1e10 ? epoch / 1000 : epoch);
        throw new InvalidOperationException(InvalidResponse);
    }
}

internal sealed class UsageReader
{
    private readonly HttpClient http;
    private readonly Func<DateTimeOffset> clock;
    private readonly UsageSnapshots snapshots;
    private readonly ConcurrentDictionary<string, DateTimeOffset> cooldowns = new();
    private readonly ConcurrentDictionary<string, SemaphoreSlim> gates = new();
    private readonly ConcurrentDictionary<string, ClaudeIdentity> profiles = new();
    private readonly ConcurrentDictionary<string, GrantSample> grants = new();
    private readonly ConcurrentDictionary<string, string> cacheWarnings = new();

    internal UsageReader(HttpClient http, Func<DateTimeOffset>? clock = null, string? cacheDirectory = null)
    {
        this.http = http;
        this.clock = clock ?? (() => DateTimeOffset.UtcNow);
        snapshots = new UsageSnapshots(cacheDirectory);
    }
    public async Task<string?> CurrentFingerprint(UsageAccount account)
    {
        try
        {
            var credential = await UsageCredentials.Read(account, clock());
            return credential.Fingerprint;
        }
        catch (InvalidOperationException) { return null; }
    }

    public async Task<Reading?> Cached(UsageAccount account)
    {
        try
        {
            var credential = await UsageCredentials.Read(account, clock());
            var reading = await snapshots.Load(account, credential, clock());
            await EnsureUnchanged(account, credential);
            return reading;
        }
        catch (InvalidOperationException) { return null; }
    }

    public async Task<Reading> Fetch(UsageAccount account)
    {
        var gate = gates.GetOrAdd(Usage.SourceKey(account), _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync();
        UsageCredential? credential = null;
        try
        {
            credential = await UsageCredentials.Read(account, clock());
            var key = account.Provider + ":" + credential.Fingerprint;
            if (cooldowns.TryGetValue(key, out var until) && until > clock())
            {
                var fallback = await SwapReading(account, credential, key, until);
                if (fallback != null) return fallback;
                throw new UsageCooldownException(until);
            }
            ClaudeIdentity? identity = null;
            if (account.Provider == "Claude")
            {
                identity = await ClaudeProfile(account, credential, key);
                if (identity != null)
                {
                    var cached = await SwapReading(account, credential, key, null, identity);
                    if (cached != null && clock() - cached.FetchedAt <= TimeSpan.FromMinutes(2)) return cached;
                }
            }
            Reading reading;
            try
            {
                var json = await Get(account, credential, key, account.Provider == "Claude"
                    ? "https://api.anthropic.com/api/oauth/usage" : "https://chatgpt.com/backend-api/wham/usage");
                reading = Usage.Decode(account.Provider, json, clock());
            }
            catch (UsageCooldownException error)
            {
                var cached = await SwapReading(account, credential, key, error.RetryAt, identity);
                if (cached != null) return cached;
                throw;
            }
            reading = reading with
            {
                AccountID = identity?.AccountID ?? credential.AccountID,
                OrganizationID = identity?.OrganizationID,
                UserID = credential.UserID,
                AccountLabel = identity?.Email ?? credential.Email,
                Plan = reading.Plan ?? identity?.Plan ?? credential.Plan,
                AuthSource = credential.AuthSource,
                CredentialFingerprint = credential.Fingerprint,
                AccountIdentity = Usage.IdentityHash(account.Provider, identity?.AccountID ?? credential.AccountID,
                    identity?.OrganizationID, credential.AccessEmail),
                Warning = JoinWarning(reading.Warning, JoinWarning(cacheWarnings.GetValueOrDefault(key),
                    account.Provider == "Claude" && identity == null
                        ? "계정 프로필을 확인할 수 없습니다. 사용량은 현재 로그인 토큰 기준이며 신원은 미확인입니다." : null))
            };
            if (account.Provider == "Claude") reading = await AddGrants(account, credential, key, reading);
            await EnsureUnchanged(account, credential);
            var warning = await snapshots.Save(account, reading, clock());
            if (warning != null) reading = reading with { Warning = JoinWarning(reading.Warning, warning) };
            await EnsureUnchanged(account, credential);
            return reading;
        }
        catch (Exception error) when (error is InvalidOperationException or HttpRequestException or TaskCanceledException)
        {
            if (credential != null) await EnsureUnchanged(account, credential);
            if (error is TaskCanceledException)
                throw new InvalidOperationException("사용량 조회 시간이 초과되었습니다. 다시 새로고침하세요.");
            if (error is HttpRequestException)
                throw new InvalidOperationException("사용량 서버에 연결할 수 없습니다. 네트워크를 확인하세요.");
            throw;
        }
        finally { gate.Release(); }
    }

    private async Task EnsureUnchanged(UsageAccount account, UsageCredential original)
    {
        UsageCredential current;
        try { current = await UsageCredentials.Read(account, clock()); }
        catch (InvalidOperationException) { throw new UsageIdentityException(); }
        if (current.Fingerprint == original.Fingerprint) return;
        var key = account.Provider + ":" + current.Fingerprint;
        DateTimeOffset? retryAt = cooldowns.TryGetValue(key, out var until) && until > clock() ? until : null;
        throw new UsageIdentityException(retryAt);
    }

    private async Task<Reading?> SwapReading(UsageAccount account, UsageCredential credential, string key,
        DateTimeOffset? retryAt, ClaudeIdentity? identity = null)
    {
        if (account.Provider != "Claude" || account.SwapCacheFile == null) return null;
        if (identity == null) profiles.TryGetValue(key, out identity);
        if (identity == null) return null;
        UsageCredentials.VerifyIdentity(account, identity.AccountID, identity.Email, identity.OrganizationID);
        Reading? reading;
        try { reading = await UsageSnapshots.SwapCache(account.SwapCacheFile, identity, clock()); }
        catch (InvalidOperationException error) { cacheWarnings[key] = error.Message; return null; }
        if (reading == null) return null;
        await EnsureUnchanged(account, credential);
        reading = reading with { AccountID = identity.AccountID, OrganizationID = identity.OrganizationID,
            AccountLabel = identity.Email, Plan = identity.Plan ?? credential.Plan,
            AuthSource = credential.AuthSource, CredentialFingerprint = credential.Fingerprint, RetryAt = retryAt,
            AccountIdentity = Usage.IdentityHash("Claude", identity.AccountID, identity.OrganizationID, null),
            Warning = retryAt != null ? "실시간 조회 제한 중 같은 계정의 cswap 캐시를 표시합니다." : null };
        var warning = await snapshots.Save(account, reading, clock());
        await EnsureUnchanged(account, credential);
        return warning == null ? reading : reading with { Warning = JoinWarning(reading.Warning, warning) };
    }

    private async Task<ClaudeIdentity?> ClaudeProfile(UsageAccount account, UsageCredential credential, string key)
    {
        if (profiles.TryGetValue(key, out var identity))
        {
            UsageCredentials.VerifyIdentity(account, identity.AccountID, identity.Email, identity.OrganizationID);
            return identity;
        }
        try
        {
            var json = await Get(account, credential, key, "https://api.anthropic.com/api/oauth/profile");
            identity = UsageCredentials.ParseClaudeProfile(json);
            UsageCredentials.VerifyIdentity(account, identity.AccountID, identity.Email, identity.OrganizationID);
            profiles[key] = identity;
            return identity;
        }
        catch (UsageIdentityException) { throw; }
        catch (UsageCooldownException) { throw; }
        catch (Exception error) when ((error is InvalidOperationException or HttpRequestException or TaskCanceledException)
            && account.ExpectedAccountID == null && account.ExpectedOrganizationID == null && account.ExpectedEmail == null)
        { return null; }
    }

    private async Task<Reading> AddGrants(UsageAccount account, UsageCredential credential, string key, Reading reading)
    {
        var now = clock();
        if (!grants.TryGetValue(key, out var sample) || now - sample.AttemptedAt >= TimeSpan.FromHours(1))
        {
            sample = new GrantSample(now, null, "사용량 초기화권 정보를 확인할 수 없습니다.");
            grants[key] = sample;
            try
            {
                var json = await Get(account, credential, key, "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1");
                using var document = JsonDocument.Parse(json);
                sample = new GrantSample(now, document.RootElement.Clone(), null);
                grants[key] = sample;
            }
            catch (UsageCooldownException error)
            { return reading with { RetryAt = error.RetryAt, Warning = JoinWarning(reading.Warning, sample.Warning) }; }
            catch (Exception error) when (error is InvalidOperationException or JsonException or HttpRequestException or TaskCanceledException) { }
        }
        if (sample.Payload is { } payload)
        {
            try
            {
                var extras = Usage.DecodeClaudeGrants(payload, now);
                return reading with { Extras = reading.Extras.Where(extra => extra.Id != "reset-grants").Concat(extras).ToArray() };
            }
            catch (InvalidOperationException)
            { return reading with { Warning = JoinWarning(reading.Warning, "사용량 초기화권 응답 형식이 올바르지 않아 제외했습니다.") }; }
        }
        return reading with { Warning = JoinWarning(reading.Warning, sample.Warning) };
    }

    private async Task<string> Get(UsageAccount account, UsageCredential credential, string key, string url)
    {
        if (cooldowns.TryGetValue(key, out var until) && until > clock()) throw new UsageCooldownException(until);
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Add("Authorization", "Bearer " + credential.Token);
        request.Headers.Add("Accept", "application/json");
        request.Headers.Add("User-Agent", account.Provider == "Claude" ? "claude-cli/2.1.294 (external, cli)" : "Mozilla/5.0");
        if (account.Provider == "Claude") request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
        else
        {
            request.Headers.Add("ChatGPT-Account-Id", credential.AccountID!);
            request.Headers.Add("Origin", "https://chatgpt.com");
            request.Headers.Add("Referer", "https://chatgpt.com/");
        }
        using var response = await http.SendAsync(request);
        if (response.StatusCode == HttpStatusCode.TooManyRequests)
        {
            var header = response.Headers.TryGetValues("Retry-After", out var headers) ? headers.FirstOrDefault() : null;
            until = RetryDate(header, clock());
            cooldowns[key] = until;
            throw new UsageCooldownException(until);
        }
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new InvalidOperationException($"{account.Provider} 인증이 만료되었거나 사용량 권한이 없습니다. {Usage.LoginMessage(account.Provider)}");
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"사용량 서버 오류 (HTTP {(int)response.StatusCode}). 나중에 새로고침하세요.");
        return await response.Content.ReadAsStringAsync();
    }

    internal static DateTimeOffset RetryDate(string? header, DateTimeOffset now)
    {
        var delay = 120d;
        if (double.TryParse(header, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) && double.IsFinite(seconds) && seconds > 0)
            delay = seconds;
        else if (DateTimeOffset.TryParseExact(header, "r", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date) && date > now)
            delay = (date - now).TotalSeconds;
        var maximumDelay = (DateTimeOffset.MaxValue - now).TotalSeconds;
        if (delay >= maximumDelay) return DateTimeOffset.MaxValue;
        try { return now.AddSeconds(delay); }
        catch (ArgumentOutOfRangeException) { return DateTimeOffset.MaxValue; }
    }
    private static string? JoinWarning(string? first, string? second) => first == null ? second : second == null ? first : first + " " + second;
    private sealed record GrantSample(DateTimeOffset AttemptedAt, JsonElement? Payload, string? Warning);
}
