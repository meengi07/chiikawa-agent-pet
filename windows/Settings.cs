using System;
using System.Collections.Generic;
using System.Linq;
using System.IO;
using System.Text.Json;

namespace ChiikawaPet;

internal sealed class Settings
{
    public string Language { get; set; } = "en";
    public string Character { get; set; } = "chiikawa";
    public double Scale { get; set; } = 0.65;
    public bool Visible { get; set; } = true;
    public bool Wanders { get; set; } = true;
    public bool AutomaticUpdates { get; set; }
    public double? X { get; set; }
    public double? Y { get; set; }
    public string MoodProvider { get; set; } = "all";
    public string MoodMetric { get; set; } = "";
    public double[] MoodThresholds { get; set; } = [10, 30, 60, 95];
    public bool PaceMood { get; set; }
    public string[] HiddenMetrics { get; set; } = [];
    public string[] TrayPins { get; set; } = ["Claude:session", "Codex:session"];
    public string TrayStyle { get; set; } = "character";
    public bool CompactTray { get; set; }
    public bool ResetCountdown { get; set; }
    public bool ShowPace { get; set; }
    public bool QuotaAlerts { get; set; }
    public bool PaceAlerts { get; set; }
    public double[] AlertThresholds { get; set; } = [10, 30];
    public bool Startup { get; set; }
    public uint HotkeyModifiers { get; set; }
    public uint HotkeyKey { get; set; }
    public bool DiscoverSavedAccounts { get; set; }
    public bool CredentialManagerEnabled { get; set; }
    public List<UsageHome> AdditionalHomes { get; set; } = [];
    public bool LocalHistoryEnabled { get; set; }
    public string? PricingFile { get; set; }

    public void Validate()
    {
        if (Language is not ("en" or "ko")) Language = "en";
        if (Character is not ("chiikawa" or "hachiware" or "usagi" or "momonga")) Character = "chiikawa";
        if (!double.IsFinite(Scale) || Scale < 0.4 || Scale > 1.2) Scale = 0.65;
        if (X is double x && !double.IsFinite(x)) X = null;
        if (Y is double y && !double.IsFinite(y)) Y = null;
        if (MoodProvider is not ("all" or "Claude" or "Codex")) MoodProvider = "all";
        MoodMetric ??= "";
        if (MoodThresholds == null || MoodThresholds.Length != 4 || MoodThresholds.Any(number => !double.IsFinite(number) || number < 0 || number > 100))
            MoodThresholds = [10, 30, 60, 95];
        Array.Sort(MoodThresholds);
        AlertThresholds = (AlertThresholds ?? [10, 30]).Where(number => double.IsFinite(number) && number >= 0 && number <= 100).Distinct().Order().ToArray();
        HiddenMetrics ??= [];
        TrayPins ??= ["Claude:session", "Codex:session"];
        TrayPins = TrayPins.Where(pin => !string.IsNullOrWhiteSpace(pin)).Distinct().Take(12).ToArray();
        if (TrayStyle is not ("character" or "text" or "bars")) TrayStyle = "character";
        AdditionalHomes ??= [];
        AdditionalHomes = AdditionalHomes.Where(home => home != null && home.Normalize()).DistinctBy(home => home.Id)
            .DistinctBy(home => home.Provider + "\0" + Usage.NormalizeSourcePath(home.Directory), StringComparer.Ordinal).ToList();
        HotkeyModifiers &= 15;
        if (HotkeyKey > 254 || (HotkeyKey != 0 && HotkeyModifiers == 0)) HotkeyKey = 0;
    }

    public static Settings Load(string path)
    {
        if (!File.Exists(path)) return new Settings();
        var settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(path)) ?? new Settings();
        settings.Validate();
        return settings;
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(this));
        File.Move(path + ".tmp", path, overwrite: true);
    }
}

internal sealed class UsageHome
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Provider { get; set; } = "Codex";
    public string Label { get; set; } = "";
    public string Directory { get; set; } = "";

    public bool Normalize()
    {
        if (Provider is not ("Claude" or "Codex") || string.IsNullOrWhiteSpace(Id) || string.IsNullOrWhiteSpace(Directory)) return false;
        try
        {
            if (!Path.IsPathFullyQualified(Directory)) return false;
            Directory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Directory));
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { return false; }
        Label ??= "";
        return true;
    }
}
