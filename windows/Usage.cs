using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace ChiikawaPet;

internal sealed record Quota(string Title, double Remaining, DateTimeOffset? ResetsAt);
internal sealed record Reading(Quota[] Windows, DateTimeOffset FetchedAt)
{
    public double Remaining => Windows.Min(window => window.Remaining);
}

internal sealed class ProviderState(string name)
{
    public string Name { get; } = name;
    public Reading? Reading { get; private set; }
    public string? Error { get; private set; }

    public void Succeed(Reading reading) { Reading = reading; Error = null; }
    public void Fail(string message) => Error = message;
    public double? Remaining => Error == null ? Reading?.Remaining : null;
}

internal static class Usage
{
    private const string InvalidResponse = "사용량 응답에 유효한 한도가 없습니다.";
    private static readonly HttpClient Client = new(new HttpClientHandler
    {
        AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false
    }) { Timeout = TimeSpan.FromSeconds(20) };

    public static double? Minimum(IEnumerable<ProviderState> providers) =>
        providers.Select(provider => provider.Remaining).Min();

    public static int MoodRow(double? remaining) => remaining switch
    {
        null => 5, <= 10 => 4, < 30 => 3, < 60 => 2, < 95 => 1, _ => 0
    };

    public static string Caption(double? remaining) => MoodRow(remaining) switch
    {
        0 => "와아! 아직 한가득!", 1 => "오늘도 같이 힘내자", 2 => "조금씩 아껴 쓰자…",
        3 => "이제 얼마 안 남았어…", 4 => "울먹… 잠깐 쉬었다 가자", _ => "연결하면 기분을 알려줄게"
    };

    public static string Percent(double? remaining) => remaining is double number
        ? $"{Math.Floor(number).ToString(CultureInfo.InvariantCulture)}%" : "—";

    public static string ConfigDirectory(string variable, string defaultName)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var configured = Environment.GetEnvironmentVariable(variable);
        if (string.IsNullOrWhiteSpace(configured)) return Path.Combine(home, defaultName);
        configured = Environment.ExpandEnvironmentVariables(configured);
        if (configured == "~") return home;
        if (configured.StartsWith("~/") || configured.StartsWith("~\\"))
            configured = Path.Combine(home, configured[2..]);
        return Path.GetFullPath(configured);
    }

    public static async Task<Reading> Fetch(string provider)
    {
        bool claude = provider == "Claude";
        var path = Path.Combine(ConfigDirectory(claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME",
            claude ? ".claude" : ".codex"), claude ? ".credentials.json" : "auth.json");
        string credentials;
        // ponytail: file credentials only; add Credential Manager when keyring accounts need support.
        try { credentials = await File.ReadAllTextAsync(path); }
        catch (FileNotFoundException) { throw new InvalidOperationException(LoginMessage(provider)); }
        catch (DirectoryNotFoundException) { throw new InvalidOperationException(LoginMessage(provider)); }
        catch (UnauthorizedAccessException) { throw new InvalidOperationException($"{provider} 로그인 파일을 읽을 권한이 없습니다."); }
        catch (IOException) { throw new InvalidOperationException($"{provider} 로그인 파일을 읽을 수 없습니다."); }
        var (token, account) = ParseCredentials(provider, credentials, DateTimeOffset.UtcNow);
        using var request = new HttpRequestMessage(HttpMethod.Get, claude
            ? "https://api.anthropic.com/api/oauth/usage" : "https://chatgpt.com/backend-api/wham/usage");
        request.Headers.Add("Authorization", $"Bearer {token}");
        request.Headers.Add("Accept", "application/json");
        request.Headers.Add("User-Agent", claude ? "claude-code" : "Mozilla/5.0");
        if (claude) request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
        else
        {
            request.Headers.Add("ChatGPT-Account-Id", account!);
            request.Headers.Add("Origin", "https://chatgpt.com");
            request.Headers.Add("Referer", "https://chatgpt.com/");
        }
        try
        {
            using var response = await Client.SendAsync(request);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                throw new InvalidOperationException($"{provider} 인증이 만료되었거나 사용량 권한이 없습니다. {LoginMessage(provider)}");
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException($"사용량 서버 오류 (HTTP {(int)response.StatusCode}). 나중에 새로고침하세요.");
            return Decode(provider, await response.Content.ReadAsStringAsync(), DateTimeOffset.UtcNow);
        }
        catch (TaskCanceledException) { throw new InvalidOperationException("사용량 조회 시간이 초과되었습니다. 다시 새로고침하세요."); }
        catch (HttpRequestException) { throw new InvalidOperationException("사용량 서버에 연결할 수 없습니다. 네트워크를 확인하세요."); }
    }

    private static string LoginMessage(string provider) => provider == "Claude"
        ? "Windows의 Claude Code에서 /login 후 새로고침하세요."
        : "Windows 터미널에서 codex login 후 새로고침하세요. Credential Manager 저장은 현재 지원하지 않습니다.";

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
                if (oauth.Value.TryGetProperty("expiresAt", out var expiry) && expiry.ValueKind != JsonValueKind.Null)
                {
                    if (expiry.ValueKind != JsonValueKind.Number || !expiry.TryGetDouble(out var milliseconds) || !double.IsFinite(milliseconds)
                        || milliseconds <= now.ToUnixTimeMilliseconds())
                        throw new InvalidOperationException("Claude 인증이 만료되었습니다. Claude Code에서 /login 후 새로고침하세요.");
                }
                return (token, null);
            }
            if (root.TryGetProperty("auth_mode", out var mode) && mode.ValueKind is not (JsonValueKind.String or JsonValueKind.Null))
                throw new InvalidOperationException(InvalidResponse);
            if (root.TryGetProperty("auth_mode", out mode) && mode.GetString() == "apikey")
                throw new InvalidOperationException("API 키는 구독 잔여량이 없습니다. codex login으로 ChatGPT 계정을 연결하세요.");
            var tokens = Object(root, "tokens");
            if (tokens is null)
            {
                if (root.TryGetProperty("OPENAI_API_KEY", out var key) && key.ValueKind == JsonValueKind.String
                    && !string.IsNullOrEmpty(key.GetString()))
                    throw new InvalidOperationException("API 키는 구독 잔여량이 없습니다. codex login으로 ChatGPT 계정을 연결하세요.");
                throw new InvalidOperationException(LoginMessage(provider));
            }
            return (Header(tokens.Value, "access_token"), Header(tokens.Value, "account_id"));
        }
        catch (JsonException) { throw new InvalidOperationException(LoginMessage(provider)); }
        catch (InvalidOperationException error) when (error.Message == InvalidResponse)
        { throw new InvalidOperationException(LoginMessage(provider)); }
    }

    private static string Header(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String
            || value.GetString() is not string text || text.Length == 0
            || text.Any(character => character < 33 || character > 126))
            throw new InvalidOperationException(InvalidResponse);
        return text;
    }

    public static Reading Decode(string provider, string json, DateTimeOffset now)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var windows = new List<Quota>();
            if (provider == "Claude")
            {
                foreach (var (key, title) in new[] { ("five_hour", "5시간"), ("seven_day", "주간"),
                    ("seven_day_sonnet", "Sonnet 주간"), ("seven_day_opus", "Opus 주간") })
                {
                    var window = Object(root, key);
                    if (window is null || Number(window.Value, "utilization") is not double used) continue;
                    DateTimeOffset? resets = null;
                    if (window.Value.TryGetProperty("resets_at", out var reset) && reset.ValueKind != JsonValueKind.Null)
                    {
                        if (reset.ValueKind != JsonValueKind.String || !reset.TryGetDateTimeOffset(out var date))
                            throw new InvalidOperationException(InvalidResponse);
                        resets = date;
                    }
                    windows.Add(MakeQuota(title, used, resets));
                }
            }
            else
            {
                var limit = Object(root, "rate_limit") ?? throw new InvalidOperationException(InvalidResponse);
                foreach (var (key, fallback) in new[] { ("primary_window", "첫 번째 한도"), ("secondary_window", "두 번째 한도") })
                {
                    var window = Object(limit, key);
                    if (window is null || Number(window.Value, "used_percent") is not double used) continue;
                    var title = fallback;
                    if (window.Value.TryGetProperty("limit_window_seconds", out var duration) && duration.ValueKind != JsonValueKind.Null)
                    {
                        if (!duration.TryGetInt64(out var seconds) || seconds <= 0)
                            throw new InvalidOperationException(InvalidResponse);
                        title = seconds == 604800 ? "주간" : seconds % 86400 == 0 ? $"{seconds / 86400}일 한도"
                            : seconds % 3600 == 0 ? $"{seconds / 3600}시간" : $"{seconds}초 한도";
                    }
                    DateTimeOffset? resets = null;
                    if (Number(window.Value, "reset_at") is double epoch)
                    {
                        if (epoch < 0 || !double.IsFinite(epoch)) throw new InvalidOperationException(InvalidResponse);
                        resets = DateTimeOffset.UnixEpoch.AddSeconds(epoch);
                    }
                    windows.Add(MakeQuota(title, used, resets));
                }
            }
            if (windows.Count == 0) throw new InvalidOperationException(InvalidResponse);
            return new Reading(windows.ToArray(), now);
        }
        catch (JsonException) { throw new InvalidOperationException(InvalidResponse); }
        catch (ArgumentOutOfRangeException) { throw new InvalidOperationException(InvalidResponse); }
        catch (InvalidOperationException) { throw new InvalidOperationException(InvalidResponse); }
    }

    private static Quota MakeQuota(string title, double used, DateTimeOffset? resets)
    {
        if (!double.IsFinite(used) || used < 0) throw new InvalidOperationException(InvalidResponse);
        return new Quota(title, Math.Max(0, 100 - used), resets);
    }

    private static JsonElement? Object(JsonElement parent, string key)
    {
        if (parent.ValueKind != JsonValueKind.Object) throw new InvalidOperationException(InvalidResponse);
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidOperationException(InvalidResponse);
        return value;
    }

    private static double? Number(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var number))
            throw new InvalidOperationException(InvalidResponse);
        return number;
    }
}
