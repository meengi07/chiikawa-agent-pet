using ChiikawaPet;

internal static class UsageSettingsChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Check(bool condition, string reason) { if (!condition) throw new Exception(reason); checks++; }
        var defaults = new Settings();
        Check(!defaults.QuotaAlerts && !defaults.PaceAlerts && !defaults.LocalHistoryEnabled && !defaults.CredentialManagerEnabled
            && !defaults.DiscoverSavedAccounts && !defaults.Startup && defaults.HotkeyKey == 0, "Invasive feature defaults stay off");
        Check(defaults.MoodProvider == "all" && defaults.MoodMetric == "" && !defaults.PaceMood
            && defaults.TrayStyle == "character" && defaults.MoodThresholds.SequenceEqual(new double[] { 10, 30, 60, 95 }),
            "Default expression and tray remain compatible");
        string root = Path.Combine(Path.GetTempPath(), "chiikawa-settings-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        string path = Path.Combine(root, "settings.json");
        try
        {
            File.WriteAllText(path, """{"Language":"ko","Character":"momonga","Scale":0.8,"Visible":false,"Wanders":false,"X":-300,"Y":20}""");
            var legacy = Settings.Load(path);
            Check(legacy.Language == "ko" && legacy.Character == "momonga" && legacy.Scale == 0.8 && !legacy.Visible
                && !legacy.Wanders && legacy.X == -300 && !legacy.QuotaAlerts && legacy.AdditionalHomes.Count == 0,
                "Legacy Windows settings retain character, position, language, and invasive defaults");
            legacy.MoodProvider = "Codex"; legacy.MoodMetric = "model:fixture:weekly"; legacy.MoodThresholds = [5, 15, 45, 90];
            legacy.TrayPins = ["Codex:weekly", "Claude:session"]; legacy.TrayStyle = "bars"; legacy.CompactTray = true;
            legacy.ResetCountdown = true; legacy.ShowPace = true; legacy.QuotaAlerts = true; legacy.AlertThresholds = [8, 20];
            legacy.HiddenMetrics = ["Claude:weekly"]; legacy.PaceAlerts = true; legacy.LocalHistoryEnabled = true;
            legacy.PricingFile = Path.Combine(root, "explicit-prices.json"); legacy.HotkeyModifiers = 8; legacy.HotkeyKey = 0x4B;
            legacy.AdditionalHomes.Add(new UsageHome { Id = "stable-home", Provider = "Codex", Label = "User label", Directory = root });
            legacy.Save(path);
            var restored = Settings.Load(path);
            Check(restored.MoodProvider == "Codex" && restored.MoodMetric == "model:fixture:weekly"
                && restored.MoodThresholds.SequenceEqual(legacy.MoodThresholds) && restored.TrayPins.SequenceEqual(legacy.TrayPins)
                && restored.HiddenMetrics.SequenceEqual(legacy.HiddenMetrics) && restored.TrayStyle == "bars" && restored.CompactTray
                && restored.ResetCountdown && restored.ShowPace && restored.QuotaAlerts && restored.PaceAlerts
                && restored.LocalHistoryEnabled && restored.PricingFile == legacy.PricingFile && restored.HotkeyModifiers == 8
                && restored.HotkeyKey == 0x4B && restored.AdditionalHomes.Single().Id == "stable-home",
                "All usage preferences, stable homes, Win chord and explicit pricing round-trip");
            restored.MoodThresholds = [90, 10, 40, 20]; restored.AlertThresholds = [20, 20, -1, double.NaN, 5];
            restored.TrayPins = ["", "Codex:weekly", "Codex:weekly"]; restored.MoodProvider = "unknown"; restored.TrayStyle = "unknown";
            restored.Validate();
            Check(restored.MoodThresholds.SequenceEqual(new double[] { 10, 20, 40, 90 })
                && restored.AlertThresholds.SequenceEqual(new double[] { 5, 20 }) && restored.TrayPins.SequenceEqual(new[] { "Codex:weekly" })
                && restored.MoodProvider == "all" && restored.TrayStyle == "character", "Invalid and duplicate preferences normalize deterministically");
            restored.MoodThresholds = [double.PositiveInfinity, 20, 30, 40]; restored.HotkeyModifiers = 0; restored.HotkeyKey = 0x41;
            restored.Validate();
            Check(restored.MoodThresholds.SequenceEqual(new double[] { 10, 30, 60, 95 }) && restored.HotkeyKey == 0,
                "Nonfinite thresholds and unmodified global keys cannot persist as active policy");
            restored.AdditionalHomes =
            [
                new UsageHome { Id = "first", Provider = "Claude", Directory = root, Label = null! },
                new UsageHome { Id = "duplicate", Provider = "Claude", Directory = root + Path.DirectorySeparatorChar },
                new UsageHome { Id = "relative", Provider = "Codex", Directory = "relative-home" },
                new UsageHome { Id = "wrong-provider", Provider = "Unknown", Directory = root }
            ];
            restored.Validate();
            Check(restored.AdditionalHomes.Count == 1 && restored.AdditionalHomes[0].Id == "first"
                && restored.AdditionalHomes[0].Label == "", "Homes normalize null labels, reject relative paths and deduplicate identical provider homes");
            string lowerWsl = @"\\wsl.localhost\Ubuntu\home\user\.codex";
            string upperWsl = @"\\wsl.localhost\Ubuntu\home\User\.codex";
            Check(Usage.NormalizeSourcePath(lowerWsl) != Usage.NormalizeSourcePath(upperWsl),
                "Source normalization preserves distinct case-sensitive WSL Linux paths");
            Check(Usage.NormalizeSourcePath(Path.Combine(root, "Home")) == Usage.NormalizeSourcePath(Path.Combine(root, "home")),
                "Ordinary Windows home identities remain case-insensitive");
            if (OperatingSystem.IsWindows())
            {
                restored.AdditionalHomes =
                [
                    new UsageHome { Id = "lower", Provider = "Codex", Directory = lowerWsl },
                    new UsageHome { Id = "upper", Provider = "Codex", Directory = upperWsl }
                ];
                restored.Save(path);
                var wslRestored = Settings.Load(path);
                Check(wslRestored.AdditionalHomes.Count == 2
                    && wslRestored.AdditionalHomes.Select(home => home.Directory).Contains(upperWsl),
                    "Case-sensitive WSL homes survive persisted settings validation without being merged");
            }
        }
        finally { Directory.Delete(root, true); }
        return checks;
    }
}
