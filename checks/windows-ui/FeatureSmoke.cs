using System;
using System.Collections.Generic;
using System.Linq;
using System.IO;
using System.Reflection;
using System.Windows.Threading;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Threading.Tasks;
using System.Threading;
using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using ChiikawaPet;
using Forms = System.Windows.Forms;

internal static partial class Program
{
    private static async Task CheckFeaturePreferences(Window window)
    {
        var settings = (Settings)Field("settings").GetValue(window)!;
        Require(!settings.QuotaAlerts && !settings.LocalHistoryEnabled && !settings.Startup && settings.HotkeyKey == 0
            && !settings.CredentialManagerEnabled && !settings.DiscoverSavedAccounts, "Invasive Windows features were enabled by default.");
        Call(window, "OpenPanel");
        var usage = (Window)Field("panel").GetValue(window)!;
        var sprites = (Dictionary<string, BitmapSource[]>)Field("sprites").GetValue(window)!;
        var providers = (ProviderState[])Field("providers").GetValue(window)!;
        var now = DateTimeOffset.UtcNow;
        var cached = new Reading([new Quota("Fixture session", 20, now.AddHours(1), "session", 18000)], now.AddMinutes(-1))
        {
            Source = "diskCache", AccountLabel = "sensitive-display-fixture", AccountID = "sensitive-account-fixture",
            AuthSource = "synthetic source", CredentialFingerprint = "fixture-fingerprint", Plan = "fixture-plan"
        };
        providers[0].Succeed(cached);
        Call(window, "UpdateCards");
        var cards = LogicalChildren(usage).OfType<TextBlock>().Select(block => block.Text).ToArray();
        Require(cards.Any(text => text.StartsWith("Saved snapshot · not live", StringComparison.Ordinal))
            && cards.Any(text => text.Contains("fixture-plan", StringComparison.Ordinal))
            && cards.Any(text => text.StartsWith("Measured:", StringComparison.Ordinal)), "Cached source, measured age, plan and identity are not visible.");
        providers[0].Fail(new UsageCooldownException(now.AddMinutes(2)));
        Call(window, "UpdateCards");
        Require(LogicalChildren(usage).OfType<TextBlock>().Any(block => block.Text.StartsWith("Next attempt:", StringComparison.Ordinal)),
            "Provider cooldown next-attempt time is missing from the real card.");
        providers[0].Succeed(cached);
        Call(window, "UpdateCards");
        foreach (string character in new[] { "chiikawa", "hachiware", "usagi", "momonga" })
        {
            string name = character switch { "chiikawa" => "Chiikawa", "hachiware" => "Hachiware", "usagi" => "Usagi", _ => "Momonga" };
            var choice = LogicalChildren(usage).OfType<Button>().Single(button => AutomationProperties.GetName(button) == "Select " + name);
            var image = LogicalChildren(choice).OfType<Image>().Single();
            Require(ReferenceEquals(image.Source, sprites[character][0]), "Character picker reflected the crying pet instead of a cheerful sample.");
            choice.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Require(ReferenceEquals(providers[0].Reading, cached), "Selecting a character changed the measured usage.");
        }
        var pet = (Image)Field("pet").GetValue(window)!;
        Require(sprites[settings.Character].Skip(32).Take(8).Any(sprite => ReferenceEquals(sprite, pet.Source)),
            "Actual zero-percent preview pet stopped reacting while cheerful choices were rendered.");

        var preferences = LogicalChildren(usage).OfType<Expander>().Single(expander => (string)expander.Header == "Usage & system preferences");
        preferences.IsExpanded = true;
        var thresholdBox = Named<TextBox>(usage, "Expression thresholds");
        thresholdBox.Text = "4, 14, 44, 94";
        Click(usage, "Apply thresholds");
        Require(settings.MoodThresholds.SequenceEqual(new double[] { 4, 14, 44, 94 }), "Threshold controls did not update policy.");
        thresholdBox.Text = "NaN, 14, 44, 94";
        Click(usage, "Apply thresholds");
        Require(settings.MoodThresholds.SequenceEqual(new double[] { 4, 14, 44, 94 }), "Invalid threshold UI changed the last valid policy.");
        Named<ComboBox>(usage, "Expression provider (hiding a metric does not exclude it)").SelectedItem = "Claude";
        Require(settings.MoodProvider == "Claude", "Provider expression selector is unreachable.");
        Toggle(usage, "Show reset countdown instead of exact time", true);
        Toggle(usage, "Show conditional usage pace", true);
        Require(settings.ResetCountdown && settings.ShowPace, "Countdown/pace controls did not update preferences.");
        Toggle(usage, "Quota notifications (Windows notification settings apply)", true);
        Require(settings.QuotaAlerts, "Notification opt-in did not enable alerts.");
        Toggle(usage, "Quota notifications (Windows notification settings apply)", false);
        Toggle(usage, "Read local usage history (off by default)", true);
        Require(settings.LocalHistoryEnabled && !(bool)Field("historyScanning").GetValue(window)!, "Preview history control bypassed the no-I/O boundary.");
        using var historyCancellation = new CancellationTokenSource();
        Field("historyCancellation").SetValue(window, historyCancellation);
        Field("historyScanning").SetValue(window, true);
        Toggle(usage, "Read local usage history (off by default)", false);
        Require(historyCancellation.IsCancellationRequested && Field("historyCancellation").GetValue(window) == null
            && !(bool)Field("historyScanning").GetValue(window)!, "Disabling local history did not cancel its in-flight read.");
        var trayStyle = Named<ComboBox>(usage, "Tray icon style");
        trayStyle.SelectedItem = "text";
        Require(settings.TrayStyle == "text" && ((Forms.NotifyIcon)Field("tray").GetValue(window)!).Icon != null, "Tray text option did not produce a native icon.");
        trayStyle.SelectedItem = "bars";
        Require(settings.TrayStyle == "bars", "Tray bar option is not reachable.");
        trayStyle.SelectedItem = "character";
        var pins = Named<ListBox>(usage, "Ordered tray pins");
        pins.SelectedIndex = 0;
        Click(usage, "Move pin down");
        Require(settings.TrayPins.SequenceEqual(new[] { "Codex:session", "Claude:session" }), "Tray pin ordering did not persist to presentation settings.");
        Named<ComboBox>(usage, "Available tray metrics").SelectedItem = "Claude:weekly";
        Click(usage, "Pin selected metric");
        Require(settings.TrayPins.Last() == "Claude:weekly", "A real metric could not be pinned.");
        pins.SelectedItem = "Claude:weekly";
        Click(usage, "Remove selected pin");
        Require(!settings.TrayPins.Contains("Claude:weekly"), "Removed tray pin remained active.");

        var record = LogicalChildren(usage).OfType<Button>().Single(button => button.Content is string title && title.StartsWith("Record global shortcut", StringComparison.Ordinal));
        record.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var source = PresentationSource.FromVisual(window)!;
        record.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, Environment.TickCount, Key.A) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
        Require(settings.HotkeyKey == 0, "Recording accepted an unmodified global key.");
        record.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, Environment.TickCount, Key.Escape) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
        Require(settings.HotkeyKey == 0 && record.Content is string caption && caption.Contains("disabled", StringComparison.Ordinal), "Esc did not cancel shortcut recording.");
        using (var native = new WindowsFeatures(new WindowInteropHelper(window).Handle, () => { }))
            Require(native.ConfigureHotkey(2, 0x7B) != null && !native.HotkeyRegistered, "Reserved F12 shortcut did not return a native configuration error.");
        bool shortcutReceived = false;
        using (var native = new WindowsFeatures(new WindowInteropHelper(window).Handle, () => shortcutReceived = true))
        {
            Require(native.ConfigureHotkey(7, 0x87) == null && native.HotkeyRegistered, "A temporary Ctrl+Alt+Shift+F24 shortcut could not be registered.");
            try
            {
                keybd_event(0x11, 0, 0, UIntPtr.Zero);
                keybd_event(0x12, 0, 0, UIntPtr.Zero);
                keybd_event(0x10, 0, 0, UIntPtr.Zero);
                keybd_event(0x87, 0, 0, UIntPtr.Zero);
                keybd_event(0x87, 0, 2, UIntPtr.Zero);
                await Task.Delay(150);
            }
            finally
            {
                keybd_event(0x87, 0, 2, UIntPtr.Zero);
                keybd_event(0x10, 0, 2, UIntPtr.Zero);
                keybd_event(0x12, 0, 2, UIntPtr.Zero);
                keybd_event(0x11, 0, 2, UIntPtr.Zero);
            }
            Require(shortcutReceived, "The registered native shortcut did not dispatch its panel-open callback.");
        }
        var startup = LogicalChildren(usage).OfType<CheckBox>().Single(toggle => (string)toggle.Content == "Start at Windows sign-in");
        Require(!startup.IsEnabled && !settings.Startup, "Preview allowed startup registry mutation.");
        string executable = Environment.ProcessPath!;
        Require(WindowsFeatures.ClassifyStartupRegistration(null, executable) == StartupRegistration.Missing
            && WindowsFeatures.ClassifyStartupRegistration("\"" + executable + "\"", executable) == StartupRegistration.CurrentExecutable
            && WindowsFeatures.ClassifyStartupRegistration("\"C:\\PortableFixture\\ChiikawaPet.exe\"", executable) == StartupRegistration.OtherExecutable
            && WindowsFeatures.ClassifyStartupRegistration("\"" + executable + "\" --another-app", executable) == StartupRegistration.OtherExecutable,
            "Startup reconciliation cannot distinguish missing, current, and different portable registrations without rewriting them.");

        Named<TextBox>(usage, "Home directory").Text = "relative-home";
        Click(usage, "Add explicit home");
        Require(settings.AdditionalHomes.Count == 0, "Relative credential home was silently accepted.");
        Named<TextBox>(usage, "Home display label").Text = "Synthetic WSL fixture";
        Named<TextBox>(usage, "Home directory").Text = @"\\wsl.localhost\SyntheticFixture\home\fixture\.codex";
        Click(usage, "Add explicit home");
        Require(settings.AdditionalHomes.Count == 1 && settings.AdditionalHomes[0].Directory.StartsWith(@"\\wsl.localhost\", StringComparison.Ordinal), "Explicit WSL UNC home UI is unreachable.");
        Named<TextBox>(usage, "Home directory").Text = @"\\wsl.localhost\SyntheticFixture\home\Fixture\.codex";
        Click(usage, "Add explicit home");
        Require(settings.AdditionalHomes.Count == 2, "Distinct case-sensitive WSL homes were collapsed by the add-home UI.");
        LogicalChildren(usage).OfType<Button>().First(button => button.Content is string label && label == "Remove home")
            .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Require(settings.AdditionalHomes.Count == 1, "Removing one WSL home removed its case-sensitive sibling.");
        Click(usage, "Remove home");
        Require(settings.AdditionalHomes.Count == 0, "Explicit home remove UI left an obsolete account.");
        var diagnosticProvider = new ProviderState(new UsageAccount("fixture", "Claude", "sensitive-display-fixture",
            @"\\wsl.localhost\SyntheticFixture\home\fixture\.claude"));
        diagnosticProvider.Succeed(cached);
        Field("providers").SetValue(window, new[] { diagnosticProvider });
        Call(window, "UpdateCards");
        Click(usage, "Copy sanitized diagnostics");
        string diagnostics = Clipboard.GetText();
        Require(!diagnostics.Contains("sensitive-display-fixture", StringComparison.Ordinal)
            && !diagnostics.Contains("sensitive-account-fixture", StringComparison.Ordinal)
            && !diagnostics.Contains("SyntheticFixture", StringComparison.Ordinal), "Sanitized diagnostics exposed account identity or a selected path.");
        await CheckInvalidPricingBoundary(window, settings);
        Call(window, "ClosePanel");
        Console.WriteLine("PASS native roadmap controls: cheerful picker, cache identity/age, expression thresholds, tray, alert opt-in, shortcut validation, WSL homes, sanitized diagnostics.");
    }

    private static async Task CheckInvalidPricingBoundary(Window window, Settings settings)
    {
        string root = Path.Combine(Path.GetTempPath(), "chiikawa-ui-history-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        string pricing = Path.Combine(root, "invalid-pricing.json");
        await File.WriteAllTextAsync(pricing, "{invalid-json");
        var refresh = (DispatcherTimer)Field("refreshTimer").GetValue(window)!;
        bool wasRunning = refresh.IsEnabled;
        object? oldPreview = Field("preview").GetValue(window);
        object? oldProviders = Field("providers").GetValue(window);
        bool oldRefreshing = (bool)Field("refreshing").GetValue(window)!;
        bool oldHistory = settings.LocalHistoryEnabled;
        string? oldPricing = settings.PricingFile;
        refresh.Stop();
        Field("refreshing").SetValue(window, true);
        Field("preview").SetValue(window, null);
        Field("providers").SetValue(window, new[] { new ProviderState(new UsageAccount("offline-history", "Claude", "Offline history", root)) });
        settings.LocalHistoryEnabled = true;
        settings.PricingFile = pricing;
        try
        {
            var scan = (Task)PetType.GetMethod("RefreshHistory", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, null)!;
            await scan;
            var errors = (Dictionary<string, string>)Field("historyErrors").GetValue(window)!;
            Require(window.IsVisible && !(bool)Field("closing").GetValue(window)! && errors.Count == 1
                && errors.Values.Single().StartsWith("Cannot read history or pricing.", StringComparison.Ordinal),
                "Invalid pricing escaped the real scan UI boundary instead of showing a sanitized warning.");
        }
        finally
        {
            Call(window, "CancelHistory");
            settings.LocalHistoryEnabled = oldHistory;
            settings.PricingFile = oldPricing;
            Field("providers").SetValue(window, oldProviders);
            Field("preview").SetValue(window, oldPreview);
            Field("refreshing").SetValue(window, oldRefreshing);
            if (wasRunning) refresh.Start();
            Directory.Delete(root, true);
        }
    }

    private static IEnumerable<DependencyObject> LogicalChildren(DependencyObject parent)
    {
        foreach (object child in LogicalTreeHelper.GetChildren(parent))
            if (child is DependencyObject dependency)
            {
                yield return dependency;
                foreach (var descendant in LogicalChildren(dependency)) yield return descendant;
            }
    }

    private static T Named<T>(Window usage, string name) where T : FrameworkElement =>
        LogicalChildren(usage).OfType<T>().Single(element => AutomationProperties.GetName(element) == name);
    private static void Click(Window usage, string label) => LogicalChildren(usage).OfType<Button>()
        .Single(button => button.Content is string title && title == label).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void Toggle(Window usage, string label, bool enabled)
    {
        var toggle = LogicalChildren(usage).OfType<CheckBox>().Single(toggle => toggle.Content is string title && title == label);
        toggle.IsChecked = enabled;
        toggle.RaiseEvent(new RoutedEventArgs(CheckBox.ClickEvent));
    }

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);
}
