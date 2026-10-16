using System;
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

    public void Validate()
    {
        if (Language is not ("en" or "ko")) Language = "en";
        if (Character is not ("chiikawa" or "hachiware" or "usagi" or "momonga")) Character = "chiikawa";
        if (!double.IsFinite(Scale) || Scale < 0.4 || Scale > 1.2) Scale = 0.65;
        if (X is double x && !double.IsFinite(x)) X = null;
        if (Y is double y && !double.IsFinite(y)) Y = null;
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
