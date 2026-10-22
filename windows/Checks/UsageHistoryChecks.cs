using ChiikawaPet;

internal static class UsageHistoryChecks
{
    internal static async Task<int> Run()
    {
        int checks = 0;
        void Check(bool condition, string reason) { if (!condition) throw new Exception(reason); checks++; }
        string root = Path.Combine(Path.GetTempPath(), "chiikawa-history-" + Guid.NewGuid().ToString("N"));
        string claudeHome = Path.Combine(root, "claude");
        string codexHome = Path.Combine(root, "codex");
        Directory.CreateDirectory(Path.Combine(claudeHome, "projects", "fixture"));
        Directory.CreateDirectory(Path.Combine(codexHome, "sessions"));
        Directory.CreateDirectory(Path.Combine(codexHome, "archived_sessions"));
        try
        {
            // OpenUsage ClaudeLogUsageScanner and official Codex token_count payload contracts.
            const string claude = """
                {"type":"assistant","timestamp":"2026-10-21T12:00:00Z","requestId":"r","isSidechain":false,"message":{"id":"m","model":"fixture","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":10}}}
                """;
            await File.WriteAllLinesAsync(Path.Combine(claudeHome, "projects", "fixture", "a.jsonl"), [claude, claude, "not-json"]);
            var unpriced = await LocalUsageHistory.ScanAsync("Claude", claudeHome);
            var day = unpriced.Days.Single();
            Check(day.InputTokens == 110 && day.OutputTokens == 20 && day.CachedTokens == 30 && day.TotalTokens == 160,
                "Claude snapshots count message once and preserve cache-write/read categories");
            Check(day.EstimatedCost == null && day.UnpricedTokens == 160 && unpriced.Warning != null,
                "Unknown prices and corrupt records are explicit, never invented zero-cost usage");
            string pricing = Path.Combine(root, "pricing.json");
            await File.WriteAllTextAsync(pricing, """
                {"version":1,"models":{"fixture":{"inputPerMillion":3,"outputPerMillion":15,"cachedInputPerMillion":0.5,"cacheWritePerMillion":4}}}
                """);
            var priced = await LocalUsageHistory.ScanAsync("claude", claudeHome, pricing);
            Check(priced.Days.Single().EstimatedCost is double cost && Math.Abs(cost - 0.000655) < 1e-12
                && priced.Days.Single().UnpricedTokens == 0, "Explicit API-rate estimate prices all four token categories");
            string specialHome = Path.Combine(root, "special");
            Directory.CreateDirectory(Path.Combine(specialHome, "projects"));
            string specialLog = Path.Combine(specialHome, "projects", "events.jsonl");
            const string hourWrite = """
                {"type":"assistant","timestamp":"2026-10-21T12:00:00Z","requestId":"hour","message":{"id":"hour","model":"fixture","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":10,"cache_creation":{"ephemeral_1h_input_tokens":10,"ephemeral_5m_input_tokens":0}}}}
                """;
            await File.WriteAllTextAsync(specialLog, hourWrite + Environment.NewLine);
            var hourUnpriced = await LocalUsageHistory.ScanAsync("claude", specialHome, pricing);
            Check(hourUnpriced.Days.Single().EstimatedCost == null && hourUnpriced.Days.Single().UnpricedTokens == 160,
                "One-hour cache creation requires an explicitly supplied one-hour price");
            await File.WriteAllTextAsync(pricing, """
                {"version":1,"models":{"fixture":{"inputPerMillion":3,"outputPerMillion":15,"cachedInputPerMillion":0.5,"cacheWritePerMillion":4,"cacheWriteOneHourPerMillion":6}}}
                """);
            var hourPriced = await LocalUsageHistory.ScanAsync("claude", specialHome, pricing);
            Check(hourPriced.Days.Single().EstimatedCost is double hourCost && Math.Abs(hourCost - 0.000675) < 1e-12,
                "One-hour cache tokens use their actual custom rate, not the five-minute write rate");
            await File.WriteAllTextAsync(specialLog, claude.Replace("\"input_tokens\":100", "\"speed\":\"fast\",\"input_tokens\":100") + Environment.NewLine);
            var fast = await LocalUsageHistory.ScanAsync("claude", specialHome, pricing);
            Check(fast.Days.Single().EstimatedCost == null && fast.Days.Single().UnpricedTokens == 160,
                "Special speed tiers remain unpriced under standard-only model rates");
            await File.WriteAllLinesAsync(specialLog, [claude, claude.Replace("\"id\":\"m\"", "\"id\":\"unknown\"").Replace("\"requestId\":\"r\"", "\"requestId\":\"unknown\"").Replace("\"model\":\"fixture\"", "\"model\":\"unlisted\"")]);
            var partialPrice = await LocalUsageHistory.ScanAsync("claude", specialHome, pricing);
            Check(partialPrice.Days.Single().EstimatedCost is double subtotal && Math.Abs(subtotal - 0.000655) < 1e-12
                && partialPrice.Days.Single().UnpricedTokens == 160 && partialPrice.Warning != null,
                "Mixed known and unknown models expose a priced subtotal and explicit unpriced usage");
            await File.WriteAllTextAsync(specialLog, claude.Replace("\"usage\":{", "\"usage\":{\"iterations\":[null],") + Environment.NewLine);
            var nullAdvisor = await LocalUsageHistory.ScanAsync("claude", specialHome, pricing);
            Check(nullAdvisor.Days.Single().TotalTokens == 160 && nullAdvisor.Warning != null,
                "A null advisor iteration preserves parent usage and marks the history incomplete");
            foreach (string tier in new[] { "priority", "batch" })
            {
                await File.WriteAllTextAsync(specialLog, claude.Replace("\"usage\":{", "\"usage\":{\"speed\":\"standard\",\"service_tier\":\"" + tier + "\",") + Environment.NewLine);
                var specialTier = await LocalUsageHistory.ScanAsync("claude", specialHome, pricing);
                Check(specialTier.Days.Single().TotalTokens == 160 && specialTier.Days.Single().UnpricedTokens == 160
                    && specialTier.Days.Single().EstimatedCost == null, "A nonstandard service tier is not priced using standard rates");
            }
            await File.WriteAllTextAsync(specialLog, claude.Replace("\"usage\":{", "\"usage\":{\"iterations\":[{\"type\":\"advisor_message\",\"model\":\"fixture\",\"service_tier\":\"priority\",\"speed\":\"standard\",\"input_tokens\":7,\"output_tokens\":3}],") + Environment.NewLine);
            var specialAdvisor = await LocalUsageHistory.ScanAsync("claude", specialHome, pricing);
            Check(specialAdvisor.Days.Single().TotalTokens == 170 && specialAdvisor.Days.Single().UnpricedTokens == 10
                && specialAdvisor.Days.Single().EstimatedCost is double advisorSubtotal && Math.Abs(advisorSubtotal - 0.000655) < 1e-12,
                "A special-tier advisor remains measured but unpriced beside its standard-rate parent");
            await File.WriteAllTextAsync(pricing, """
                {"version":1,"models":{"fixture":{"inputPerMillion":-1,"outputPerMillion":15,"cachedInputPerMillion":0.5,"cacheWritePerMillion":4}}}
                """);
            bool rejected = false;
            try { await LocalUsageHistory.ScanAsync("claude", claudeHome, pricing); }
            catch (InvalidDataException) { rejected = true; }
            Check(rejected, "Negative custom prices are rejected instead of generating misleading costs");
            await File.WriteAllTextAsync(pricing, """
                {"version":1,"models":{"fixture":{"inputPerMillion":3,"outputPerMillion":15,"cachedInputPerMillion":0.5}}}
                """);
            rejected = false;
            try { await LocalUsageHistory.ScanAsync("claude", claudeHome, pricing); }
            catch (InvalidDataException) { rejected = true; }
            Check(rejected, "Missing cache-write pricing does not silently become free");

            string[] codex = [
                """{"type":"session_meta","timestamp":"2026-10-21T12:00:00Z","payload":{"id":"session-a","source":"cli"}}""",
                """{"type":"event_msg","timestamp":"2026-10-21T12:00:00Z","payload":{"type":"token_count","model":"fixture","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20}}}}""",
                """{"type":"event_msg","timestamp":"2026-10-21T12:01:00Z","payload":{"type":"token_count","model":"fixture","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":40,"output_tokens":30}}}}""",
                """{"type":"event_msg","timestamp":"2026-10-21T12:02:00Z","payload":{"type":"token_count","model":"fixture","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":40,"output_tokens":30}}}}"""
            ];
            await File.WriteAllLinesAsync(Path.Combine(codexHome, "sessions", "a.jsonl"), codex);
            await File.WriteAllLinesAsync(Path.Combine(codexHome, "archived_sessions", "copy.jsonl"), codex);
            var measured = await LocalUsageHistory.ScanAsync("Codex", codexHome);
            day = measured.Days.Single();
            Check(day.InputTokens == 110 && day.CachedTokens == 40 && day.OutputTokens == 30 && day.TotalTokens == 180,
                "Codex cumulative deltas, repeated totals, and archived copies never double count");
            Check(day.UnpricedTokens == 180 && day.EstimatedCost == null, "No bundled speculative pricing for Codex models");
            await File.WriteAllLinesAsync(Path.Combine(codexHome, "sessions", "different-session.jsonl"),
                codex.Select(line => line.Replace("\"id\":\"session-a\"", "\"id\":\"session-b\"")));
            var separateSessions = await LocalUsageHistory.ScanAsync("Codex", codexHome);
            Check(separateSessions.Days.Single().TotalTokens == 360 && separateSessions.Days.Single().CachedTokens == 80,
                "Known different sessions retain identical events, while copied files of one session remain deduplicated");
            using var cancellation = new CancellationTokenSource();
            cancellation.Cancel();
            bool cancelled = false;
            try { await LocalUsageHistory.ScanAsync("Claude", claudeHome, pricing, cancellation.Token); }
            catch (OperationCanceledException) { cancelled = true; }
            Check(cancelled, "A pre-cancelled scan stops before parsing logs or invalid pricing");
            var absent = await LocalUsageHistory.ScanAsync("codex", Path.Combine(root, "missing"));
            Check(absent.Days.Count == 0 && absent.Warning != null, "Missing logs are unknown/no measured events, not fake totals");
        }
        finally { Directory.Delete(root, true); }
        return checks;
    }
}
