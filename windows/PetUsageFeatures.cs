using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Automation;
using static ChiikawaPet.Language;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ChiikawaPet;

internal sealed partial class PetApp
{
    private WindowsFeatures? systemFeatures;
    private UsageAlertPolicy alertPolicy = new();
    private readonly List<string> quotaMessages = [];
    private readonly Dictionary<string, UsageHistorySummary> historyByHome = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> historyErrors = new(StringComparer.Ordinal);
    private bool reloadPending, featureDialogOpen, historyScanning;
    private CancellationTokenSource? historyCancellation;
    private string? systemFeatureError;
    private StartupRegistration startupRegistration = StartupRegistration.Unavailable;
    private string? startupRegistrationError;
    private TextBlock? startupStatusText;
    private CheckBox? startupToggle;
    private TextBlock? moodReasonText;
    private TextBlock? discoveryWarningText;
    private TextBlock? pricingStatusText;
    private Button? historyScanButton;
    private static string L(string english, string korean) => Current == "ko" ? korean : english;
    private static string MetricKey(string provider, string metric) => provider + ":" + metric;

    private IEnumerable<Quota> MoodQuotas(ProviderState provider)
    {
        if (provider.Error != null || provider.Reading is not { } reading || !reading.IsCurrent(DateTimeOffset.UtcNow)
            || (settings.MoodProvider != "all" && provider.Name != settings.MoodProvider)) return [];
        return reading.Windows.Where(quota => settings.MoodMetric.Length == 0 || quota.Id == settings.MoodMetric);
    }

    private double? MoodRemaining() => MoodRemaining(out _, out _);

    private double? MoodRemaining(out ProviderState? driverProvider, out Quota? driverQuota)
    {
        driverProvider = null;
        driverQuota = null;
        double? minimum = null;
        foreach (var provider in providers)
            foreach (var quota in MoodQuotas(provider))
            {
                double remaining = quota.Remaining;
                if (settings.PaceMood && provider.Reading is { } reading)
                {
                    var projection = UsagePace.Projection(quota, reading.FetchedAt, DateTimeOffset.UtcNow);
                    if (projection == null) continue;
                    remaining = projection.RemainingAtReset;
                }
                if (minimum == null || remaining < minimum.Value)
                {
                    minimum = remaining;
                    driverProvider = provider;
                    driverQuota = quota;
                }
            }
        return minimum;
    }

    private int MoodRow() => Usage.MoodRow(Remaining, settings.MoodThresholds);

    private string MoodReason()
    {
        if (preview != null) return L("Expression preview · not measured usage", "표정 미리보기 · 실제 측정 아님");
        _ = MoodRemaining(out var driverProvider, out var driverQuota);
        if (driverProvider == null || driverQuota == null) return L("No current selected metric; expression is unknown.", "선택한 최신 한도가 없어 표정을 알 수 없습니다.");
        return L("Expression driver: ", "표정 기준: ") + driverProvider.Name + " · " + driverProvider.Account.Label
            + " · " + T(driverQuota.Title) + (settings.PaceMood ? L(" (projected remaining)", " (예상 잔여량)") : "");
    }

    private string MoodCaption() => MoodRow() switch
    {
        0 => T("와아! 아직 한가득!"), 1 => T("오늘도 같이 힘내자"),
        2 => T("조금씩 아껴 쓰자…"), 3 => T("이제 얼마 안 남았어…"),
        4 => T("울먹… 잠깐 쉬었다 가자"), _ => T("연결하면 기분을 알려줄게")
    };

    private void ReloadAccounts()
    {
        if (refreshing)
        {
            reloadPending = true;
            foreach (var provider in providers) provider.Clear();
            quotaMessages.Clear();
            return;
        }
        if (preview != null) { providers = Usage.DefaultAccounts().Select(account => new ProviderState(account)).ToArray(); return; }
        var additional = settings.AdditionalHomes.Select(home => new UsageAccount(home.Id, home.Provider,
            home.Label.Length == 0 ? home.Provider + " custom home" : home.Label, home.Directory)
            { UseCredentialManager = settings.CredentialManagerEnabled });
        providers = Usage.Discover(settings.DiscoverSavedAccounts, additional, settings.CredentialManagerEnabled)
            .Select(account => new ProviderState(account)).ToArray();
        alertPolicy = new UsageAlertPolicy();
    }

    private void ApplyAccountSettings()
    {
        SaveSettings();
        CancelHistory();
        historyByHome.Clear();
        historyErrors.Clear();
        ReloadAccounts();
        UpdatePresentation();
        UpdateCards();
        if (!reloadPending && settings.LocalHistoryEnabled) _ = RefreshHistory();
        _ = Refresh();
    }

    private void OpenPanel()
    {
        if (closing) return;
        if (panel == null) TogglePanel();
        else { panel.Show(); panel.Activate(); }
    }

    private void ConfigureSystemFeatures()
    {
        if (preview != null) return;
        var handle = new WindowInteropHelper(this).Handle;
        systemFeatures = new WindowsFeatures(handle, () => Dispatcher.Invoke(OpenPanel));
        systemFeatureError = systemFeatures.ConfigureHotkey(settings.HotkeyModifiers, settings.HotkeyKey);
        if (systemFeatureError != null) ShowSystemFailure();
        RefreshStartupRegistration();
    }

    private void RefreshStartupRegistration()
    {
        if (preview != null || systemFeatures == null) return;
        startupRegistration = systemFeatures.ReadStartupRegistration(out startupRegistrationError);
        if (startupStatusText != null) startupStatusText.Text = StartupDescription();
        if (startupToggle != null) startupToggle.IsChecked = startupRegistration == StartupRegistration.CurrentExecutable;
    }

    private string StartupDescription()
    {
        if (preview != null) return L("Preview · startup registration is not read or changed.", "미리보기 · 시작 등록을 읽거나 변경하지 않습니다.");
        return startupRegistration switch
        {
            StartupRegistration.CurrentExecutable => L("Registered for this executable. Windows Startup Apps may still disable launch; check Windows Settings > Apps > Startup.", "현재 실행 파일이 등록되었습니다. Windows 시작 앱 설정에서 실행을 제한할 수 있으므로 설정 > 앱 > 시작 프로그램을 확인하세요."),
            StartupRegistration.Missing => L("Not registered. Enable again to register this executable.", "등록되지 않았습니다. 현재 실행 파일을 등록하려면 다시 켜세요."),
            StartupRegistration.OtherExecutable => L("A different executable (possibly a portable copy) is registered and was left unchanged. Enable explicitly to replace it.", "다른 실행 파일 (포터블 사본 등)이 등록되어 있으며 변경하지 않았습니다. 교체하려면 직접 켜세요."),
            _ => startupRegistrationError ?? L("Startup registration could not be verified.", "시작 등록을 확인할 수 없습니다.")
        };
    }

    private void NotifyQuotaChanges(ProviderState provider)
    {
        if (!settings.QuotaAlerts || provider.Error != null || provider.Reading is not { } reading
            || provider.RetryAt > DateTimeOffset.UtcNow) return;
        string identity = UsageAlertPolicy.AccountKey(provider.Account.Id, reading);
        var events = alertPolicy.Evaluate(identity, reading, DateTimeOffset.UtcNow, settings.AlertThresholds, settings.PaceAlerts);
        foreach (var notification in events)
        {
            string title = T(notification.MetricTitle);
            string message = notification.Threshold is double threshold
                ? L($"{title}: remaining usage has reached {threshold:G}% or less.", $"{title}: 잔여량이 {threshold:G}% 이하가 되었습니다.")
                : notification.PaceSeverity == 2
                    ? L($"{title}: at this pace, usage will run out at or before reset.", $"{title}: 이 속도면 초기화 전 또는 초기화 때 소진됩니다.")
                    : L($"{title}: at this pace, little usage will remain at reset.", $"{title}: 이 속도면 초기화 때 잔여량이 적습니다.");
            quotaMessages.Add(provider.Name + " · " + message);
        }
    }

    private void ShowQuotaNotifications()
    {
        if (!settings.QuotaAlerts || quotaMessages.Count == 0 || closing) return;
        string message = string.Join(Environment.NewLine, quotaMessages);
        tray.ShowBalloonTip(8000, L("Quota alert", "잔여량 알림"), message[..Math.Min(message.Length, 240)], Forms.ToolTipIcon.Warning);
        quotaMessages.Clear();
    }

    private string CurrentStatus(ProviderState provider)
    {
        if (provider.Reading is not { } reading) return provider.Error == null ? L("Not measured", "측정 전") : L("Unavailable", "조회 불가");
        string status = provider.Error != null ? L("Previous data", "이전 데이터") : reading.Source == "diskCache"
            ? L("Saved snapshot · not live", "저장된 측정값 · 실시간 아님") : !reading.IsCurrent(DateTimeOffset.UtcNow)
            ? L("Outdated", "오래된 측정값") : reading.Source == "swapCache" ? L("Swap cache", "Swap 캐시") : L("Live API", "실시간 API");
        var age = DateTimeOffset.UtcNow - reading.FetchedAt;
        string ageText = age < TimeSpan.Zero ? L("invalid future measurement", "잘못된 미래 측정")
            : age.TotalMinutes < 1 ? L("just measured", "방금 측정") : $"{(long)age.TotalMinutes}{L(" min old", "분 전 측정")}";
        return status + " · " + ageText;
    }

    private string ResetDescription(DateTimeOffset reset)
    {
        var remaining = reset - DateTimeOffset.UtcNow;
        if (settings.ResetCountdown)
        {
            if (remaining <= TimeSpan.Zero) return L("Reset passed · awaiting measurement", "초기화 시각 지남 · 새 측정 대기");
            return L($"Resets in {(int)remaining.TotalHours}h {remaining.Minutes}m", $"{(int)remaining.TotalHours}시간 {remaining.Minutes}분 후 초기화");
        }
        return L("Resets ", "초기화 ") + reset.ToLocalTime().ToString("g", CultureInfo.GetCultureInfo(settings.Language == "ko" ? "ko-KR" : "en-US"));
    }

    private static string ProjectionDescription(UsageProjection projection) => projection.Severity == 2
        ? L("At this pace: exhausted before reset", "이 속도면 초기화 전 소진 예상")
        : L($"At this pace: {projection.RemainingAtReset:F0}% at reset (estimate)", $"이 속도면 초기화 때 {projection.RemainingAtReset:F0}% 남음 (예상)");

    private void AddReadingDetails(StackPanel content, ProviderState provider, Reading reading)
    {
        content.Children.Add(Text($"{L("Measured", "측정 시각")}: {reading.FetchedAt.ToLocalTime():g}", 10));
        content.Children.Add(Text($"{L("Verified account", "확인된 계정")}: {reading.AccountLabel ?? reading.AccountID ?? L("unknown", "알 수 없음")}", 11));
        content.Children.Add(Text($"{L("Plan", "플랜")}: {reading.Plan ?? L("unknown", "알 수 없음")} · {L("Authentication", "인증 출처")}: {reading.AuthSource ?? L("unknown", "알 수 없음")}", 10));
        foreach (var extra in reading.Extras)
            content.Children.Add(Text($"{extra.Title}: {extra.Amount:G} {extra.Unit}" + (extra.Limit is double limit ? $" / {limit:G} {extra.Unit}" : ""), 11));
        if (reading.Warning != null) content.Children.Add(Text(reading.Warning, 10));
        var determining = MoodQuotas(provider).OrderBy(quota => quota.Remaining).FirstOrDefault();
        if (determining != null) content.Children.Add(Text(L("Expression candidate: ", "표정 반영 한도: ") + determining.Title, 10));
    }

    private IEnumerable<(string Key, string Label)> AvailableMetrics()
    {
        var metrics = new Dictionary<string, string>();
        foreach (var provider in providers)
        {
            foreach (string id in new[] { "session", "weekly" }) metrics.TryAdd(MetricKey(provider.Name, id), provider.Name + " · " + id);
            if (provider.Reading != null)
                foreach (var quota in provider.Reading.Windows) metrics[MetricKey(provider.Name, quota.Id)] = provider.Name + " · " + T(quota.Title);
        }
        return metrics.Select(metric => (metric.Key, metric.Value));
    }

    private double? PinRemaining(string pin)
    {
        double? minimum = null;
        foreach (var provider in providers)
        {
            if (provider.Error != null || provider.Reading is not { } reading || !reading.IsCurrent(DateTimeOffset.UtcNow)) continue;
            foreach (var quota in reading.Windows)
                if (pin == MetricKey(provider.Name, quota.Id)) minimum = minimum == null ? quota.Remaining : Math.Min(minimum.Value, quota.Remaining);
        }
        return minimum;
    }

    private string TraySummary()
    {
        var values = settings.TrayPins.Take(settings.CompactTray ? 1 : 12).Select(pin => (settings.CompactTray ? pin[0] + ":" : pin + " ") + Usage.Percent(PinRemaining(pin)));
        string summary = CharacterName + " · " + string.Join(" · ", values);
        return summary[..Math.Min(summary.Length, 127)];
    }

    private void DrawMetricTray()
    {
        trayRow = -1;
        using var bitmap = new Drawing.Bitmap(32, 32);
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        graphics.Clear(Drawing.Color.Transparent);
        var pins = settings.TrayPins.Take(settings.CompactTray ? 1 : 3).ToArray();
        using var font = new Drawing.Font("Segoe UI", settings.CompactTray ? 14 : 9, Drawing.FontStyle.Bold, Drawing.GraphicsUnit.Pixel);
        if (pins.Length == 0) graphics.DrawString("?", font, Drawing.Brushes.White, 8, 4);
        for (int index = 0; index < pins.Length; index++)
        {
            var remaining = PinRemaining(pins[index]);
            float y = index * (32f / pins.Length);
            if (settings.TrayStyle == "bars")
            {
                graphics.FillRectangle(Drawing.Brushes.DimGray, 1, y + 2, 30, 7);
                if (remaining is double number) graphics.FillRectangle(number <= 10 ? Drawing.Brushes.OrangeRed : Drawing.Brushes.MediumSeaGreen, 1, y + 2, (float)(30 * number / 100), 7);
                else graphics.DrawString("?", font, Drawing.Brushes.White, 10, y);
            }
            else graphics.DrawString(remaining == null ? "?" : Math.Floor(remaining.Value).ToString(CultureInfo.InvariantCulture), font, Drawing.Brushes.White, 1, y);
        }
        var handle = bitmap.GetHicon();
        try
        {
            using var borrowed = Drawing.Icon.FromHandle(handle);
            var previous = tray.Icon;
            tray.Icon = (Drawing.Icon)borrowed.Clone();
            previous?.Dispose();
        }
        finally { DestroyIcon(handle); }
    }

    private void PreferenceToggle(StackPanel body, string label, bool enabled, Action<bool> changed)
    {
        var toggle = new CheckBox { Content = label, IsChecked = enabled, Margin = new Thickness(3, 6, 3, 6) };
        toggle.Click += (_, _) => { changed(toggle.IsChecked == true); SaveSettings(); UpdatePresentation(); UpdateCards(); };
        body.Children.Add(toggle);
    }

    private void PreferenceChoice(StackPanel body, string label, string[] values, string current, Action<string> changed)
    {
        body.Children.Add(Text(label));
        var choices = new ComboBox { ItemsSource = values, SelectedItem = current, Margin = new Thickness(3) };
        AutomationProperties.SetName(choices, label);
        choices.SelectionChanged += (_, _) =>
        {
            if (choices.SelectedItem is not string selected) return;
            changed(selected); SaveSettings(); UpdatePresentation(); UpdateCards();
        };
        body.Children.Add(choices);
    }

    private void BuildFeatureControls(StackPanel body)
    {
        var preferences = new StackPanel();
        body.Children.Add(new Expander { Header = L("Usage & system preferences", "사용량 및 시스템 설정"), Content = preferences, Margin = new Thickness(0, 12, 0, 12) });
        PreferenceChoice(preferences, L("Expression provider (hiding a metric does not exclude it)", "표정 제공자 (한도 숨김과 표정 제외는 별개)"), ["all", "Claude", "Codex"], settings.MoodProvider, selected => settings.MoodProvider = selected);
        var metrics = AvailableMetrics().ToArray();
        var metricIDs = new[] { "" }.Concat(metrics.Select(metric => metric.Key[(metric.Key.IndexOf(':') + 1)..])).Distinct().ToArray();
        PreferenceChoice(preferences, L("Expression metric (blank = all)", "표정 한도 (빈 값 = 전체)"), metricIDs, settings.MoodMetric, selected => settings.MoodMetric = selected);
        preferences.Children.Add(Text(L("Remaining thresholds: crying / worried / careful / happy", "잔여량 기준: 울음 / 걱정 / 아낌 / 기쁨"), 11));
        var thresholds = new TextBox { Text = string.Join(", ", settings.MoodThresholds), Margin = new Thickness(3) };
        AutomationProperties.SetName(thresholds, L("Expression thresholds", "표정 기준"));
        preferences.Children.Add(thresholds);
        var thresholdError = Text("", 10);
        preferences.Children.Add(thresholdError);
        preferences.Children.Add(ActionButton(L("Apply thresholds", "기준 적용"), () =>
        {
            if (!TryThresholds(thresholds.Text, 4, out var parsed)) { thresholdError.Text = L("Enter four numbers from 0 to 100.", "0~100 숫자 네 개를 입력하세요."); return; }
            settings.MoodThresholds = parsed; thresholdError.Text = ""; SaveSettings(); UpdatePresentation(); UpdateCards();
        }));
        PreferenceToggle(preferences, L("Predictive expressions (only with sufficient window data)", "페이스 예측 표정 (충분한 측정이 있을 때만)"), settings.PaceMood, enabled => settings.PaceMood = enabled);
        PreferenceToggle(preferences, L("Show reset countdown instead of exact time", "정확한 시각 대신 초기화 카운트다운"), settings.ResetCountdown, enabled => settings.ResetCountdown = enabled);
        PreferenceToggle(preferences, L("Show conditional usage pace", "조건부 사용 페이스 표시"), settings.ShowPace, enabled => settings.ShowPace = enabled);
        PreferenceChoice(preferences, L("Tray icon style", "트레이 아이콘 표시"), ["character", "text", "bars"], settings.TrayStyle, selected => settings.TrayStyle = selected);
        PreferenceToggle(preferences, L("Compact tray (first pin only)", "간결한 트레이 (첫 핀만 표시)"), settings.CompactTray, enabled => settings.CompactTray = enabled);
        BuildMetricControls(preferences, metrics);
        PreferenceToggle(preferences, L("Quota notifications (Windows notification settings apply)", "잔여량 알림 (Windows 알림 설정 적용)"), settings.QuotaAlerts, enabled => { settings.QuotaAlerts = enabled; alertPolicy = new UsageAlertPolicy(); quotaMessages.Clear(); });
        PreferenceToggle(preferences, L("Also alert when usage pace worsens", "사용 페이스 악화도 알림"), settings.PaceAlerts, enabled => settings.PaceAlerts = enabled);
        preferences.Children.Add(Text(L("Alert remaining thresholds, comma-separated", "알림 잔여량 기준 (쉼표 구분)"), 11));
        var alertThresholds = new TextBox { Text = string.Join(", ", settings.AlertThresholds), Margin = new Thickness(3) };
        AutomationProperties.SetName(alertThresholds, L("Notification thresholds", "알림 기준"));
        preferences.Children.Add(alertThresholds);
        preferences.Children.Add(ActionButton(L("Apply alert thresholds", "알림 기준 적용"), () =>
        {
            if (!TryThresholds(alertThresholds.Text, null, out var parsed)) { thresholdError.Text = L("Use numbers from 0 to 100.", "0~100 숫자를 입력하세요."); return; }
            settings.AlertThresholds = parsed; alertPolicy = new UsageAlertPolicy(); SaveSettings();
        }));
        RefreshStartupRegistration();
        var startup = new CheckBox { Content = L("Start at Windows sign-in", "Windows 로그인 시 시작"), IsChecked = startupRegistration == StartupRegistration.CurrentExecutable,
            IsEnabled = preview == null, Margin = new Thickness(3, 6, 3, 6) };
        startupToggle = startup;
        startup.Click += (_, _) =>
        {
            if (systemFeatures == null) { startup.IsChecked = false; return; }
            bool enabled = startup.IsChecked == true;
            systemFeatureError = systemFeatures.SetStartup(enabled);
            if (systemFeatureError == null) { settings.Startup = enabled; SaveSettings(); }
            RefreshStartupRegistration();
            startup.IsChecked = startupRegistration == StartupRegistration.CurrentExecutable;
            ShowSystemFailure();
        };
        preferences.Children.Add(startup);
        startupStatusText = Text(StartupDescription(), 10);
        preferences.Children.Add(startupStatusText);
        BuildHotkeyControl(preferences);
        PreferenceToggle(preferences, L("Discover saved cswap/xswap accounts (read-only)", "cswap/xswap 저장 계정 검색 (읽기 전용)"), settings.DiscoverSavedAccounts, enabled => { settings.DiscoverSavedAccounts = enabled; ApplyAccountSettings(); });
        PreferenceToggle(preferences, L("Allow Codex Windows Credential Manager fallback", "Codex Windows 자격 증명 관리자 읽기 허용"), settings.CredentialManagerEnabled, enabled => { settings.CredentialManagerEnabled = enabled; ApplyAccountSettings(); });
        preferences.Children.Add(Text(L("Credential Manager reads only Codex Auth for the selected Windows home. WSL keyrings are not accessible; explicitly select a WSL UNC config home with a readable auth file. Never copy tokens here.", "자격 증명 관리자는 선택한 Windows home의 Codex Auth만 읽습니다. WSL 키링은 읽을 수 없으며 읽기 가능한 인증 파일이 있는 WSL UNC 설정 경로를 직접 선택하세요. 토큰을 여기에 복사하지 마세요."), 10));
        BuildHomeControls(preferences);
        discoveryWarningText = Text(string.Join(Environment.NewLine, Usage.DiscoveryWarnings.Select(T)), 10);
        preferences.Children.Add(discoveryWarningText);
        PreferenceToggle(preferences, L("Read local usage history (off by default)", "로컬 사용 기록 읽기 (기본 꺼짐)"), settings.LocalHistoryEnabled, enabled =>
        {
            settings.LocalHistoryEnabled = enabled;
            if (enabled) _ = RefreshHistory();
            else { CancelHistory(); historyByHome.Clear(); historyErrors.Clear(); }
        });
        historyScanButton = ActionButton(L("Scan local history", "로컬 기록 조회"), async () => await RefreshHistory());
        preferences.Children.Add(historyScanButton);
        preferences.Children.Add(Text(L("History belongs to each CLI home, not necessarily the displayed account. A home is counted once. API-rate estimates are not subscription bills; unknown prices remain unpriced.", "기록은 CLI home별이며 표시 계정 소유로 단정하지 않습니다. 같은 home은 한 번만 집계합니다. API 환산액은 구독 청구액이 아니며 모르는 가격은 미산정입니다."), 10));
        preferences.Children.Add(ActionButton(L("Choose optional pricing JSON…", "선택형 가격 JSON 선택…"), ChoosePricingFile));
        pricingStatusText = Text(settings.PricingFile ?? L("No pricing file · tokens only", "가격 파일 없음 · 토큰만 표시"), 10);
        preferences.Children.Add(pricingStatusText);
        preferences.Children.Add(ActionButton(L("Clear pricing file", "가격 파일 해제"), () =>
        {
            settings.PricingFile = null;
            if (pricingStatusText != null) pricingStatusText.Text = L("No pricing file · tokens only", "가격 파일 없음 · 토큰만 표시");
            SaveSettings(); _ = RefreshHistory();
        }));
        preferences.Children.Add(ActionButton(L("Copy sanitized diagnostics", "민감정보 없는 진단 복사"), CopyDiagnostics));
        if (systemFeatureError != null) preferences.Children.Add(Text(systemFeatureError, 10));
    }

    private static bool TryThresholds(string text, int? count, out double[] parsed)
    {
        parsed = [];
        var parts = text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length == 0 || (count != null && parts.Length != count)) return false;
        var numbers = new List<double>();
        foreach (string part in parts)
        {
            if (!double.TryParse(part, NumberStyles.Float, CultureInfo.InvariantCulture, out double number) || !double.IsFinite(number) || number < 0 || number > 100) return false;
            numbers.Add(number);
        }
        parsed = numbers.Distinct().Order().ToArray();
        return count == null || parsed.Length == count;
    }

    private void BuildMetricControls(StackPanel preferences, (string Key, string Label)[] metrics)
    {
        var metricBody = new StackPanel();
        preferences.Children.Add(new Expander { Header = L("Metric visibility & ordered tray pins", "한도 표시 및 트레이 핀 순서"), Content = metricBody });
        metricBody.Children.Add(Text(L("The icon shows the first three pins (one in compact mode); the tray menu lists all pins. Values use the lowest current matching quota across this provider's homes.", "아이콘은 처음 세 핀 (간결한 모드에서는 하나)을 표시하고 트레이 메뉴에는 모두 표시합니다. 값은 해당 제공자의 home들 중 최신 한도 최솟값입니다."), 10));
        foreach (var metric in metrics)
            PreferenceToggle(metricBody, L("Show card: ", "카드 표시: ") + metric.Label, !settings.HiddenMetrics.Contains(metric.Key), enabled =>
            {
                settings.HiddenMetrics = enabled ? settings.HiddenMetrics.Where(key => key != metric.Key).ToArray() : settings.HiddenMetrics.Append(metric.Key).Distinct().ToArray();
            });
        var pins = new ListBox { ItemsSource = settings.TrayPins.ToArray(), Height = 95, Margin = new Thickness(3) };
        AutomationProperties.SetName(pins, L("Ordered tray pins", "트레이 핀 순서"));
        metricBody.Children.Add(pins);
        var available = new ComboBox { ItemsSource = metrics.Select(metric => metric.Key).ToArray(), SelectedIndex = metrics.Length > 0 ? 0 : -1, Margin = new Thickness(3) };
        AutomationProperties.SetName(available, L("Available tray metrics", "트레이 한도 목록"));
        metricBody.Children.Add(available);
        void CommitPins(IEnumerable<string> ordered) { settings.TrayPins = ordered.Distinct().Take(12).ToArray(); pins.ItemsSource = settings.TrayPins.ToArray(); SaveSettings(); UpdatePresentation(); }
        metricBody.Children.Add(ActionButton(L("Pin selected metric", "선택 한도 고정"), () => { if (available.SelectedItem is string key) CommitPins(settings.TrayPins.Append(key)); }));
        metricBody.Children.Add(ActionButton(L("Remove selected pin", "선택 핀 제거"), () => { if (pins.SelectedItem is string key) CommitPins(settings.TrayPins.Where(pin => pin != key)); }));
        foreach (int delta in new[] { -1, 1 })
            metricBody.Children.Add(ActionButton(delta < 0 ? L("Move pin up", "핀 위로") : L("Move pin down", "핀 아래로"), () =>
            {
                int index = pins.SelectedIndex;
                if (index < 0 || index + delta < 0 || index + delta >= settings.TrayPins.Length) return;
                var ordered = settings.TrayPins.ToArray();
                (ordered[index], ordered[index + delta]) = (ordered[index + delta], ordered[index]);
                CommitPins(ordered); pins.SelectedIndex = index + delta;
            }));
    }

    private void BuildHotkeyControl(StackPanel preferences)
    {
        var record = ActionButton(HotkeyLabel(), () => { });
        bool recording = false;
        record.Click += (_, _) => { recording = true; record.Content = L("Press Ctrl/Alt/Shift/Win + a key (Esc cancels)", "Ctrl/Alt/Shift/Win + 키 입력 (Esc 취소)"); record.Focus(); };
        record.PreviewKeyDown += (_, args) =>
        {
            if (!recording) return;
            args.Handled = true;
            var key = args.Key == Key.System ? args.SystemKey : args.Key;
            if (key == Key.Escape) { recording = false; record.Content = HotkeyLabel(); return; }
            if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
            var modifiers = Keyboard.Modifiers;
            uint nativeModifiers = (modifiers.HasFlag(ModifierKeys.Alt) ? 1u : 0) | (modifiers.HasFlag(ModifierKeys.Control) ? 2u : 0)
                | (modifiers.HasFlag(ModifierKeys.Shift) ? 4u : 0) | (modifiers.HasFlag(ModifierKeys.Windows) ? 8u : 0);
            if (nativeModifiers == 0) return;
            uint nativeKey = (uint)KeyInterop.VirtualKeyFromKey(key);
            if (preview != null || systemFeatures == null) return;
            systemFeatureError = systemFeatures.ConfigureHotkey(nativeModifiers, nativeKey);
            if (systemFeatureError == null) { settings.HotkeyModifiers = nativeModifiers; settings.HotkeyKey = nativeKey; SaveSettings(); }
            else if (!systemFeatures.HotkeyRegistered) { settings.HotkeyKey = 0; settings.HotkeyModifiers = 0; SaveSettings(); }
            recording = false; record.Content = HotkeyLabel(); ShowSystemFailure();
        };
        preferences.Children.Add(record);
        preferences.Children.Add(ActionButton(L("Disable global shortcut", "전역 단축키 해제"), () =>
        {
            if (preview != null || systemFeatures == null) return;
            systemFeatureError = systemFeatures.ConfigureHotkey(0, 0);
            if (systemFeatureError == null) { settings.HotkeyKey = 0; settings.HotkeyModifiers = 0; SaveSettings(); }
            record.Content = HotkeyLabel(); ShowSystemFailure();
        }));
    }

    private string HotkeyLabel()
    {
        if (settings.HotkeyKey == 0) return L("Record global shortcut… (disabled)", "전역 단축키 기록… (꺼짐)");
        var labels = new List<string>();
        if ((settings.HotkeyModifiers & 2) != 0) labels.Add("Ctrl");
        if ((settings.HotkeyModifiers & 1) != 0) labels.Add("Alt");
        if ((settings.HotkeyModifiers & 4) != 0) labels.Add("Shift");
        if ((settings.HotkeyModifiers & 8) != 0) labels.Add("Win");
        labels.Add(KeyInterop.KeyFromVirtualKey((int)settings.HotkeyKey).ToString());
        return L("Shortcut: ", "단축키: ") + string.Join("+", labels);
    }

    private void ShowSystemFailure()
    {
        if (systemFeatureError != null) MessageBox.Show(systemFeatureError, T("치이카와 펫"), MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    private void BuildHomeControls(StackPanel preferences)
    {
        var homes = new StackPanel();
        preferences.Children.Add(new Expander { Header = L("Explicit config homes / WSL UNC", "직접 지정한 설정 home / WSL UNC"), Content = homes });
        foreach (var home in settings.AdditionalHomes.ToArray()) AddHomeRow(homes, home);
        var provider = new ComboBox { ItemsSource = new[] { "Claude", "Codex" }, SelectedIndex = 1, Margin = new Thickness(3) };
        var label = new TextBox { Margin = new Thickness(3), ToolTip = L("Optional display label (not verified identity)", "표시 이름 (확인된 신원 아님)") };
        var path = new TextBox { Margin = new Thickness(3), ToolTip = L("CLI config directory; explicit \\\\wsl.localhost\\Distro\\home\\… supported", "CLI 설정 폴더; 직접 지정한 WSL UNC 지원") };
        AutomationProperties.SetName(provider, L("Home provider", "home 제공자"));
        AutomationProperties.SetName(label, L("Home display label", "home 표시 이름"));
        AutomationProperties.SetName(path, L("Home directory", "home 폴더"));
        homes.Children.Add(provider); homes.Children.Add(Text(L("Display label", "표시 이름"), 10)); homes.Children.Add(label);
        homes.Children.Add(Text(L("Config directory (not auth file)", "설정 폴더 (인증 파일 아님)"), 10)); homes.Children.Add(path);
        homes.Children.Add(ActionButton(L("Browse home…", "home 선택…"), () =>
        {
            featureDialogOpen = true;
            try { using var chooser = new Forms.FolderBrowserDialog { Description = L("Select the CLI config home", "CLI 설정 home 선택") }; if (chooser.ShowDialog() == Forms.DialogResult.OK) path.Text = chooser.SelectedPath; }
            finally { featureDialogOpen = false; panel?.Activate(); }
        }));
        var error = Text("", 10); homes.Children.Add(error);
        homes.Children.Add(ActionButton(L("Add explicit home", "home 추가"), () =>
        {
            try
            {
                if (string.IsNullOrWhiteSpace(path.Text) || !Path.IsPathFullyQualified(path.Text)) { error.Text = L("Enter an absolute directory path.", "절대 폴더 경로를 입력하세요."); return; }
                string directory = Path.GetFullPath(path.Text.Trim());
                string selectedProvider = (string)provider.SelectedItem;
                bool duplicate = settings.AdditionalHomes.Any(home => home.Provider == selectedProvider
                    && string.Equals(Usage.NormalizeSourcePath(home.Directory), Usage.NormalizeSourcePath(directory), StringComparison.Ordinal))
                    || Usage.DefaultAccounts().Any(account => account.Provider == selectedProvider
                        && string.Equals(Usage.NormalizeSourcePath(account.Directory), Usage.NormalizeSourcePath(directory), StringComparison.Ordinal));
                if (duplicate) { error.Text = L("That home is already configured.", "이미 추가한 home입니다."); return; }
                var home = new UsageHome { Provider = selectedProvider, Directory = directory, Label = label.Text.Trim() };
                settings.AdditionalHomes.Add(home); AddHomeRow(homes, home); ApplyAccountSettings(); error.Text = L("Home added.", "home을 추가했습니다.");
            }
            catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException) { error.Text = L("Invalid directory path.", "잘못된 폴더 경로입니다."); }
        }));
    }

    private void AddHomeRow(StackPanel homes, UsageHome home)
    {
        var row = new StackPanel();
        row.Children.Add(Text(home.Provider + " · " + home.Label + "\n" + home.Directory, 10));
        row.Children.Add(ActionButton(L("Remove home", "home 제거"), () =>
        {
            settings.AdditionalHomes.Remove(home); homes.Children.Remove(row); ApplyAccountSettings();
        }));
        homes.Children.Add(row);
    }

    private static string HistoryKey(ProviderState provider) => provider.Name + ":" + Usage.NormalizeSourcePath(provider.Account.Directory);

    private void CancelHistory()
    {
        var cancellation = historyCancellation;
        historyCancellation = null;
        historyScanning = false;
        cancellation?.Cancel();
    }

    private async Task RefreshHistory()
    {
        if (!settings.LocalHistoryEnabled || preview != null || closing) return;
        CancelHistory();
        var cancellation = new CancellationTokenSource();
        historyCancellation = cancellation;
        historyScanning = true;
        historyByHome.Clear();
        historyErrors.Clear();
        UpdateCards();
        string? selectedPricing = settings.PricingFile;
        try
        {
            var scanned = new HashSet<string>(StringComparer.Ordinal);
            foreach (var provider in providers.ToArray())
            {
                string key = HistoryKey(provider);
                if (!scanned.Add(key)) continue;
                try
                {
                    var history = await LocalUsageHistory.ScanAsync(provider.Name, provider.Account.Directory, selectedPricing, cancellation.Token);
                    if (cancellation.IsCancellationRequested || !ReferenceEquals(historyCancellation, cancellation)
                        || !settings.LocalHistoryEnabled || closing || settings.PricingFile != selectedPricing) return;
                    historyByHome[key] = history; historyErrors.Remove(key);
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return; }
                catch (Exception error) when (error is InvalidDataException or IOException or UnauthorizedAccessException or InvalidOperationException or System.Text.Json.JsonException or ArgumentException)
                {
                    if (cancellation.IsCancellationRequested || !ReferenceEquals(historyCancellation, cancellation)) return;
                    historyErrors[key] = L("Cannot read history or pricing. Check the selected home and pricing JSON.", "기록 또는 가격을 읽을 수 없습니다. 선택한 home과 가격 JSON을 확인하세요.");
                    historyByHome.Remove(key);
                }
            }
        }
        finally
        {
            cancellation.Dispose();
            if (ReferenceEquals(historyCancellation, cancellation))
            {
                historyCancellation = null;
                historyScanning = false;
                if (!closing) UpdateCards();
            }
        }
    }

    private void AddHistoryDetails(StackPanel content, ProviderState provider)
    {
        if (!settings.LocalHistoryEnabled) return;
        string key = HistoryKey(provider);
        if (providers.First(candidate => string.Equals(HistoryKey(candidate), key, StringComparison.Ordinal)) != provider)
        { content.Children.Add(Text(L("Shared home history is shown once on its first card.", "같은 home의 기록은 첫 카드에만 표시합니다."), 10)); return; }
        content.Children.Add(Text(L("Local home history · account ownership unknown", "로컬 home 기록 · 계정 소유 여부 알 수 없음"), 11));
        if (historyErrors.TryGetValue(key, out string? error)) content.Children.Add(Text(error, 10));
        if (!historyByHome.TryGetValue(key, out var history)) { content.Children.Add(Text(historyScanning ? L("Scanning history…", "기록 조회 중…") : L("Use Scan local history to measure.", "로컬 기록 조회 버튼으로 측정하세요."), 10)); return; }
        AddHistoryPeriod(content, history, L("Today", "오늘"), DateTime.Today, DateTime.Today);
        AddHistoryPeriod(content, history, L("Yesterday", "어제"), DateTime.Today.AddDays(-1), DateTime.Today.AddDays(-1));
        AddHistoryPeriod(content, history, L("Last 30 local days", "최근 30일"), DateTime.Today.AddDays(-29), DateTime.Today);
        foreach (var day in history.Days.OrderByDescending(day => day.Day).Take(14))
        {
            string estimate = day.EstimatedCost is double cost ? $" · ~${cost:F4} API" + (day.UnpricedTokens > 0 ? L(" priced subtotal", " 산정분 소계") : "") : "";
            string unpriced = day.UnpricedTokens > 0 ? L($" · {day.UnpricedTokens:N0} unpriced tokens", $" · {day.UnpricedTokens:N0} 토큰 미산정") : "";
            content.Children.Add(Text($"{day.Day} · {day.TotalTokens:N0} tokens (in {day.InputTokens:N0}, out {day.OutputTokens:N0}, cache {day.CachedTokens:N0}){estimate}{unpriced}", 10));
        }
        if (history.Days.Count == 0) content.Children.Add(Text(L("No measured local usage events.", "측정된 로컬 사용 이벤트가 없습니다."), 10));
        if (history.Warning != null) content.Children.Add(Text(history.Warning, 10));
    }

    private static void AddHistoryPeriod(StackPanel content, UsageHistorySummary history, string title, DateTime from, DateTime through)
    {
        string first = from.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        string last = through.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        decimal tokens = 0, unpriced = 0;
        double cost = 0;
        bool measured = false, priced = false;
        foreach (var day in history.Days)
        {
            if (string.CompareOrdinal(day.Day, first) < 0 || string.CompareOrdinal(day.Day, last) > 0) continue;
            measured = true;
            tokens += day.TotalTokens;
            unpriced += day.UnpricedTokens;
            if (day.EstimatedCost is double estimate) { cost += estimate; priced = true; }
        }
        string summary = !measured ? L("no measured events", "측정 이벤트 없음") : $"{tokens:N0} tokens";
        if (priced) summary += $" · ~${cost:F4} API" + (unpriced > 0 ? L(" priced subtotal", " 산정분 소계") : "");
        if (unpriced > 0) summary += L($" · {unpriced:N0} unpriced", $" · {unpriced:N0} 미산정");
        content.Children.Add(Text(title + ": " + summary, 10));
    }

    private void ChoosePricingFile()
    {
        if (preview != null) return;
        featureDialogOpen = true;
        try
        {
            var chooser = new Microsoft.Win32.OpenFileDialog { Title = L("Optional local pricing JSON (USD per million tokens)", "선택형 로컬 가격 JSON (백만 토큰당 USD)"), Filter = "JSON (*.json)|*.json", CheckFileExists = true };
            if (chooser.ShowDialog(panel) == true)
            {
                settings.PricingFile = chooser.FileName;
                if (pricingStatusText != null) pricingStatusText.Text = chooser.FileName;
                SaveSettings(); _ = RefreshHistory();
            }
        }
        finally { featureDialogOpen = false; panel?.Activate(); }
    }

    private void CopyDiagnostics()
    {
        var diagnostics = new StringBuilder("ChiikawaPet " + Updates.AppVersion + " · Windows\n");
        diagnostics.AppendLine("Read-only usage. No tokens, account identity, paths, or provider payloads included.");
        foreach (var provider in providers)
        {
            var reading = provider.Reading;
            diagnostics.AppendLine($"provider={provider.Name}; source={reading?.Source ?? "none"}; measured={reading?.FetchedAt.ToString("O") ?? "none"}; windows={reading?.Windows.Length ?? 0}; error={provider.Error != null}; retry={provider.RetryAt?.ToString("O") ?? "none"}");
        }
        diagnostics.AppendLine($"savedDiscovery={settings.DiscoverSavedAccounts}; credentialManager={settings.CredentialManagerEnabled}; explicitHomes={settings.AdditionalHomes.Count}; localHistory={settings.LocalHistoryEnabled}; pricing={settings.PricingFile != null}");
        try { Clipboard.SetText(diagnostics.ToString()); }
        catch (System.Runtime.InteropServices.COMException) { MessageBox.Show(L("Clipboard is unavailable. Try again.", "클립보드를 사용할 수 없습니다. 다시 시도하세요.")); }
    }
}
