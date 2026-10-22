using System;
using System.Collections.Generic;
using System.Globalization;

namespace ChiikawaPet;

internal sealed record UsageProjection(double RemainingAtReset, DateTimeOffset? ExhaustsAt, int Severity);

internal static class UsagePace
{
    public static UsageProjection? Projection(Quota quota, DateTimeOffset measuredAt, DateTimeOffset now)
    {
        if (measuredAt > now || now - measuredAt > TimeSpan.FromMinutes(15)
            || quota.ResetsAt is not DateTimeOffset reset || reset <= now
            || quota.DurationSeconds is not double duration || !double.IsFinite(duration) || duration <= 0
            || !double.IsFinite(quota.Remaining) || quota.Remaining < 0 || quota.Remaining > 100)
            return null;

        double secondsUntilReset = (reset - measuredAt).TotalSeconds;
        double elapsed = duration - secondsUntilReset;
        if (elapsed < Math.Max(60, duration * 0.01) || elapsed >= duration) return null;

        double used = 100 - quota.Remaining;
        double usedPerSecond = used / elapsed;
        double projectedRemaining = 100 - usedPerSecond * duration;
        DateTimeOffset? exhaustsAt = null;
        if (usedPerSecond > 0)
        {
            double secondsToExhaust = quota.Remaining / usedPerSecond;
            if (secondsToExhaust < secondsUntilReset) exhaustsAt = measuredAt.AddSeconds(secondsToExhaust);
        }
        int severity = projectedRemaining <= 0 ? 2 : projectedRemaining < 10 ? 1 : 0;
        return new UsageProjection(Math.Clamp(projectedRemaining, 0, 100), exhaustsAt, severity);
    }
}

internal sealed record UsageAlertEvent(string Id, string MetricTitle, string Message,
    double? Threshold = null, int? PaceSeverity = null);

internal sealed class UsageAlertPolicy
{
    private sealed class WindowState(DateTimeOffset reset, DateTimeOffset measuredAt)
    {
        public DateTimeOffset Reset { get; } = reset;
        public DateTimeOffset MeasuredAt { get; set; } = measuredAt;
        public Dictionary<double, bool> Thresholds { get; } = new();
        public int? PaceSeverity { get; set; }
    }

    private readonly Dictionary<(string AccountId, string MetricId), WindowState> windows = new();

    public static string AccountKey(string cardId, Reading reading)
    {
        string? identity = reading.AccountIdentity ?? reading.CredentialFingerprint;
        if (string.IsNullOrWhiteSpace(cardId) || string.IsNullOrWhiteSpace(identity)) return "";
        return cardId.Length.ToString(CultureInfo.InvariantCulture) + ":" + cardId + identity;
    }

    public UsageAlertEvent[] Evaluate(string accountId, Reading reading, DateTimeOffset now,
        double[] thresholds, bool paceEnabled)
    {
        if (string.IsNullOrWhiteSpace(accountId) || !reading.IsCurrent(now) || reading.RetryAt > now) return [];
        List<UsageAlertEvent>? alerts = null;
        foreach (var quota in reading.Windows)
        {
            if (string.IsNullOrWhiteSpace(quota.Id) || quota.ResetsAt is not DateTimeOffset reset
                || reset <= now || !double.IsFinite(quota.Remaining)
                || quota.Remaining < 0 || quota.Remaining > 100) continue;

            var key = (accountId, quota.Id);
            bool baseline = !windows.TryGetValue(key, out var previous) || previous.Reset != reset;
            if (previous != null && reading.FetchedAt <= previous.MeasuredAt) continue;
            var state = baseline ? new WindowState(reset, reading.FetchedAt) : previous!;
            windows[key] = state;
            state.MeasuredAt = reading.FetchedAt;

            foreach (double threshold in thresholds)
            {
                if (!double.IsFinite(threshold) || threshold < 0 || threshold > 100) continue;
                bool entered = quota.Remaining <= threshold;
                bool hadBaseline = state.Thresholds.TryGetValue(threshold, out bool wasEntered);
                state.Thresholds[threshold] = entered;
                if (baseline || !hadBaseline || wasEntered || !entered) continue;
                alerts ??= new List<UsageAlertEvent>();
                string thresholdLabel = threshold.ToString("0.##", CultureInfo.InvariantCulture);
                string id = EventId(accountId, quota.Id, reset, reading.FetchedAt, "threshold:" + thresholdLabel);
                alerts.Add(new UsageAlertEvent(id, quota.Title,
                    $"{quota.Title}: remaining usage has reached {thresholdLabel}% or less.", Threshold: threshold));
            }

            var projection = paceEnabled ? UsagePace.Projection(quota, reading.FetchedAt, now) : null;
            if (!baseline && projection != null && state.PaceSeverity is int previousSeverity
                && projection.Severity > previousSeverity)
            {
                alerts ??= new List<UsageAlertEvent>();
                string id = EventId(accountId, quota.Id, reset, reading.FetchedAt, "pace");
                string message = projection.Severity == 2
                    ? $"{quota.Title}: at this pace, usage will run out at or before reset."
                    : $"{quota.Title}: at this pace, little usage will remain at reset.";
                alerts.Add(new UsageAlertEvent(id, quota.Title, message, PaceSeverity: projection.Severity));
            }
            state.PaceSeverity = projection?.Severity;
        }
        return alerts?.ToArray() ?? [];
    }

    private static string EventId(string accountId, string metricId, DateTimeOffset reset,
        DateTimeOffset measuredAt, string transition) =>
        $"{accountId.Length}:{accountId}{metricId.Length}:{metricId}:{reset.UtcTicks}:{measuredAt.UtcTicks}:{transition}";
}
