using System;
using ChiikawaPet;

internal static class UsagePolicyChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Check(bool condition, string reason)
        {
            if (!condition) throw new Exception(reason);
            checks++;
        }

        var now = DateTimeOffset.FromUnixTimeSeconds(1_780_000_000);
        var reset = now.AddSeconds(1800);
        Quota Window(double remaining, DateTimeOffset? ends = null, double? duration = 3600,
            string id = "session") => new("Session", remaining, ends ?? reset, id, duration);
        Reading Sample(double remaining, int second, DateTimeOffset? ends = null, string id = "session") =>
            new([Window(remaining, ends, id: id)], now.AddSeconds(second));
        var healthy = UsagePace.Projection(Window(80), now, now);
        Check(healthy is { RemainingAtReset: 60, ExhaustsAt: null, Severity: 0 }, "Healthy pace projects the full window");
        var tight = UsagePace.Projection(Window(55), now, now);
        Check(tight is { RemainingAtReset: 10, ExhaustsAt: null, Severity: 0 }, "Exactly ten percent projected remaining is healthy");
        var lowSpare = UsagePace.Projection(Window(54), now, now);
        Check(lowSpare is { ExhaustsAt: null, Severity: 1 } && Math.Abs(lowSpare.RemainingAtReset - 8) < 0.000001,
            "Less than ten percent projected remaining is tight");
        var exhausting = UsagePace.Projection(Window(40), now, now);
        Check(exhausting is { RemainingAtReset: 0, Severity: 2 }
            && exhausting.ExhaustsAt == now.AddSeconds(1200), "Exhaustion date and zero-clamped projection");
        Check(UsagePace.Projection(Window(50), now, now) is { RemainingAtReset: 0, ExhaustsAt: null, Severity: 2 },
            "Exhaustion exactly at reset is severe without an earlier exhaustion time");
        Check(UsagePace.Projection(Window(100), now, now) is { RemainingAtReset: 100, ExhaustsAt: null, Severity: 0 },
            "Zero use has no invented exhaustion time");
        Check(UsagePace.Projection(Window(0), now, now) is { RemainingAtReset: 0, Severity: 2 }, "Already exhausted stays zero");
        Check(UsagePace.Projection(Window(99, now.AddSeconds(3540)), now, now) != null,
            "Exactly sixty seconds of elapsed window is sufficient");
        Check(UsagePace.Projection(Window(99, now.AddSeconds(3541)), now, now) == null,
            "Less than sixty seconds cannot drive pace");
        Check(UsagePace.Projection(Window(100, now.AddSeconds(598752), 604800), now, now) != null,
            "Exactly one percent of a weekly window is sufficient");
        Check(UsagePace.Projection(Window(100, now.AddSeconds(598753), 604800), now, now) == null,
            "Weekly windows require more than sixty elapsed seconds");
        Check(UsagePace.Projection(Window(80), now, now.AddMinutes(15)) != null,
            "Fifteen-minute freshness boundary is inclusive");
        Check(UsagePace.Projection(Window(80), now, now.AddMinutes(15).AddTicks(1)) == null,
            "Samples older than fifteen minutes cannot drive pace");
        Check(UsagePace.Projection(Window(80), now.AddTicks(1), now) == null, "Future samples cannot drive pace");
        Check(UsagePace.Projection(Window(80, now), now, now) == null, "Expired resets cannot drive pace");
        Check(UsagePace.Projection(Window(80, now.AddSeconds(3601)), now, now) == null,
            "A window that has not started cannot drive pace");
        Check(UsagePace.Projection(new Quota("Unknown", 80, null, "unknown", 3600), now, now) == null,
            "Missing reset cannot drive pace");
        foreach (double? duration in new double?[] { null, 0, -1, double.NaN, double.PositiveInfinity })
            Check(UsagePace.Projection(Window(80, duration: duration), now, now) == null, "Invalid duration cannot drive pace");
        foreach (double remaining in new[] { -1d, 101d, double.NaN, double.NegativeInfinity })
            Check(UsagePace.Projection(Window(remaining), now, now) == null, "Invalid remaining cannot drive pace");

        double[] thresholds = [30, 10];
        var policy = new UsageAlertPolicy();
        UsageAlertEvent[] Evaluate(Reading sample, string account = "account-a", bool pace = false) =>
            policy.Evaluate(account, sample, sample.FetchedAt, thresholds, pace);
        Check(Evaluate(Sample(80, 0)).Length == 0, "First account reading establishes a silent baseline");
        var firstEntry = Evaluate(Sample(30, 1));
        Check(firstEntry.Length == 1 && firstEntry[0].MetricTitle == "Session" && firstEntry[0].Message.Length > 0,
            "Equality enters the threshold with a usable event");
        Check(Evaluate(Sample(29, 2)).Length == 0, "Remaining in a threshold does not repeat the alert");
        Check(Evaluate(Sample(9, 3)).Length == 1, "A worse threshold is a separate transition");
        Check(Evaluate(Sample(40, 4)).Length == 0, "Recovery is silent and rearms thresholds");
        var reentry = Evaluate(Sample(29, 5));
        Check(reentry.Length == 1 && reentry[0].Id != firstEntry[0].Id, "Recovery permits a distinct reentry alert");
        Check(Evaluate(Sample(29, 5)).Length == 0, "Replaying the same measured sample does not alert");
        Check(Evaluate(Sample(9, 4)).Length == 0, "Out-of-order samples do not regress alert state");
        var nextReset = reset.AddHours(1);
        Check(Evaluate(Sample(5, 6, nextReset)).Length == 0, "A new reset establishes a silent baseline");
        Check(Evaluate(Sample(80, 7, nextReset)).Length == 0, "New reset recovery rearms thresholds");
        Check(Evaluate(Sample(80, 5)).Length == 0, "An older reset sample cannot replace the newer interval baseline");
        Check(Evaluate(Sample(5, 8, nextReset)).Length == 2, "A new interval can enter both rearmed thresholds");
        Check(Evaluate(Sample(5, 9), "account-b").Length == 0, "Another account has an independent silent baseline");
        Check(Evaluate(Sample(5, 10, id: "weekly")).Length == 0, "Another metric has an independent silent baseline");
        Check(new UsageAlertPolicy().Evaluate("account", Sample(5, 0), now, thresholds, false).Length == 0,
            "Launching below all thresholds is silent");

        var gated = new UsageAlertPolicy();
        Check(gated.Evaluate("account", Sample(80, 0), now, thresholds, false).Length == 0, "Gating baseline");
        var disk = Sample(5, 1) with { Source = "diskCache" };
        Check(gated.Evaluate("account", disk, disk.FetchedAt, thresholds, true).Length == 0, "Disk cache cannot alert");
        var stale = Sample(5, -901);
        Check(gated.Evaluate("account", stale, now, thresholds, true).Length == 0, "Stale reading cannot alert");
        var future = Sample(5, 10);
        Check(gated.Evaluate("account", future, now, thresholds, true).Length == 0, "Future reading cannot alert");
        var cooldown = Sample(5, 2) with { RetryAt = now.AddMinutes(1) };
        Check(gated.Evaluate("account", cooldown, cooldown.FetchedAt, thresholds, true).Length == 0, "Cooldown reading cannot alert");
        var live = Sample(5, 3);
        Check(gated.Evaluate("account", live, live.FetchedAt, thresholds, false).Length == 2,
            "Rejected readings do not consume threshold transitions");
        var expired = new Reading([Window(5, now)], now);
        Check(gated.Evaluate("account", expired, now, thresholds, true).Length == 0, "Expired resets cannot alert");
        var noReset = new Reading([new Quota("Unknown", 80, null, "unknown", 3600)], now);
        Check(gated.Evaluate("account", noReset, now, thresholds, false).Length == 0, "Unknown reset does not create an interval");
        var noResetLow = new Reading([new Quota("Unknown", 5, null, "unknown", 3600)], now.AddSeconds(1));
        Check(gated.Evaluate("account", noResetLow, noResetLow.FetchedAt, thresholds, false).Length == 0,
            "Unknown reset never uses a fabricated reset identity");
        var discoveredReset = Sample(5, 2, id: "unknown");
        Check(gated.Evaluate("account", discoveredReset, discoveredReset.FetchedAt, thresholds, false).Length == 0,
            "Learning a real reset starts a new silent baseline");

        var duplicateThresholds = new UsageAlertPolicy();
        double[] repeated = [30, 30, 10, double.NaN, -1, 101];
        duplicateThresholds.Evaluate("account", Sample(80, 0), now, repeated, false);
        Check(duplicateThresholds.Evaluate("account", Sample(5, 1), now.AddSeconds(1), repeated, false).Length == 2,
            "Duplicate and invalid thresholds cannot produce duplicate alerts");
        var addedThreshold = new UsageAlertPolicy();
        addedThreshold.Evaluate("account", Sample(20, 0), now, [10], false);
        Check(addedThreshold.Evaluate("account", Sample(19, 1), now.AddSeconds(1), [30, 10], false).Length == 0,
            "Adding a threshold establishes its own silent baseline");

        var pacePolicy = new UsageAlertPolicy();
        UsageAlertEvent[] Pace(double remaining, int second, bool enabled = true) =>
            pacePolicy.Evaluate("account", Sample(remaining, second), now.AddSeconds(second), [], enabled);
        Check(Pace(80, 0).Length == 0, "Initial pace is silent");
        Check(Pace(54, 1).Length == 1, "Pace worsening to tight alerts when enabled");
        Check(Pace(54, 2).Length == 0, "Unchanged pace severity is deduplicated");
        Check(Pace(40, 3).Length == 1, "Pace worsening to exhaustion alerts");
        Check(Pace(80, 4).Length == 0, "Pace recovery is silent");
        Check(Pace(54, 5).Length == 1, "Pace recovery rearms worsening alerts");
        Check(Pace(80, 6, false).Length == 0, "Disabled pace emits nothing");
        Check(Pace(40, 7).Length == 0, "Enabling pace establishes a silent pace baseline");
        var identityPolicy = new UsageAlertPolicy();
        var accountA = Sample(80, 0) with { AccountIdentity = Usage.Hash("workspace:person-a@example.test"), CredentialFingerprint = Usage.Hash("token-a-1") };
        string accountAKey = UsageAlertPolicy.AccountKey("default-codex", accountA);
        Check(identityPolicy.Evaluate(accountAKey, accountA, now, thresholds, false).Length == 0, "Verified account A establishes its first baseline");
        var rotatedA = Sample(30, 1) with { AccountIdentity = accountA.AccountIdentity, CredentialFingerprint = Usage.Hash("token-a-2") };
        Check(UsageAlertPolicy.AccountKey("default-codex", rotatedA) == accountAKey
            && identityPolicy.Evaluate(accountAKey, rotatedA, now.AddSeconds(1), thresholds, false).Length == 1,
            "Same verified user token rotation retains threshold transition state");
        var accountB = Sample(5, 2) with { AccountIdentity = Usage.Hash("workspace:person-b@example.test"), CredentialFingerprint = Usage.Hash("token-b") };
        string accountBKey = UsageAlertPolicy.AccountKey("default-codex", accountB);
        Check(accountBKey != accountAKey && identityPolicy.Evaluate(accountBKey, accountB, now.AddSeconds(2), thresholds, false).Length == 0,
            "A different user in the same workspace and reset interval starts silently instead of inheriting A's thresholds");
        var unknownA = accountA with { AccountIdentity = null };
        var unknownB = accountB with { AccountIdentity = null };
        Check(UsageAlertPolicy.AccountKey("default-codex", unknownA) != UsageAlertPolicy.AccountKey("default-codex", unknownB),
            "Incomplete identities fall back to per-credential baselines, never shared workspace identity");
        var missingResetA = accountA with { Windows = [new Quota("Session", 80, null, "session", 18000)] };
        var missingResetB = accountB with { Windows = [new Quota("Session", 5, null, "session", 18000)] };
        Check(identityPolicy.Evaluate(accountAKey, missingResetA, now, thresholds, false).Length == 0
            && identityPolicy.Evaluate(accountBKey, missingResetB, now.AddSeconds(2), thresholds, false).Length == 0,
            "Account switches without a known reset never fabricate an alert interval");
        return checks;
    }
}
