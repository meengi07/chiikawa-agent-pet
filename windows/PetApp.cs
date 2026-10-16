using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using static ChiikawaPet.Language;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace ChiikawaPet;

internal sealed class PetApp : Window
{
    private static readonly (string Id, string Name)[] Characters =
        [("chiikawa", "치이카와"), ("hachiware", "하치와레"), ("usagi", "우사기"), ("momonga", "모몽가")];
    private static readonly int[] MomongaRowEdges = [0, 400, 700, 1024];
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ChiikawaPet", "settings.json");
    private readonly Settings settings;
    private readonly double? preview;
    private readonly ProviderState[] providers = [new("Claude"), new("Codex")];
    private readonly Dictionary<string, BitmapSource[]> sprites = new();
    private readonly Image pet = new() { Stretch = Stretch.Uniform };
    private readonly Forms.NotifyIcon tray = new();
    private readonly DispatcherTimer animation = new() { Interval = TimeSpan.FromMilliseconds(140) };
    private readonly DispatcherTimer refreshTimer = new() { Interval = TimeSpan.FromMinutes(2) };
    private Window? panel;
    private ContextMenu? petMenu;
    private StackPanel? providerCards;
    private TextBlock? caption;
    private Button? refreshButton;
    private bool refreshing, mouseDown, dragged, closing;
    private Point dragStart, originalPosition;
    private int frame, direction = -1, trayRow = -1;
    private string trayCharacter = "";
    private double? Remaining => preview ?? Usage.Minimum(providers);
    private string CharacterName => T(Characters.First(character => character.Id == settings.Character).Name);

    [STAThread]
    public static void Main(string[] arguments)
    {
        double? preview = null;
        bool showUsage = false;
        for (int index = 0; index < arguments.Length; index++)
        {
            if (arguments[index] == "--show-usage") { showUsage = true; continue; }
            if (arguments[index] == "--preview" && index + 1 < arguments.Length
                && double.TryParse(arguments[++index], NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
                && double.IsFinite(value) && value >= 0 && value <= 100)
            { preview = value; continue; }
            MessageBox.Show(T("실행 옵션: --preview 0~100 [--show-usage]"), T("치이카와 펫"));
            return;
        }
        using var instance = new Mutex(true, "Local\\ChiikawaAgentPet", out bool created);
        if (!created) { MessageBox.Show(T("이미 실행 중입니다. 알림 영역의 펫 아이콘을 클릭하세요."), T("치이카와 펫")); return; }
        try
        {
            var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
            var window = new PetApp(preview);
            app.MainWindow = window;
            window.Show();
            if (!window.settings.Visible) window.Hide();
            if (showUsage) window.TogglePanel();
            app.DispatcherUnhandledException += (_, error) =>
            {
                // Show a bounded message: exception details may contain local account information.
                MessageBox.Show(T("앱 실행 중 오류가 발생했습니다. 펫을 다시 실행하세요."), T("치이카와 펫"));
                error.Handled = true;
                window.Quit();
            };
            app.Run();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        { MessageBox.Show(T("펫 리소스 또는 설정을 읽을 수 없습니다. 실행 파일을 다시 압축 해제하고 설정 파일을 확인하세요."), T("치이카와 펫")); }
        finally { instance.ReleaseMutex(); }
    }

    private PetApp(double? preview)
    {
        this.preview = preview;
        settings = Settings.Load(SettingsPath);
        ChiikawaPet.Language.Current = settings.Language;
        Title = T("치이카와 펫");
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Width = 148 * settings.Scale;
        Height = 164 * settings.Scale;
        Left = settings.X ?? SystemParameters.WorkArea.Right - Width - 60;
        Top = settings.Y ?? SystemParameters.WorkArea.Bottom - Height - 55;
        LoadSprites();
        RenderOptions.SetBitmapScalingMode(pet, BitmapScalingMode.NearestNeighbor);
        var petButton = new Button
        {
            Content = pet, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            Padding = new Thickness(0), ToolTip = T("클릭: 사용량 · 드래그: 이동 · 우클릭: 메뉴")
        };
        // The default button template adds hover shading; keep native button keyboard/automation behavior.
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        petButton.Template = new ControlTemplate(typeof(Button)) { VisualTree = presenter };
        petButton.Click += (_, _) => TogglePanel();
        Content = petButton;
        petButton.PreviewMouseLeftButtonDown += (_, mouse) =>
        {
            mouseDown = true;
            dragged = false;
            dragStart = PointToScreen(mouse.GetPosition(this));
            originalPosition = new Point(Left, Top);
            petButton.CaptureMouse();
            mouse.Handled = true;
        };
        petButton.PreviewMouseMove += (_, mouse) =>
        {
            if (!mouseDown) return;
            var current = PointToScreen(mouse.GetPosition(this));
            var transform = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
            var delta = transform.Transform(current - dragStart);
            if (delta.Length > 3) { dragged = true; ClosePanel(); }
            if (dragged) { Left = originalPosition.X + delta.X; Top = originalPosition.Y + delta.Y; }
        };
        petButton.PreviewMouseLeftButtonUp += (_, mouse) =>
        {
            if (!mouseDown) return;
            mouseDown = false;
            petButton.ReleaseMouseCapture();
            ClampPosition();
            if (dragged) SaveSettings(); else TogglePanel();
            mouse.Handled = true;
        };
        petButton.LostMouseCapture += (_, _) => mouseDown = false;
        petButton.MouseRightButtonUp += (_, mouse) =>
        {
            petMenu = MakePetMenu();
            petMenu.PlacementTarget = petButton;
            petMenu.IsOpen = true;
            mouse.Handled = true;
        };
        Loaded += (_, _) => ClampPosition();
        DpiChanged += (_, _) => ClampPosition();
        animation.Tick += (_, _) => Animate();
        refreshTimer.Tick += async (_, _) => await Refresh();
        BuildTrayMenu();
        tray.MouseClick += (_, mouse) =>
        {
            if (mouse.Button == Forms.MouseButtons.Left) Dispatcher.Invoke(TogglePanel);
        };
        UpdatePresentation();
        tray.Visible = true;
        refreshTimer.Start();
        Dispatcher.BeginInvoke(new Action(async () => await Refresh()));
        Closing += (_, _) =>
        {
            closing = true;
            animation.Stop();
            refreshTimer.Stop();
            ClosePanel();
            SaveSettings();
            tray.Visible = false;
            var icon = tray.Icon;
            tray.Dispose();
            icon?.Dispose();
        };
    }

    private void LoadSprites()
    {
        foreach (var (id, _) in Characters)
        {
            var sheet = new BitmapImage(new Uri($"pack://application:,,,/Sprites/{id}.png"));
            if (sheet.PixelWidth < 512 || sheet.PixelHeight < 480
                || (id == "momonga" && (sheet.PixelWidth != 1536 || sheet.PixelHeight != 1024)))
                throw new IOException("Invalid sprite sheet");
            var frames = new BitmapSource[48];
            for (int row = 0; row < 6; row++)
                for (int column = 0; column < 8; column++)
                {
                    // Momonga uses one open/blinking pair per mood; idle motion stays in DrawPet.
                    int index = row * 2 + (column >= 6 ? 1 : 0);
                    int columns = id == "momonga" ? 4 : 8, rows = id == "momonga" ? 3 : 6;
                    int sourceColumn = id == "momonga" ? index % 4 : column;
                    int sourceRow = id == "momonga" ? index / 4 : row;
                    int x = sourceColumn * sheet.PixelWidth / columns;
                    int y = id == "momonga" ? MomongaRowEdges[sourceRow] : sourceRow * sheet.PixelHeight / rows;
                    BitmapSource bitmap = new CroppedBitmap(sheet, new Int32Rect(x, y,
                        (sourceColumn + 1) * sheet.PixelWidth / columns - x,
                        (id == "momonga" ? MomongaRowEdges[sourceRow + 1] : (sourceRow + 1) * sheet.PixelHeight / rows) - y));
                    if (id == "momonga")
                    {
                        // Trim transparent padding, keeping the complete tail and outline.
                        bitmap = new FormatConvertedBitmap(bitmap, PixelFormats.Pbgra32, null, 0);
                        int stride = bitmap.PixelWidth * 4;
                        var pixels = new byte[stride * bitmap.PixelHeight];
                        bitmap.CopyPixels(pixels, stride, 0);
                        int left = bitmap.PixelWidth, top = bitmap.PixelHeight, right = -1, bottom = -1;
                        for (int py = 0; py < bitmap.PixelHeight; py++)
                            for (int px = 0; px < bitmap.PixelWidth; px++)
                                if (pixels[py * stride + px * 4 + 3] > 1)
                                {
                                    left = Math.Min(left, px); right = Math.Max(right, px);
                                    top = Math.Min(top, py); bottom = Math.Max(bottom, py);
                                }
                        if (right < left || bottom < top) throw new IOException("Empty Momonga sprite");
                        bitmap = new CroppedBitmap(bitmap, new Int32Rect(left, top, right - left + 1, bottom - top + 1));
                        var visual = new DrawingVisual();
                        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.NearestNeighbor);
                        double scale = Math.Min(60.0 / bitmap.PixelWidth, 76.0 / bitmap.PixelHeight);
                        double width = bitmap.PixelWidth * scale, height = bitmap.PixelHeight * scale;
                        using (var drawing = visual.RenderOpen())
                            drawing.DrawImage(bitmap, new Rect((64 - width) / 2, 76 - height, width, height));
                        var normalized = new RenderTargetBitmap(64, 80, 96, 96, PixelFormats.Pbgra32);
                        normalized.Render(visual);
                        bitmap = normalized;
                    }
                    bitmap.Freeze();
                    frames[row * 8 + column] = bitmap;
                }
            sprites[id] = frames;
        }
    }

    private void DrawPet()
    {
        int row = Usage.MoodRow(Remaining);
        int column = row == 4 ? frame / 3 % 8 : frame % 40 >= 38 ? 6 + frame % 2 : frame % 6;
        pet.Source = sprites[settings.Character][row * 8 + column];
        pet.RenderTransform = new TranslateTransform(0, frame / 8 % 4 == 2 ? -1 : 0);
    }

    private void Animate()
    {
        frame = (frame + 1) % 120;
        DrawPet();
        if (!settings.Wanders || mouseDown || panel != null || IsMouseOver
            || petMenu?.IsOpen == true || tray.ContextMenuStrip?.Visible == true) return;
        var cursor = Forms.Control.MousePosition;
        var localCursor = PointFromScreen(new Point(cursor.X, cursor.Y));
        if (new Rect(-24, -24, Width + 48, Height + 48).Contains(localCursor)) return;
        var screen = WorkArea();
        Left += direction * 1.8;
        if (Left < screen.Left + 12) { Left = screen.Left + 12; direction = 1; }
        if (Left + Width > screen.Right - 12) { Left = screen.Right - Width - 12; direction = -1; }
    }

    private Rect WorkArea()
    {
        if (PresentationSource.FromVisual(this)?.CompositionTarget is not { } target) return SystemParameters.WorkArea;
        var center = PointToScreen(new Point(Width / 2, Height / 2));
        var screen = Forms.Screen.FromPoint(new Drawing.Point((int)center.X, (int)center.Y)).WorkingArea;
        var start = target.TransformFromDevice.Transform(new Point(screen.Left, screen.Top));
        var end = target.TransformFromDevice.Transform(new Point(screen.Right, screen.Bottom));
        return new Rect(start, end);
    }

    private void ClampPosition()
    {
        var area = WorkArea();
        Left = Math.Clamp(Left, area.Left, Math.Max(area.Left, area.Right - Width));
        Top = Math.Clamp(Top, area.Top, Math.Max(area.Top, area.Bottom - Height));
    }

    private void SaveSettings()
    {
        settings.X = Left;
        settings.Y = Top;
        // A preview should not overwrite the user's real pet settings.
        if (preview != null) return;
        try { settings.Save(SettingsPath); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { MessageBox.Show(T("펫 설정을 저장할 수 없습니다. %LOCALAPPDATA%\\ChiikawaPet 폴더의 쓰기 권한을 확인하세요."), T("치이카와 펫")); }
    }

    private async Task Refresh()
    {
        if (refreshing || preview != null || closing) return;
        refreshing = true;
        UpdateCards();
        try
        {
            await Task.WhenAll(providers.Select(async provider =>
            {
                try { provider.Succeed(await Usage.Fetch(provider.Name)); }
                catch (InvalidOperationException error) { provider.Fail(error.Message); }
                if (!closing) { UpdatePresentation(); UpdateCards(); }
            }));
        }
        finally { refreshing = false; if (!closing) UpdateCards(); }
    }

    private void UpdatePresentation()
    {
        ((Button)Content).ToolTip = T("클릭: 사용량 · 드래그: 이동 · 우클릭: 메뉴");
        Title = T($"{CharacterName} 펫");
        AutomationProperties.SetName((Button)Content, T($"{CharacterName}, 잔여량 {Usage.Percent(Remaining)}. {Usage.Caption(Remaining)}"));
        DrawPet();
        if (settings.Visible) animation.Start(); else animation.Stop();
        tray.Text = $"{CharacterName} · Claude {Usage.Percent(providers[0].Remaining)} · Codex {Usage.Percent(providers[1].Remaining)}";
        int row = Usage.MoodRow(Remaining);
        if (trayRow == row && trayCharacter == settings.Character) return;
        trayRow = row;
        trayCharacter = settings.Character;
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(sprites[settings.Character][row * 8]));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        stream.Position = 0;
        using var bitmap = new Drawing.Bitmap(stream);
        var handle = bitmap.GetHicon();
        try
        {
            using var borrowedIcon = Drawing.Icon.FromHandle(handle);
            var old = tray.Icon;
            tray.Icon = (Drawing.Icon)borrowedIcon.Clone();
            old?.Dispose();
        }
        finally { DestroyIcon(handle); }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);

    private void SelectLanguage(string code)
    {
        settings.Language = code;
        ChiikawaPet.Language.Current = code;
        SaveSettings();
        bool wasOpen = panel != null;
        ClosePanel();
        var previousMenu = tray.ContextMenuStrip;
        BuildTrayMenu();
        previousMenu?.Dispose();
        UpdatePresentation();
        if (wasOpen) TogglePanel();
    }

    private void SelectCharacter(string id)
    {
        settings.Character = id;
        SaveSettings();
        UpdatePresentation();
        UpdateCards();
    }

    private void SetScale(double scale)
    {
        settings.Scale = Math.Clamp(scale, 0.4, 1.2);
        double middle = Left + Width / 2, bottom = Top + Height;
        Width = 148 * settings.Scale;
        Height = 164 * settings.Scale;
        Left = middle - Width / 2;
        Top = bottom - Height;
        ClampPosition();
        SaveSettings();
    }

    private void SetVisible(bool visible)
    {
        settings.Visible = visible;
        if (visible) { Show(); ClampPosition(); } else Hide();
        SaveSettings();
        UpdatePresentation();
    }

    private void CenterPet()
    {
        SetVisible(true);
        var screen = WorkArea();
        Left = screen.Left + (screen.Width - Width) / 2;
        Top = screen.Bottom - Height - 60;
        ClampPosition();
        SaveSettings();
    }

    private void BuildTrayMenu()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(T("사용량 보기"), null, (_, _) => Dispatcher.Invoke(TogglePanel));
        var characters = new Forms.ToolStripMenuItem(T("펫 종류"));
        foreach (var (id, name) in Characters)
            characters.DropDownItems.Add(T(name), null, (_, _) => Dispatcher.Invoke(() => SelectCharacter(id)));
        menu.Items.Add(characters);
        var languages = new Forms.ToolStripMenuItem("Language / 언어");
        foreach (var (code, label) in new[] { ("en", "English"), ("ko", "한국어") })
        {
            var item = new Forms.ToolStripMenuItem(label) { Checked = settings.Language == code };
            item.Click += (_, _) => Dispatcher.Invoke(() => SelectLanguage(code));
            languages.DropDownItems.Add(item);
        }
        menu.Items.Add(languages);
        var visible = new Forms.ToolStripMenuItem(T("화면에 펫 표시"));
        visible.Click += (_, _) => Dispatcher.Invoke(() => SetVisible(!settings.Visible));
        menu.Items.Add(visible);
        var wander = new Forms.ToolStripMenuItem(T("느긋하게 산책하기"));
        wander.Click += (_, _) => Dispatcher.Invoke(() => { settings.Wanders = !settings.Wanders; SaveSettings(); });
        menu.Items.Add(wander);
        menu.Items.Add(T("화면 가운데로 데려오기"), null, (_, _) => Dispatcher.Invoke(CenterPet));
        menu.Items.Add(T("새로고침"), null, (_, _) => Dispatcher.InvokeAsync(Refresh));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(T("펫 종료"), null, (_, _) => Dispatcher.Invoke(Quit));
        menu.Opening += (_, _) => { visible.Checked = settings.Visible; wander.Checked = settings.Wanders; };
        tray.ContextMenuStrip = menu;
    }

    private ContextMenu MakePetMenu()
    {
        var menu = new ContextMenu();
        void Add(string title, Action action, bool? check = null)
        {
            var item = new MenuItem { Header = title, IsCheckable = check != null, IsChecked = check ?? false };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Add(T("사용량 보기"), TogglePanel);
        Add("English", () => SelectLanguage("en"), settings.Language == "en");
        Add("한국어", () => SelectLanguage("ko"), settings.Language == "ko");
        foreach (var (id, name) in Characters) Add(T(name), () => SelectCharacter(id), settings.Character == id);
        menu.Items.Add(new Separator());
        Add(T("화면에 펫 표시"), () => SetVisible(!settings.Visible), settings.Visible);
        Add(T("느긋하게 산책하기"), () => { settings.Wanders = !settings.Wanders; SaveSettings(); }, settings.Wanders);
        Add(T("화면 가운데로 데려오기"), CenterPet);
        Add(T("새로고침"), async () => await Refresh());
        Add(T("펫 종료"), Quit);
        return menu;
    }

    private static TextBlock Text(string text, double size = 12) => new()
    { Text = T(text), FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 3) };

    private static Button ActionButton(string title, Action action)
    {
        var button = new Button { Content = T(title), Padding = new Thickness(10, 7, 10, 7), Margin = new Thickness(3) };
        button.Click += (_, _) => action();
        return button;
    }

    private void TogglePanel()
    {
        if (panel != null) { ClosePanel(); return; }
        var screen = WorkArea();
        var body = new StackPanel { Margin = new Thickness(20) };
        body.Children.Add(Text("CHIIKAWA PET", 11));
        caption = Text(T($"{CharacterName}의 에너지 · {Usage.Caption(Remaining)}"), 20);
        body.Children.Add(caption);
        var choices = new UniformGrid { Columns = 2 };
        foreach (var (id, name) in Characters)
        {
            var content = new StackPanel();
            var image = new Image { Source = sprites[id][Usage.MoodRow(Remaining) * 8], Width = 64, Height = 80 };
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
            content.Children.Add(image);
            content.Children.Add(Text(name));
            var choice = ActionButton(name, () => SelectCharacter(id));
            choice.Content = content;
            AutomationProperties.SetName(choice, T($"{name} 선택"));
            choices.Children.Add(choice);
        }
        body.Children.Add(choices);
        var languageChoices = new StackPanel { Orientation = Orientation.Horizontal };
        languageChoices.Children.Add(ActionButton("English", () => SelectLanguage("en")));
        languageChoices.Children.Add(ActionButton("한국어", () => SelectLanguage("ko")));
        body.Children.Add(Text("Language / 언어"));
        body.Children.Add(languageChoices);
        var sizeLabel = Text(T($"펫 크기 {Math.Round(settings.Scale * 100)}%"));
        body.Children.Add(sizeLabel);
        var slider = new Slider { Minimum = 0.4, Maximum = 1.2, Value = settings.Scale, TickFrequency = 0.05,
            IsSnapToTickEnabled = true, Margin = new Thickness(5, 8, 5, 8) };
        AutomationProperties.SetName(slider, T("펫 크기"));
        slider.ValueChanged += (_, _) => { SetScale(slider.Value); sizeLabel.Text = T($"펫 크기 {Math.Round(settings.Scale * 100)}%"); };
        body.Children.Add(slider);
        body.Children.Add(ActionButton(T("기본 크기 65%"), () => slider.Value = 0.65));
        var visible = new CheckBox { Content = T("화면에 펫 표시"), IsChecked = settings.Visible, Margin = new Thickness(3, 7, 3, 7) };
        visible.Click += (_, _) => SetVisible(visible.IsChecked == true);
        body.Children.Add(visible);
        var wander = new CheckBox { Content = T("느긋하게 산책하기"), IsChecked = settings.Wanders, Margin = new Thickness(3, 7, 3, 7) };
        wander.Click += (_, _) => { settings.Wanders = wander.IsChecked == true; SaveSettings(); };
        body.Children.Add(wander);
        if (preview != null) body.Children.Add(Text(T($"표정 미리보기 {Usage.Percent(preview)} · 실제 사용량이 아닙니다")));
        providerCards = new StackPanel();
        body.Children.Add(providerCards);
        body.Children.Add(Text(T("표정은 정상 조회된 한도 중 가장 낮은 잔여량 기준 · 2분마다 갱신"), 10));
        refreshButton = ActionButton(T("사용량 새로고침"), async () => await Refresh());
        body.Children.Add(refreshButton);
        body.Children.Add(ActionButton(T("닫기"), ClosePanel));
        body.Children.Add(ActionButton(T("펫 종료"), Quit));
        panel = new Window
        {
            Title = T($"{CharacterName} 사용량"), Width = 380, Height = Math.Min(780, screen.Height - 24),
            Topmost = true, ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize,
            Background = new SolidColorBrush(Color.FromRgb(255, 250, 243)),
            Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }
        };
        panel.Left = Math.Clamp(Left + Width / 2 - panel.Width / 2, screen.Left, Math.Max(screen.Left, screen.Right - panel.Width));
        panel.Top = Math.Clamp(Top - panel.Height - 8, screen.Top + 12, Math.Max(screen.Top + 12, screen.Bottom - panel.Height - 12));
        panel.Closed += (_, _) => { panel = null; providerCards = null; caption = null; refreshButton = null; };
        panel.KeyDown += (_, key) => { if (key.Key == Key.Escape) ClosePanel(); };
        panel.Deactivated += (_, _) => { if (!IsMouseOver) ClosePanel(); };
        UpdateCards();
        panel.Show();
        panel.Activate();
    }

    private void UpdateCards()
    {
        if (caption != null) caption.Text = T($"{CharacterName}의 에너지 · {Usage.Caption(Remaining)}");
        if (panel != null) panel.Title = T($"{CharacterName} 사용량");
        if (refreshButton != null) { refreshButton.IsEnabled = !refreshing && preview == null; refreshButton.Content = refreshing ? T("조회 중…") : T("사용량 새로고침"); }
        if (providerCards == null) return;
        providerCards.Children.Clear();
        foreach (var provider in providers)
        {
            var content = new StackPanel { Margin = new Thickness(12) };
            content.Children.Add(Text(T($"{provider.Name} · {Usage.Percent(provider.Remaining)} 남음"), 18));
            if (provider.Reading is { } reading)
            {
                foreach (var quota in reading.Windows)
                {
                    content.Children.Add(Text($"{T(quota.Title)} · {Usage.Percent(quota.Remaining)}"));
                    content.Children.Add(new ProgressBar { Minimum = 0, Maximum = 100, Value = quota.Remaining, Height = 6,
                        Margin = new Thickness(0, 4, 0, 4) });
                    if (quota.ResetsAt is { } reset) content.Children.Add(Text(T($"{reset.ToLocalTime().ToString("g", CultureInfo.GetCultureInfo(settings.Language == "ko" ? "ko-KR" : "en-US"))} 초기화"), 10));
                }
                content.Children.Add(Text(T($"{reading.FetchedAt.ToLocalTime().ToString("T", CultureInfo.GetCultureInfo(settings.Language == "ko" ? "ko-KR" : "en-US"))} 조회{(provider.Error == null ? "" : " · 이전 데이터")}"), 10));
            }
            if (provider.Error != null) content.Children.Add(Text(provider.Error));
            else if (provider.Reading == null) content.Children.Add(Text(preview != null ? T("미리보기 · 조회하지 않습니다") : refreshing ? T("조회 중…") : T("CLI 로그인 정보를 연결합니다.")));
            providerCards.Children.Add(new Border { Child = content, Background = Brushes.White,
                CornerRadius = new CornerRadius(12), Margin = new Thickness(0, 5, 0, 5),
                Opacity = provider.Error != null && provider.Reading != null ? 0.65 : 1 });
        }
    }

    private void ClosePanel()
    {
        var openPanel = panel;
        panel = null;
        openPanel?.Close();
    }
    private void Quit() => Close();
}
