using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace ChiikawaPet;

internal sealed record UsageHistorySummary(IReadOnlyList<UsageHistoryDay> Days, string? Warning);
internal sealed record UsageHistoryDay(string Day)
{
    public long InputTokens { get; internal set; }
    public long OutputTokens { get; internal set; }
    public long CachedTokens { get; internal set; }
    public double? EstimatedCost { get; internal set; }
    public long UnpricedTokens { get; internal set; }
    public long TotalTokens => InputTokens + OutputTokens + CachedTokens;
}

// Contracts: openai/codex codex-rs/protocol/src/protocol.rs; OpenUsage commit
// 26132ff48dd78eb2c4a9498e40424e6365f99fec ClaudeLogUsageScanner / CodexLogFileParser.
// Opt-in is the caller's boundary. Logs belong to the selected home, not its current login.
internal static class LocalUsageHistory
{
    public static Task<UsageHistorySummary> ScanAsync(string provider, string directory, string? pricingFile = null, CancellationToken cancellationToken = default)
    {
        if (!string.Equals(provider, "claude", StringComparison.OrdinalIgnoreCase)
            && !string.Equals(provider, "codex", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Unsupported history provider.");
        return Task.Run(() => new Scan(cancellationToken).Run(string.Equals(provider, "claude", StringComparison.OrdinalIgnoreCase), directory, pricingFile), cancellationToken);
    }

    private sealed class Rates
    {
        [JsonRequired] public double inputPerMillion { get; set; }
        [JsonRequired] public double outputPerMillion { get; set; }
        [JsonRequired] public double cachedInputPerMillion { get; set; }
        [JsonRequired] public double cacheWritePerMillion { get; set; }
        public double? cacheWriteOneHourPerMillion { get; set; }
        public bool Valid => RateValid(inputPerMillion) && RateValid(outputPerMillion)
            && RateValid(cachedInputPerMillion) && RateValid(cacheWritePerMillion)
            && (!cacheWriteOneHourPerMillion.HasValue || RateValid(cacheWriteOneHourPerMillion.Value));
        private static bool RateValid(double rate) => double.IsFinite(rate) && rate >= 0 && rate <= 1e12;
    }
    private sealed class Prices
    {
        public int version { get; set; }
        public Dictionary<string, Rates>? models { get; set; }
    }
    private sealed class Envelope
    {
        public string? type { get; set; }
        public string? timestamp { get; set; }
        public string? requestId { get; set; }
        public bool? isSidechain { get; set; }
        public Message? message { get; set; }
        public Payload? payload { get; set; }
    }
    private sealed class Message
    {
        public string? id { get; set; }
        public string? model { get; set; }
        public RawUsage? usage { get; set; }
    }
    private sealed class Payload
    {
        public string? type { get; set; }
        public string? id { get; set; }
        public string? model { get; set; }
        public string? model_name { get; set; }
        public ModelMetadata? metadata { get; set; }
        public TokenInfo? info { get; set; }
        public string? forked_from_id { get; set; }
        public string? parent_thread_id { get; set; }
        public string? thread_source { get; set; }
        public JsonElement source { get; set; }
        public double? started_at { get; set; }
        public ThreadSettings? thread_settings { get; set; }
        public string? service_tier { get; set; }
        public string? Model => model ?? model_name ?? metadata?.model;
        public bool Child => !string.IsNullOrWhiteSpace(forked_from_id) || !string.IsNullOrWhiteSpace(parent_thread_id)
            || thread_source == "subagent" || (source.ValueKind == JsonValueKind.String && source.GetString() == "subagent")
            || (source.ValueKind == JsonValueKind.Object && source.TryGetProperty("subagent", out var child)
                && child.ValueKind != JsonValueKind.Null);
    }
    private sealed class ModelMetadata { public string? model { get; set; } }
    private sealed class ThreadSettings { public string? service_tier { get; set; } }
    private sealed class TokenInfo
    {
        public RawUsage? total_token_usage { get; set; }
        public RawUsage? last_token_usage { get; set; }
        public string? model { get; set; }
        public string? model_name { get; set; }
    }
    private sealed class CacheCreation
    {
        public long? ephemeral_5m_input_tokens { get; set; }
        public long? ephemeral_1h_input_tokens { get; set; }
    }
    private sealed class RawUsage
    {
        public string? type { get; set; }
        public string? model { get; set; }
        public long? input_tokens { get; set; }
        public long? output_tokens { get; set; }
        public long? cached_input_tokens { get; set; }
        public long? cache_read_input_tokens { get; set; }
        public long? cache_creation_input_tokens { get; set; }
        public long? cache_write_input_tokens { get; set; }
        public CacheCreation? cache_creation { get; set; }
        public string? speed { get; set; }
        public string? service_tier { get; set; }
        public List<RawUsage?>? iterations { get; set; }
        public bool SpecialRate => (speed != null && speed != "standard") || (service_tier != null && service_tier != "standard");

        public Tokens Normalize(bool claude)
        {
            if (!input_tokens.HasValue || !output_tokens.HasValue) throw new InvalidDataException();
            long input = input_tokens.Value, output = output_tokens.Value;
            long cached = (claude ? cache_read_input_tokens : cached_input_tokens) ?? 0;
            long oneHour = cache_creation?.ephemeral_1h_input_tokens ?? 0;
            long fiveMinute = cache_creation?.ephemeral_5m_input_tokens ?? 0;
            long writes = (claude ? cache_creation_input_tokens : cache_write_input_tokens) ?? 0;
            if (!CountValid(input) || !CountValid(output) || !CountValid(cached) || !CountValid(oneHour)
                || !CountValid(fiveMinute) || !CountValid(writes)) throw new InvalidDataException();
            if (claude && !cache_creation_input_tokens.HasValue) writes = fiveMinute + oneHour;
            if (cache_creation == null) fiveMinute = writes;
            if (!CountValid(writes) || (!claude && cached + writes > input)
                || (cache_creation != null && fiveMinute + oneHour != writes)) throw new InvalidDataException();
            return new Tokens(claude ? input : input - cached - writes, output, cached, fiveMinute, oneHour);
        }
    }
    private readonly record struct Tokens(long Input, long Output, long Cached, long Writes, long OneHour)
    {
        public long Total => Input + Output + Cached + Writes + OneHour;
        public Tokens Delta(Tokens? previous)
        {
            Tokens before = previous ?? default;
            if (Input < before.Input || Output < before.Output || Cached < before.Cached
                || Writes < before.Writes || OneHour < before.OneHour) throw new InvalidDataException();
            return new Tokens(Input - before.Input, Output - before.Output, Cached - before.Cached,
                Writes - before.Writes, OneHour - before.OneHour);
        }
    }
    private sealed record Event(DateTimeOffset Date, string? Model, Tokens Tokens, string Request, bool Sidechain, bool SpecialRate);
    private readonly record struct CodexKey(string? SessionID, DateTimeOffset Date, string? Model, Tokens Tokens, bool SpecialRate);
    private sealed class FileContext
    {
        public Tokens? Previous;
        public string? Model;
        public string? SessionID;
        public bool SawMeta;
        public bool Replaying;
        public DateTimeOffset? Created;
        public bool SpecialRate;
    }

    private sealed class Scan(CancellationToken cancellationToken)
    {
        private readonly Dictionary<string, List<Event>> claudeMessages = new(StringComparer.Ordinal);
        private readonly Dictionary<CodexKey, Event> codexEvents = new();
        private int eventCount, files;
        private long readBytes;
        private bool incomplete, limited;
        private const int MaxEvents = 250_000;

        public UsageHistorySummary Run(bool claude, string directory, string? pricingFile)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var prices = LoadPrices(pricingFile);
            string[] roots = claude ? new[] { "projects" } : new[] { "sessions", "archived_sessions" };
            var activeRelativePaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string name in roots)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    string root = Path.Combine(directory, name);
                    if (!Directory.Exists(root)) continue;
                    var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = false,
                        AttributesToSkip = FileAttributes.ReparsePoint, ReturnSpecialDirectories = false };
                    foreach (string file in Directory.EnumerateFiles(root, "*.jsonl", options))
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        if (limited) break;
                        if (!claude)
                        {
                            string relative = Path.GetRelativePath(root, file);
                            if (name == "archived_sessions" && activeRelativePaths.Contains(relative)) continue;
                            if (name == "sessions") activeRelativePaths.Add(relative);
                        }
                        if (++files > 20_000) { limited = true; break; }
                        ParseFile(file, claude);
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
                { incomplete = true; }
            }
            var days = new SortedDictionary<string, UsageHistoryDay>(StringComparer.Ordinal);
            foreach (var matches in claudeMessages.Values)
                foreach (var entry in matches)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    Aggregate(entry, prices, days);
                }
            foreach (var entry in codexEvents.Values)
            {
                cancellationToken.ThrowIfCancellationRequested();
                Aggregate(entry, prices, days);
            }
            var warnings = new List<string>();
            if (files == 0) warnings.Add("No local session history found.");
            if (incomplete) warnings.Add("History is incomplete: unreadable, corrupt, unsupported or ambiguous records were skipped.");
            if (limited) warnings.Add("History is incomplete: local scan safety limit reached.");
            if (days.Values.Any(day => day.UnpricedTokens > 0))
                warnings.Add("Some measured tokens are unpriced. Estimates use only exact user-supplied model rates; API-rate estimates are not subscription bills.");
            cancellationToken.ThrowIfCancellationRequested();
            return new UsageHistorySummary(days.Values.ToArray(), warnings.Count == 0 ? null : string.Join(" ", warnings));
        }

        private static Dictionary<string, Rates> LoadPrices(string? file)
        {
            if (string.IsNullOrEmpty(file)) return new(StringComparer.Ordinal);
            try
            {
                using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                byte[] buffer = new byte[262_145];
                int count = 0, read;
                while (count < buffer.Length && (read = stream.Read(buffer, count, buffer.Length - count)) > 0) count += read;
                if (count > 262_144) throw new InvalidDataException();
                var prices = JsonSerializer.Deserialize<Prices>(buffer.AsSpan(0, count));
                if (prices?.version != 1 || prices.models == null || prices.models.Count > 1000
                    || prices.models.Any(pair => !ValidID(pair.Key) || pair.Value == null || !pair.Value.Valid)) throw new InvalidDataException();
                return new Dictionary<string, Rates>(prices.models, StringComparer.Ordinal);
            }
            catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException)
            { throw new InvalidDataException("Cannot read pricing JSON. Use version 1 and finite, nonnegative per-million-token model rates."); }
        }

        private void ParseFile(string file, bool claude)
        {
            var context = new FileContext();
            try
            {
                using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                byte[] chunk = new byte[65_536];
                using var line = new MemoryStream();
                bool oversized = false;
                int count;
                while (!limited && (count = stream.Read(chunk, 0, chunk.Length)) > 0)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    readBytes += count;
                    if (readBytes > 2_147_483_648) { limited = true; break; }
                    for (int index = 0; index < count; index++)
                    {
                        if (index % 4096 == 0) cancellationToken.ThrowIfCancellationRequested();
                        byte current = chunk[index];
                        if (current == 10)
                        {
                            if (!oversized && line.Length != 0) ParseLine(line.GetBuffer().AsSpan(0, (int)line.Length), claude, context);
                            line.SetLength(0);
                            oversized = false;
                        }
                        else if (!oversized)
                        {
                            if (line.Length >= 4_194_304) { oversized = true; incomplete = true; line.SetLength(0); }
                            else line.WriteByte(current);
                        }
                    }
                }
                if (!oversized && line.Length != 0 && !limited) ParseLine(line.GetBuffer().AsSpan(0, (int)line.Length), claude, context);
                if (context.Replaying) incomplete = true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { incomplete = true; }
        }

        private void ParseLine(ReadOnlySpan<byte> line, bool claude, FileContext context)
        {
            try
            {
                var envelope = JsonSerializer.Deserialize<Envelope>(line);
                if (envelope == null) { incomplete = true; return; }
                if (claude)
                {
                    var message = envelope.message;
                    var usage = message?.usage;
                    if (usage == null) return;
                    var date = ParseDate(envelope.timestamp);
                    if (!date.HasValue || !ValidID(message!.id) || (message.model != null && !ValidID(message.model))
                        || (envelope.requestId != null && !ValidID(envelope.requestId))) throw new InvalidDataException();
                    var entry = new Event(date.Value, message.model, usage.Normalize(true), envelope.requestId ?? "",
                        envelope.isSidechain ?? false, usage.SpecialRate);
                    AddClaude(entry, message.id!);
                    int advisorIndex = 0;
                    if (usage.iterations != null)
                        foreach (var advisor in usage.iterations)
                        {
                            if (advisor == null) { incomplete = true; continue; }
                            if (advisor.type != "advisor_message") continue;
                            if (!ValidID(advisor.model)) { incomplete = true; continue; }
                            Tokens advisorTokens;
                            try { advisorTokens = advisor.Normalize(true); }
                            catch (InvalidDataException) { incomplete = true; continue; }
                            bool specialRate = entry.SpecialRate || advisor.SpecialRate;
                            AddClaude(new Event(entry.Date, advisor.model, advisorTokens,
                                entry.Request, entry.Sidechain, specialRate), message.id + ":advisor:" + advisorIndex++);
                        }
                    return;
                }
                var payload = envelope.payload;
                if (payload == null) return;
                if (envelope.type == "session_meta" && !context.SawMeta)
                {
                    context.SawMeta = true;
                    if (ValidID(payload.id)) context.SessionID = payload.id;
                    else incomplete = true;
                    context.Replaying = payload.Child;
                    context.Created = ParseDate(envelope.timestamp);
                    return;
                }
                if (envelope.type == "turn_context")
                {
                    if (ValidID(payload.Model)) context.Model = payload.Model;
                    return;
                }
                if (envelope.type != "event_msg") return;
                if (payload.type == "thread_settings_applied")
                {
                    var tier = payload.thread_settings?.service_tier ?? payload.service_tier;
                    if (tier != null) context.SpecialRate = tier != "default" && tier != "standard";
                    return;
                }
                if (payload.type == "task_started" && context.Replaying && payload.started_at.HasValue && double.IsFinite(payload.started_at.Value))
                {
                    var boundary = context.Created ?? ParseDate(envelope.timestamp);
                    if (boundary.HasValue && payload.started_at.Value >= boundary.Value.ToUnixTimeSeconds()) context.Replaying = false;
                    return;
                }
                var info = payload.info;
                if (payload.type != "token_count" || info == null) return;
                var totals = info.total_token_usage?.Normalize(false);
                if (context.Replaying) { if (totals.HasValue) context.Previous = totals; return; }
                if (totals.HasValue && totals == context.Previous) return;
                Tokens tokens;
                if (info.last_token_usage != null) tokens = info.last_token_usage.Normalize(false);
                else if (totals.HasValue)
                {
                    try { tokens = totals.Value.Delta(context.Previous); }
                    catch (InvalidDataException) { context.Previous = totals; throw; }
                }
                else throw new InvalidDataException();
                if (totals.HasValue) context.Previous = totals;
                var timestamp = ParseDate(envelope.timestamp);
                if (!timestamp.HasValue) throw new InvalidDataException();
                var model = payload.Model ?? info.model ?? info.model_name;
                if (ValidID(model)) context.Model = model;
                if (tokens.Total == 0) return;
                if (context.SessionID == null) incomplete = true;
                var key = new CodexKey(context.SessionID, timestamp.Value, context.Model, tokens, context.SpecialRate);
                if (codexEvents.ContainsKey(key)) return;
                if (eventCount >= MaxEvents) { limited = true; return; }
                codexEvents.Add(key, new Event(timestamp.Value, context.Model, tokens, "", false, context.SpecialRate));
                eventCount++;
            }
            catch (Exception error) when (error is JsonException or InvalidDataException or FormatException or OverflowException)
            { incomplete = true; }
        }

        private void AddClaude(Event entry, string id)
        {
            if (!claudeMessages.TryGetValue(id, out var matches)) { matches = new List<Event>(); claudeMessages[id] = matches; }
            int index = -1;
            for (int match = 0; match < matches.Count; match++)
                if (matches[match].Request == entry.Request || matches[match].Sidechain || entry.Sidechain) { index = match; break; }
            if (index >= 0)
            {
                var old = matches[index];
                bool larger = entry.Tokens.Total > old.Tokens.Total;
                bool richer = entry.Tokens.Total == old.Tokens.Total && entry.SpecialRate && !old.SpecialRate;
                if ((old.Sidechain && !entry.Sidechain) || (old.Sidechain == entry.Sidechain && (larger || richer))) matches[index] = entry;
            }
            else if (eventCount < MaxEvents && matches.Count < 256) { matches.Add(entry); eventCount++; }
            else limited = true;
        }

        private static void Aggregate(Event entry, Dictionary<string, Rates> prices, SortedDictionary<string, UsageHistoryDay> days)
        {
            string date = entry.Date.ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            if (!days.TryGetValue(date, out var day)) { day = new UsageHistoryDay(date); days.Add(date, day); }
            var tokens = entry.Tokens;
            day.InputTokens += tokens.Input + tokens.Writes + tokens.OneHour;
            day.OutputTokens += tokens.Output;
            day.CachedTokens += tokens.Cached;
            if (!entry.SpecialRate && entry.Model != null && prices.TryGetValue(entry.Model, out var rate)
                && (tokens.OneHour == 0 || rate.cacheWriteOneHourPerMillion.HasValue))
            {
                double cost = (tokens.Input * rate.inputPerMillion + tokens.Output * rate.outputPerMillion
                    + tokens.Cached * rate.cachedInputPerMillion + tokens.Writes * rate.cacheWritePerMillion
                    + tokens.OneHour * (rate.cacheWriteOneHourPerMillion ?? 0)) / 1_000_000;
                day.EstimatedCost = (day.EstimatedCost ?? 0) + cost;
            }
            else day.UnpricedTokens += tokens.Total;
        }
    }

    private static bool CountValid(long count) => count >= 0 && count <= 1_000_000_000_000;
    private static bool ValidID(string? text) => !string.IsNullOrWhiteSpace(text) && System.Text.Encoding.UTF8.GetByteCount(text) <= 256 && !text.Any(char.IsControl);
    private static readonly string[] TimestampFormats = { "yyyy-MM-dd'T'HH:mm:ssK", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK" };
    private static DateTimeOffset? ParseDate(string? text)
    {
        if (text == null || text.Length > 64) return null;
        return DateTimeOffset.TryParseExact(text, TimestampFormats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) ? date : null;
    }
}
