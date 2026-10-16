using ChiikawaPet;
using System.Text.Json;

int checks = 0;
void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
    checks++;
}
void Reject(Action action, string message)
{
    try { action(); } catch (InvalidOperationException) { checks++; return; }
    throw new Exception(message);
}

var now = DateTimeOffset.FromUnixTimeSeconds(1780000000);
var claude = Usage.Decode("Claude", """
    {"five_hour":{"utilization":25.5,"resets_at":"2026-05-22T18:00:00Z"},
     "seven_day":null,"seven_day_sonnet":{"utilization":95},"seven_day_opus":{"utilization":null}}
    """, now);
Check(claude.Windows.Length == 2 && claude.Windows[0].Remaining == 74.5 && claude.Remaining == 5, "Claude measured quotas/minimum");
Check(claude.Windows[0].ResetsAt == DateTimeOffset.FromUnixTimeSeconds(1779472800), "Claude ISO reset");
var weekly = Usage.Decode("Codex", """
    {"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800,"reset_at":1785260773},"secondary_window":null}}
    """, now);
Check(weekly.Windows.Length == 1 && weekly.Windows[0].Title == "주간" && weekly.Remaining == 99, "No invented 5-hour limit");
Check(weekly.Windows[0].ResetsAt == DateTimeOffset.FromUnixTimeSeconds(1785260773), "Codex epoch reset");
var reordered = Usage.Decode("Codex", """
    {"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":604800},"secondary_window":{"used_percent":90,"limit_window_seconds":18000}}}
    """, now);
Check(reordered.Windows[1].Title == "5시간" && reordered.Remaining == 10, "Reordered quota durations");
var missing = Usage.Decode("Codex", """{"rate_limit":{"secondary_window":{"used_percent":0}}}""", now);
Check(missing.Windows[0].Title == "두 번째 한도" && missing.Remaining == 100, "Unspecified duration stays neutral");

foreach (double used in new[] { 100d, double.BitIncrement(100d), 100.1, 125, double.MaxValue })
{
    var claudeOverage = JsonSerializer.Serialize(new { five_hour = new { utilization = used }, seven_day = new { utilization = 20 } });
    var codexOverage = JsonSerializer.Serialize(new { rate_limit = new { primary_window = new { used_percent = used }, secondary_window = new { used_percent = 20 } } });
    foreach (var (provider, json) in new[] { ("Claude", claudeOverage), ("Codex", codexOverage) })
    {
        var exhausted = Usage.Decode(provider, json, now);
        Check(exhausted.Windows.Select(window => window.Remaining).SequenceEqual(new[] { 0d, 80d }),
            "Exhaustion and overage preserve every measured quota");
        var exhaustedProvider = new ProviderState(provider);
        exhaustedProvider.Succeed(exhausted);
        Check(Usage.Minimum(new[] { exhaustedProvider }) == 0 && Usage.MoodRow(exhaustedProvider.Remaining) == 4
            && Usage.Percent(exhaustedProvider.Remaining) == "0%", "Exhausted provider stays measured, zero, and crying");
    }
}

foreach (var json in new[] { "{}", "[]", "not json", """{"five_hour":{"utilization":"25"}}""",
    """{"five_hour":{"utilization":25,"resets_at":"invalid"}}""",
    """{"five_hour":{"utilization":-1}}""", """{"five_hour":{"utilization":null}}""",
    """{"five_hour":42}""", """{"five_hour":{"utilization":1e999}}""" })
    Reject(() => Usage.Decode("Claude", json, now), "Malformed Claude usage accepted");
foreach (var json in new[] { "{}", "[]", """{"rate_limit":null}""", """{"rate_limit":{}}""",
    """{"rate_limit":{"primary_window":{"used_percent":"10"}}}""",
    """{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":0}}}""",
    """{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":-1}}}""",
    """{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1e999}}}""",
    """{"rate_limit":{"primary_window":{"used_percent":-1},"secondary_window":{"used_percent":0}}}""" })
    Reject(() => Usage.Decode("Codex", json, now), "Malformed Codex usage accepted");

foreach (var (value, row) in new (double?, int)[] { (null, 5), (0, 4), (10, 4), (10.0001, 3), (29.999, 3),
    (30, 2), (59.999, 2), (60, 1), (94.999, 1), (95, 0), (100, 0) })
    Check(Usage.MoodRow(value) == row, "Mood threshold");
Check(Usage.Percent(94.99) == "94%" && Usage.Percent(null) == "—", "Floor display, never invent a value");
var providers = new[] { new ProviderState("Claude"), new ProviderState("Codex") };
providers[0].Succeed(claude);
providers[1].Succeed(weekly);
Check(Usage.Minimum(providers) == 5, "Fresh minimum");
providers[0].Fail("offline");
Check(Usage.Minimum(providers) == 99 && providers[0].Reading == claude, "Stale reading kept, excluded from expression");
providers[1].Fail("offline");
Check(Usage.Minimum(providers) == null, "All failures mean unknown");
providers[0].Succeed(reordered);
Check(Usage.Minimum(providers) == 10 && providers[0].Error == null, "Recovery clears errors");

var credentials = Usage.ParseCredentials("Codex", """{"tokens":{"access_token":"dummy-token","account_id":"dummy-account"}}""", now);
Check(credentials.Token == "dummy-token" && credentials.Account == "dummy-account", "File credential parsing");
Check(Usage.ParseCredentials("Claude", """{"claudeAiOauth":{"accessToken":"dummy-token","expiresAt":1999999999999}}""", now).Token == "dummy-token", "Claude valid expiry");
foreach (var json in new[] { "{}", "[]", "not json", """{"auth_mode":42}""", """{"auth_mode":"apikey","OPENAI_API_KEY":"dummy-key"}""",
    """{"tokens":{"access_token":"bad\r\ntoken","account_id":"dummy-account"}}""",
    """{"tokens":{"access_token":"dummy-token","account_id":""}}""" })
    Reject(() => Usage.ParseCredentials("Codex", json, now), "Unsafe or unusable credentials accepted");
Reject(() => Usage.ParseCredentials("Claude", """{"claudeAiOauth":{"accessToken":"dummy-token","expiresAt":1}}""", now), "Expired credential accepted");
Reject(() => Usage.ParseCredentials("Claude", """{"claudeAiOauth":{"accessToken":"dummy-token","expiresAt":"invalid"}}""", now), "Malformed expiry accepted");

var temp = Path.Combine(Path.GetTempPath(), "chiikawa-check-" + Guid.NewGuid());
var settingsPath = Path.Combine(temp, "settings.json");
try
{
    Check(Settings.Load(settingsPath).Scale == 0.65, "Default size");
    var settings = new Settings { Character = "momonga", Scale = 1.2, Visible = false, Wanders = false, X = -200, Y = 40 };
    settings.Save(settingsPath);
    var restored = Settings.Load(settingsPath);
    Check(restored.Character == "momonga" && restored.Scale == 1.2 && !restored.Visible && !restored.Wanders
        && restored.X == -200 && restored.Y == 40, "Preferences round trip / negative monitor coordinates");
    settings.Character = "invalid";
    settings.Scale = double.NaN;
    settings.X = double.PositiveInfinity;
    settings.Validate();
    Check(settings.Character == "chiikawa" && settings.Scale == 0.65 && settings.X == null, "Invalid settings recover");
    settings.Save(settingsPath);
    Check(Settings.Load(settingsPath).Scale == 0.65 && !File.Exists(settingsPath + ".tmp"), "Atomic overwrite completes");
}
finally { if (Directory.Exists(temp)) Directory.Delete(temp, recursive: true); }
Check(new Settings().Language == "en", "English is default");
var languageSettings = new Settings { Language = "invalid" };
languageSettings.Validate();
Check(languageSettings.Language == "en", "Invalid language defaults to English");
var languagePath = Path.Combine(Path.GetTempPath(), "chiikawa-language-" + Guid.NewGuid(), "settings.json");
try {
    new Settings { Language = "ko" }.Save(languagePath);
    Check(Settings.Load(languagePath).Language == "ko", "Language persists after restart");
} finally { Directory.Delete(Path.GetDirectoryName(languagePath)!, recursive: true); }
Language.Current = "en";
checks += UpdateChecks.Run();
Console.WriteLine($"Windows logic checks passed: {checks}");
