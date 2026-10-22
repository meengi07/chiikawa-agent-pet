using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using ChiikawaPet;

internal static class UsageDataChecks
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1800000000);
    private static int checks;
    private const string CodexUsage = """{"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_after_seconds":9000}}}""";

    internal static int Run()
    {
        checks = 0;
        ParserModelsAndExtras();
        FreshnessAndMood();
        CredentialsAndDiscovery();
        CacheValidation();
        RetryDates();
        RunAsync().GetAwaiter().GetResult();
        return checks;
    }

    private static void ParserModelsAndExtras()
    {
        // Observed payload contracts: OpenUsage 26132ff ClaudeUsageMapper.swift / CodexUsageMapper.swift.
        var claude = Usage.Decode("Claude", """
            {"five_hour":{"utilization":12,"resets_at":null},
             "seven_day_sonnet":{"utilization":99},
             "limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":45,"resets_at":1800200000},
                       {"kind":"weekly_scoped","scope":{"model":{"display_name":"Sonnet"}},"percent":10}],
             "extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000},
             "cedar_ember":{"eligible":true,"grants":[{"id":"available","resets_left":2,"ends_at":1800100000},
                 {"id":"expired","resets_left":7,"ends_at":1799999999}]}}
            """, Now);
        Check(claude.Windows.Length == 3 && claude.Windows.Single(window => window.Id == "model:sonnet:weekly").Remaining == 90,
            "Scoped values replace duplicate legacy model, without making up a weekly quota");
        Check(claude.Windows.Single(window => window.Id == "model:fable:weekly").DurationSeconds == 604800,
            "New named Claude models carry verified weekly duration");
        Check(claude.Extras.Single(extra => extra.Unit == "USD").Amount == 12.34
            && claude.Extras.Single(extra => extra.Unit == "USD").Limit == 50
            && claude.Extras.Single(extra => extra.Unit == "resets").Amount == 2, "Money and reset counts remain separate from quota percent");
        var codex = Usage.Decode("Codex", """
            {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":604800}},
             "additional_rate_limits":[null,{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{
                 "primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_after_seconds":50},
                 "secondary_window":{"used_percent":80,"limit_window_seconds":604800}}},
                 {"metered_feature":"Future-Model","rate_limit":{"secondary_window":{"used_percent":5,"limit_window_seconds":604800}}}],
             "credits":{"balance":"796.5","has_credits":true},"rate_limit_reset_credits":{"available_count":2}}
            """, Now);
        Check(codex.Windows[0].Id == "weekly" && codex.Windows.All(window => window.Id != "session"), "Weekly-only Codex never invents a session");
        Check(codex.Windows.Single(window => window.Id == "model:gpt-5.3-codex-spark:session").ResetsAt == Now.AddSeconds(50),
            "Additional models carry their own relative reset");
        Check(codex.Windows.Single(window => window.Id == "model:future-model:weekly").Remaining == 95, "All named additional models are decoded");
        Check(codex.Plan == "pro" && codex.Extras.Single(extra => extra.Id == "credits").Amount == 796.5
            && codex.Extras.Single(extra => extra.Id == "reset-credits").Amount == 2, "Plan, measured credits, and reset counts retain their provider units without inventing dollars");
        var damaged = Usage.Decode("Codex", """
            {"rate_limit":{"primary_window":{"used_percent":20}},"additional_rate_limits":[
             {"limit_name":"bad","rate_limit":{"primary_window":{"used_percent":1},"secondary_window":{"used_percent":-1}}},
             {"limit_name":"good","rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":18000}}}]}
            """, Now);
        Check(damaged.Windows.Length == 2 && damaged.Windows.All(window => !window.Id.Contains("bad")) && damaged.Warning != null,
            "Malformed additional model is discarded atomically, preserving valid siblings with a safe warning");
        var noCap = Usage.Decode("Claude", """{"five_hour":{"utilization":0},"extra_usage":{"is_enabled":true,"used_credits":0,"monthly_limit":0}}""", Now);
        Check(noCap.Extras.Single().Amount == 0 && noCap.Extras.Single().Limit == null, "Reported zero spend stays measured, while zero monthly cap means unbounded rather than a fake zero-dollar cap");
        var unlimited = Usage.Decode("Codex", """{"rate_limit":{"primary_window":{"used_percent":1}},"credits":{"unlimited":true,"has_credits":true}}""", Now);
        Check(unlimited.Extras.Length == 0 && unlimited.Warning != null, "Unlimited credit status is surfaced without inventing a numeric balance");
        foreach (var json in new[] {
            """{"five_hour":{"utilization":-1}}""", """{"five_hour":{"utilization":1},"extra_usage":{"is_enabled":true,"used_credits":-1}}""",
            """{"five_hour":{"utilization":1},"cedar_ember":{"grants":[{"id":"fractional","resets_left":1.5}]}}""" })
            Reject(() => Usage.Decode("Claude", json, Now), "Malformed extras are not accepted as measurements");
        Reject(() => Usage.Decode("Codex", """{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":1.5}}}""", Now),
            "Fractional quota duration is rejected");
    }

    private static void FreshnessAndMood()
    {
        var reading = new Reading([new("session", 50, Now.AddMinutes(10), "session", 18000)], Now);
        Check(reading.IsCurrent(Now) && reading.IsCurrent(Now.AddMinutes(1)), "Fresh live sample is current");
        Check(!(reading with { Source = "diskCache" }).IsCurrent(Now), "Disk snapshots never drive live state");
        Check(!(reading with { FetchedAt = Now.AddTicks(1) }).IsCurrent(Now), "Future samples are rejected");
        Check(!(reading with { FetchedAt = Now.AddMinutes(-15).AddTicks(-1) }).IsCurrent(Now), "Samples older than fifteen minutes are rejected");
        Check(!reading.IsCurrent(Now.AddMinutes(10)), "A reset at now is already expired");
        Check(new Quota("legacy", 20, null).Id == "legacy", "Existing quota constructors retain stable title fallback");
        var thresholds = new[] { 5d, 20, 40, 80 };
        foreach (var (remaining, row) in new[] { (5d, 4), (5.1, 3), (20d, 2), (40d, 1), (80d, 0) })
            Check(Usage.MoodRow(remaining, thresholds) == row, "Custom threshold exact boundary");
        var state = new ProviderState(new UsageAccount("a", "Codex", "A", "synthetic"));
        state.Succeed(reading);
        state.Fail(new UsageCooldownException(Now.AddMinutes(1)));
        Check(state.RetryAt == Now.AddMinutes(1) && state.Remaining == null && state.Reading == reading, "Cooldown preserves display but excludes live minimum");
        state.Clear();
        Check(state.Reading == null && state.Error == null && state.RetryAt == null, "Account switch clears every previous state field");
        var bound = reading with { CredentialFingerprint = new string('a', 64) };
        state.Succeed(bound);
        state.Fail(new UsageCooldownException(Now.AddMinutes(1)));
        state.VerifyFingerprint(bound.CredentialFingerprint);
        Check(state.Reading == bound && state.Error != null && state.RetryAt != null, "Unchanged source retains last live sample and cooldown even without a disk snapshot");
        state.VerifyFingerprint(null);
        Check(state.Reading == null && state.Error == null && state.RetryAt == null, "Unknown current source invalidates all previous-account state");
        state.Fail(new UsageIdentityException(Now.AddMinutes(2)));
        Check(state.Reading == null && state.RetryAt == Now.AddMinutes(2), "Identity failure carries only the current owner's explicitly supplied cooldown");
    }

    private static void CredentialsAndDiscovery()
    {
        var account = new UsageAccount("test", "Codex", "Test", Path.GetTempPath())
            { ExpectedAccountID = "workspace", ExpectedEmail = "person@example.test" };
        var json = Auth("workspace", "person@example.test", "one");
        var credential = UsageCredentials.Parse(account, json, Now, "synthetic");
        Check(credential.AccountID == "workspace" && credential.Email == "person@example.test"
            && credential.UserID == "user" && credential.Plan == "plus" && credential.Fingerprint.Length == 64,
            "Metadata comes from token claims, fingerprint has no raw token");
        var rotated = UsageCredentials.Parse(account, Auth("workspace", "person@example.test", "rotated"), Now, "synthetic");
        var otherUser = UsageCredentials.Parse(account with { ExpectedEmail = "other@example.test" },
            Auth("workspace", "other@example.test", "other-user"), Now, "synthetic");
        var identityKey = Usage.IdentityHash("Codex", credential.AccountID, null, credential.AccessEmail);
        Check(identityKey is { Length: 64 } && identityKey == Usage.IdentityHash("Codex", rotated.AccountID, null, rotated.AccessEmail)
            && credential.Fingerprint != rotated.Fingerprint, "Verified same-owner alert identity survives token rotation");
        Check(identityKey != Usage.IdentityHash("Codex", otherUser.AccountID, null, otherUser.AccessEmail),
            "Users in the same Codex workspace have distinct verified alert identities");
        var idOnlyJson = JsonSerializer.Serialize(new { tokens = new { access_token = "opaque-access", account_id = "workspace", id_token = credential.Token } });
        var idOnly = UsageCredentials.Parse(account, idOnlyJson, Now, "synthetic");
        Check(idOnly.Email == "person@example.test" && idOnly.AccessEmail == null
            && Usage.IdentityHash("Codex", idOnly.AccountID, null, idOnly.AccessEmail) == null,
            "ID-token-only email is advisory metadata, not a verified stable alert identity");
        Check(Usage.IdentityHash("Claude", "user", null, null) == null
            && Usage.IdentityHash("Claude", "user", "org", null) != Usage.IdentityHash("Claude", "user", "other-org", null),
            "Claude stable alert identity requires both verified user and organization");
        Reject(() => UsageCredentials.Parse(account with { ExpectedEmail = "other@example.test" }, json, Now, "synthetic"), "Same-workspace different users cannot share credentials");
        Reject(() => UsageCredentials.Parse(account, Auth("other", "person@example.test", "one", claimAccount: "workspace"), Now, "synthetic"),
            "Stored workspace conflicting with access claim is an identity error");
        Reject(() => UsageCredentials.Parse(account, Auth("workspace", "person@example.test", "one", expiry: Now.ToUnixTimeSeconds()), Now, "synthetic"),
            "Expired access token is not refreshed or silently accepted");
        var profile = UsageCredentials.ParseClaudeProfile("""{"account":{"uuid":"account","email_address":"person@example.test"},"organization":{"uuid":"org","rate_limit_tier":"max_5x"}}""");
        Check(profile.AccountID == "account" && profile.OrganizationID == "org" && profile.Plan == "max_5x", "Claude profile metadata is token-scoped");
        var warnings = new List<string>();
        var root = Path.Combine(Path.GetTempPath(), "synthetic-cswap");
        var claude = UsageCredentials.ParseClaudeSaved("""
            {"accounts":{"1":{"email":"person@example.test","uuid":"12345678-1234-1234-1234-123456789abc",
                "organizationUuid":"abcdef12-1234-1234-1234-123456789abc","organizationName":"Work"},
                "../2":{"email":"bad@example.test"}}}
            """, root, warnings);
        Check(claude.Length == 1 && warnings.Count == 1 && claude[0].ExpectedOrganizationID != null
            && claude[0].Directory == Path.Combine(root, "sessions", "1-person_example.test")
            && claude[0].VaultFile == Path.Combine(root, "credentials", ".creds-1-person@example.test.enc"), "cswap discovery binds identity, sanitizes slug, and rejects traversal");
        var registry = JsonSerializer.Serialize(new {
            schemaVersion = 1, mainHome = Path.GetTempPath(), accounts = new[] {
                new { number = 1, alias = "Work", home = Path.GetTempPath(), identity = new { accountId = "workspace", email = "person@example.test", userId = "user" }, enabled = false } }
        });
        var saved = UsageCredentials.ParseCodexSaved(registry, Path.GetTempPath(), warnings, true);
        Check(saved.Length == 1 && saved[0].ExpectedEmail == "person@example.test" && saved[0].UseCredentialManager,
            "Disabled xswap slot remains explicitly usable and retains owner verification");
        Reject(() => UsageCredentials.ParseCodexSaved(registry.Replace("\"schemaVersion\":1", "\"schemaVersion\":2"), root, warnings), "Unknown registry version rejected");
        const string canonical = @"\\?\C:\Users\Synthetic\.codex";
        Check(UsageCredentials.CodexTarget(canonical) == "cli|" + Usage.Hash(canonical)[..16] + ".Codex Auth", "Only verified keyring-rs username.service Windows target is used");
        Check(UsageCredentials.CodexTarget("abc") == "cli|ba7816bf8f01cfea.Codex Auth", "Known SHA-256 fixture verifies digest truncation and exact target punctuation");
        var sameSource = account with { Id = "renamed", Label = "Different label", Directory = Path.Combine(account.Directory, ".") };
        Check(Usage.SourceKey(account) == Usage.SourceKey(sameSource), "Source dedup ignores UI IDs/labels and normalizes lexical home aliases");
        Check(Usage.SourceKey(account) != Usage.SourceKey(account with { VaultFile = Path.Combine(account.Directory, "vault.enc") }),
            "Distinct saved credential sources are not merged");
        Check(UsageCredentials.IsWsl(@"\\wsl.localhost\Ubuntu\home\synthetic\.codex"), "Explicit WSL UNC path is recognized without a distro scan");
        Check(UsageCredentials.IsWsl(@"\\?\UNC\wsl.localhost\Ubuntu\home\synthetic\.codex")
            && UsageCredentials.IsWsl("//wsl$/Ubuntu/home/synthetic/.codex"), "Extended and forward-slash WSL UNC aliases cannot trigger native Credential Manager reads");
        var upperHome = account with { Directory = @"\\wsl$\Ubuntu\home\User\.codex" };
        var lowerHome = account with { Directory = @"\\wsl.localhost\ubuntu\home\user\.codex" };
        Check(Usage.SourceKey(upperHome) != Usage.SourceKey(lowerHome), "WSL Linux path case remains distinct on every checks host");
        Check(Usage.NormalizeSourcePath(@"\\?\UNC\WSL$\Ubuntu\home\User\.\.codex\")
            == Usage.NormalizeSourcePath(@"\\wsl.localhost\ubuntu\home\User\.codex"), "WSL aliases and lexical separators normalize without inspecting the host filesystem");
        var filesystemRoot = Path.GetPathRoot(Path.GetTempPath())!;
        Check(Usage.NormalizeSourcePath(filesystemRoot) == filesystemRoot.ToUpperInvariant(), "Root directory separators remain intact");
    }

    private static void CacheValidation()
    {
        var good = Sample();
        Check(UsageSnapshots.Valid(good, Now), "Valid normalized snapshot accepted");
        foreach (var invalid in new[] {
            good with { FetchedAt = Now.AddTicks(1) }, good with { FetchedAt = Now.AddHours(-24).AddTicks(-1) },
            good with { Source = "diskCache" }, good with { CredentialFingerprint = "raw-secret" },
            good with { AccountIdentity = new string('z', 64) }, good with { AccountIdentity = "not-a-digest" },
            good with { Windows = [new("session", double.NaN, null)] }, good with { Windows = [new("session", 101, null)] },
            good with { Windows = [new("session", 10, Now)] }, good with { Windows = [new("session", 10, Now.AddDays(367))] },
            good with { Windows = [new("session", 10, null, "session", double.PositiveInfinity)] },
            good with { Windows = [new("one", 10, null, "same"), new("two", 20, null, "same")] },
            good with { Extras = [new("x", "credits", -1, "credits")] }, good with { Extras = [new("x", "reset", 1.5, "resets")] },
            good with { Extras = [new("x", "credits", double.PositiveInfinity, "credits")] } })
            Check(!UsageSnapshots.Valid(invalid, Now), "Strict cache age, finite, range, identity fingerprint, duration and reset validation");
        var identity = new ClaudeIdentity("account", "person@example.test", "org", null);
        var json = SwapJson(Now.AddSeconds(-30));
        var reading = UsageSnapshots.DecodeSwapCache(json, identity, Now);
        Check(reading?.Source == "swapCache" && reading.FetchedAt == Now.AddSeconds(-30) && reading.Windows.Length == 2,
            "Schema-two cswap cache keeps original sample age and models");
        Check(UsageSnapshots.DecodeSwapCache(json, identity with { OrganizationID = "other" }, Now) == null, "cswap cache cannot cross organizations");
        Check(UsageSnapshots.DecodeSwapCache(json, identity with { Email = "other@example.test" }, Now) == null, "cswap cache cannot cross accounts");
        Check(UsageSnapshots.DecodeSwapCache(SwapJson(Now.AddSeconds(1)), identity, Now) == null, "Future shared-cache sample rejected");
        Check(UsageSnapshots.DecodeSwapCache(SwapJson(Now.AddHours(-1).AddSeconds(-1)), identity, Now) == null, "Over-age shared-cache sample rejected");
        Reject(() => UsageSnapshots.DecodeSwapCache("""{"timestamp":1800000000,"data":{"1":{}}}""", identity, Now), "Legacy slot-only cache is never trusted");
        Reject(() => UsageSnapshots.DecodeSwapCache(json.Replace("\"pct\":20", "\"pct\":-1"), identity, Now), "Negative shared used percentage rejected");
        var overage = UsageSnapshots.DecodeSwapCache(json.Replace("\"pct\":20", "\"pct\":125"), identity, Now);
        Check(overage?.Windows[0].Remaining == 0, "Verified provider overage remains a measured exhausted quota in shared cache");
        Reject(() => UsageSnapshots.DecodeSwapCache(json.Replace("1800003600", "1799999999"), identity, Now), "Expired shared-cache reset rejected");
    }

    private static void RetryDates()
    {
        Check(UsageReader.RetryDate("45", Now) == Now.AddSeconds(45), "Retry-After delta");
        Check(UsageReader.RetryDate(Now.AddMinutes(3).ToString("r", CultureInfo.InvariantCulture), Now) == Now.AddMinutes(3), "Retry-After HTTP-date");
        foreach (var invalid in new string?[] { null, "", "0", "-1", "NaN", "Infinity", "garbage" })
            Check(UsageReader.RetryDate(invalid, Now) == Now.AddSeconds(120), "Missing, zero or invalid Retry-After uses bounded positive fallback");
        Check(UsageReader.RetryDate("172800", Now) == Now.AddDays(2), "Valid long server cooldown is never shortened");
        Check(UsageReader.RetryDate("1e300", Now) == DateTimeOffset.MaxValue, "Huge finite Retry-After cannot overflow");
    }

    private static async Task RunAsync()
    {
        using var files = new SyntheticFiles();
        var account = files.Account("one");
        files.WriteAuth(account, "first");
        int calls = 0;
        using var http = new HttpClient(new FixtureHandler(_ => {
            calls++;
            var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
            response.Headers.TryAddWithoutValidation("Retry-After", "60");
            return response;
        }));
        var reader = new UsageReader(http, () => Now, files.Cache);
        var initialFingerprint = await reader.CurrentFingerprint(account);
        Check(initialFingerprint is { Length: 64 }, "Current binding exposes only a one-way fingerprint without requiring disk cache");
        await RejectAsync<UsageCooldownException>(() => reader.Fetch(account), "Initial 429 surfaces retry time");
        await RejectAsync<UsageCooldownException>(() => reader.Fetch(account), "Manual refresh cannot bypass cooldown");
        Check(calls == 1, "Cooldown prevents another actual HTTP send");
        await RejectAsync<UsageCooldownException>(() => reader.Fetch(account with { Id = "duplicate-id" }), "Duplicate card IDs cannot bypass one credential cooldown");
        Check(calls == 1, "Same source with a new card ID remains blocked");
        var secondAccount = files.Account("two");
        await File.WriteAllTextAsync(Path.Combine(secondAccount.Directory, "auth.json"), Auth("other-workspace", "other@example.test", "second"));
        await RejectAsync<UsageCooldownException>(() => reader.Fetch(secondAccount), "Different actual account has independent cooldown");
        Check(calls == 2, "Other account did not inherit blocked account cooldown");
        files.WriteAuth(account, "rotated");
        Check(await reader.CurrentFingerprint(account) != initialFingerprint, "Current source fingerprint follows synthetic credential rotation");
        await RejectAsync<UsageCooldownException>(() => reader.Fetch(account), "Changed fingerprint starts its own cooldown");
        Check(calls == 3, "Credentials are reread on every fetch");

        using var liveHttp = new HttpClient(new FixtureHandler(_ => Json(CodexUsage)));
        var liveReader = new UsageReader(liveHttp, () => Now, files.Cache);
        var live = await liveReader.Fetch(account);
        Check(live.AccountIdentity == Usage.IdentityHash("Codex", "workspace", null, "person@example.test"),
            "Live pipeline exposes a complete verified owner digest rather than workspace-only identity");
        var disk = await liveReader.Cached(account);
        Check(disk?.Source == "diskCache" && disk.FetchedAt == live.FetchedAt && disk.CredentialFingerprint == live.CredentialFingerprint
            && !disk.IsCurrent(Now), "Last good snapshot survives load without masquerading as live");
        var persisted = await File.ReadAllTextAsync(new UsageSnapshots(files.Cache).SnapshotPath(account));
        var accessToken = Usage.ParseCredentials("Codex", Auth("workspace", "person@example.test", "rotated"), Now).Token;
        Check(!persisted.Contains("access_token") && !persisted.Contains(accessToken) && !persisted.Contains("refresh_token"), "Persisted snapshot excludes exact access token and credential document");
        Check(await liveReader.Cached(account with { Id = "unrelated" }) == null, "Snapshot storage is account-bound");
        files.WriteAuth(account, "another");
        Check(await liveReader.Cached(account) == null, "Old fingerprint never flashes after same-home login changes");
        var state = new ProviderState(account);
        state.Succeed(live);
        await File.WriteAllTextAsync(Path.Combine(account.Directory, "auth.json"), Auth("workspace-b", "b@example.test", "account-b"));
        state.VerifyFingerprint(await reader.CurrentFingerprint(account));
        try { await reader.Fetch(account); }
        catch (UsageCooldownException error) { state.Fail(error); }
        Check(state.Reading == null && state.Error != null && state.RetryAt == Now.AddMinutes(1),
            "A-to-B same-home switch followed by B 429 cannot retain A quota, identity or snapshot");
        await File.WriteAllTextAsync(Path.Combine(account.Directory, "auth.json"), "not json");
        Check(await liveReader.Cached(account) == null, "Unavailable current identity never authorizes old snapshot");
        Check(await liveReader.CurrentFingerprint(account) == null, "Unreadable current credential source yields unknown binding, not an old fingerprint");

        files.WriteAuth(account, "before-request");
        using var switchedHttp = new HttpClient(new FixtureHandler(_ => {
            files.WriteAuth(account, "after-request");
            return Json(CodexUsage);
        }));
        var switching = new UsageReader(switchedHttp, () => Now, Path.Combine(files.Root, "switch-cache"));
        await RejectAsync<UsageIdentityException>(() => switching.Fetch(account), "Mid-request credential change drops the old response");
        Check(await switching.Cached(account) == null, "Old response is not persisted under new credentials");
        foreach (var failure in new[] { "429", "401", "network", "cancelled", "missing" })
        {
            files.WriteAuth(account, "failed-request-owner-a");
            var failedCalls = 0;
            using var failedHttp = new HttpClient(new FixtureHandler(_ =>
            {
                failedCalls++;
                if (failure == "missing") File.Delete(Path.Combine(account.Directory, "auth.json"));
                else File.WriteAllText(Path.Combine(account.Directory, "auth.json"), Auth("workspace-b", "b@example.test", "failed-request-owner-b"));
                if (failure == "network") throw new HttpRequestException("synthetic");
                if (failure == "cancelled") throw new TaskCanceledException("synthetic");
                var response = new HttpResponseMessage(failure == "429" ? HttpStatusCode.TooManyRequests : HttpStatusCode.Unauthorized);
                response.Headers.TryAddWithoutValidation("Retry-After", "600");
                return response;
            }));
            var failedReader = new UsageReader(failedHttp, () => Now, Path.Combine(files.Root, "failure-" + failure));
            UsageIdentityException? changed = null;
            try { await failedReader.Fetch(account); }
            catch (UsageIdentityException error) { changed = error; }
            Check(changed != null && changed.RetryAt == null && failedCalls == 1,
                "Changed source on failed " + failure + " discards A error/cooldown without retrying its API");
        }

        var claude = files.Account("claude") with { Provider = "Claude", ExpectedAccountID = "account", ExpectedOrganizationID = "org", ExpectedEmail = "person@example.test" };
        await File.WriteAllTextAsync(Path.Combine(claude.Directory, ".credentials.json"), """{"claudeAiOauth":{"accessToken":"synthetic-claude","expiresAt":1999999999999}}""");
        using var mismatchHttp = new HttpClient(new FixtureHandler(_ => Json("""{"account":{"uuid":"wrong","email":"person@example.test"},"organization":{"uuid":"org"}}""")));
        var mismatchReader = new UsageReader(mismatchHttp, () => Now, files.Cache);
        await RejectAsync<UsageIdentityException>(() => mismatchReader.Fetch(claude), "Profile identity mismatch is not hidden by usage/cache fallback");

        var vaultAccount = claude with { VaultFile = Path.Combine(claude.Directory, "synthetic.enc") };
        File.Delete(Path.Combine(claude.Directory, ".credentials.json"));
        var vault = Convert.ToBase64String(Encoding.UTF8.GetBytes("""{"claudeAiOauth":{"accessToken":"vault-token","expiresAt":1999999999999}}"""));
        await File.WriteAllTextAsync(vaultAccount.VaultFile!, vault);
        var credential = await UsageCredentials.Read(vaultAccount, Now);
        Check(credential.Token == "vault-token" && credential.AuthSource.Contains("vault"), "cswap base64 vault is genuinely read without mutation");
        Check(await File.ReadAllTextAsync(vaultAccount.VaultFile!) == vault, "Read-only vault remains unchanged");

        var swapPath = Path.Combine(claude.Directory, "usage.json");
        await File.WriteAllTextAsync(swapPath, SwapJson(Now.AddSeconds(-30)));
        var swapAccount = vaultAccount with { SwapCacheFile = swapPath };
        int profileCalls = 0;
        using var swapHttp = new HttpClient(new FixtureHandler(request => {
            Check(request.RequestUri!.AbsolutePath.EndsWith("/profile"), "Fresh bound cswap cache avoids usage request");
            profileCalls++;
            return Json("""{"account":{"uuid":"account","email":"person@example.test"},"organization":{"uuid":"org"}}""");
        }));
        var swapReader = new UsageReader(swapHttp, () => Now, files.Cache);
        var shared = await swapReader.Fetch(swapAccount);
        Check(profileCalls == 1 && shared.Source == "swapCache" && shared.AccountID == "account"
            && shared.FetchedAt == Now.AddSeconds(-30), "Shared cache requires token-profile identity and preserves measurement time");
    }

    private static Reading Sample() => new([new("session", 50, Now.AddHours(1), "session", 18000)], Now)
        { CredentialFingerprint = new string('a', 64), AccountID = "workspace", AccountLabel = "person@example.test" };
    private static string SwapJson(DateTimeOffset fetched) => """
        {"schemaVersion":2,"accounts":{"1":{"email":"person@example.test","organizationUuid":"org","fetchedAt":FETCHED,
          "lastGood":{"five_hour":{"pct":20,"resets_at":1800003600},"scoped":[{"name":"Fable","pct":30,"resets_at":1800007200}]}}}}
        """.Replace("FETCHED", fetched.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture));
    private static string Auth(string account, string email, string marker, string? claimAccount = null, long? expiry = null)
    {
        var claims = JsonSerializer.Serialize(new Dictionary<string, object> {
            ["email"] = email, ["exp"] = expiry ?? Now.AddHours(1).ToUnixTimeSeconds(), ["marker"] = marker,
            ["https://api.openai.com/auth"] = new { chatgpt_account_id = claimAccount ?? account, chatgpt_user_id = "user", chatgpt_plan_type = "plus" }
        });
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return JsonSerializer.Serialize(new { tokens = new { access_token = "header." + payload + ".signature", account_id = account } });
    }
    private static HttpResponseMessage Json(string json) => new(HttpStatusCode.OK) { Content = new StringContent(json) };
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("Usage data check failed: " + message);
        checks++;
    }
    private static void Reject(Action action, string message)
    {
        try { action(); }
        catch (InvalidOperationException) { checks++; return; }
        throw new InvalidOperationException("Usage data check failed: " + message);
    }
    private static async Task RejectAsync<T>(Func<Task<Reading>> action, string message) where T : Exception
    {
        try { await action(); }
        catch (T) { checks++; return; }
        throw new InvalidOperationException("Usage data check failed: " + message);
    }
    private sealed class FixtureHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            => Task.FromResult(respond(request));
    }
    private sealed class SyntheticFiles : IDisposable
    {
        internal string Root { get; } = Path.Combine(Path.GetTempPath(), "chiikawa-usage-check-" + Guid.NewGuid().ToString("N"));
        internal string Cache => Path.Combine(Root, "cache");
        internal UsageAccount Account(string id)
        {
            var path = Path.Combine(Root, id);
            Directory.CreateDirectory(path);
            return new UsageAccount(id, "Codex", id, path);
        }
        internal void WriteAuth(UsageAccount account, string marker) => File.WriteAllText(Path.Combine(account.Directory, "auth.json"),
            Auth("workspace", "person@example.test", marker));
        public void Dispose() { if (Directory.Exists(Root)) Directory.Delete(Root, true); }
    }
}
