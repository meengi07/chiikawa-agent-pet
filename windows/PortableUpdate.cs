using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace ChiikawaPet;

internal sealed class PortableUpdate
{
    internal const string InventoryName = ".chiikawa-managed-files.json";
    private readonly string target;
    private readonly string stage;
    private readonly string backup;
    private readonly HashSet<string> previous;
    private readonly HashSet<string> replacement;
    private readonly List<string> saved = new();
    private readonly List<string> placed = new();

    internal PortableUpdate(string target, string stage, string backup)
    {
        this.target = target;
        this.stage = stage;
        this.backup = backup;
        previous = ReadInventory(target);
        replacement = ReadInventory(stage);
        foreach (string path in Directory.EnumerateFiles(stage, "*", SearchOption.AllDirectories))
        {
            string relative = Path.GetRelativePath(stage, path).Replace('\\', '/');
            if (!replacement.Contains(relative)) throw new InvalidDataException("The update contains an unmanaged file.");
        }
        foreach (string relative in replacement)
        {
            string destination = Resolve(target, relative);
            if (Directory.Exists(destination) || (File.Exists(destination) && !previous.Contains(relative)))
                throw new IOException("An update file collides with an unrelated file. Move the portable app to its own folder.");
            var parent = Directory.GetParent(destination);
            while (parent != null && !parent.FullName.Equals(target, StringComparison.OrdinalIgnoreCase))
            {
                if (File.Exists(parent.FullName)) throw new IOException("An update folder collides with an existing file.");
                parent = parent.Parent;
            }
        }
    }

    private static HashSet<string> ReadInventory(string directory)
    {
        string path = Path.Combine(directory, InventoryName);
        if (!File.Exists(path) || new FileInfo(path).Length > 256 * 1024)
            throw new IOException("The portable app file inventory is missing. Extract the official ZIP into its own folder before updating.");
        using var document = JsonDocument.Parse(File.ReadAllBytes(path));
        if (document.RootElement.ValueKind != JsonValueKind.Array || document.RootElement.GetArrayLength() > 25000)
            throw new InvalidDataException("Invalid portable app file inventory.");
        var files = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in document.RootElement.EnumerateArray())
        {
            string relative = entry.GetString() ?? "";
            string full = Resolve(directory, relative);
            if (!files.Add(relative) || !File.Exists(full) || (File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Missing, duplicate, or linked managed app file.");
        }
        if (!files.Contains(InventoryName) || !files.Contains("ChiikawaPet.exe")) throw new InvalidDataException("Incomplete portable app file inventory.");
        return files;
    }

    private static string Resolve(string directory, string relative)
    {
        if (relative.Length == 0 || relative.Contains('\\') || relative.Contains(':') || relative.StartsWith('/'))
            throw new InvalidDataException("Unsafe managed app file path.");
        foreach (string part in relative.Split('/'))
            if (part.Length == 0 || part is "." or ".." || part.EndsWith('.') || part.EndsWith(' '))
                throw new InvalidDataException("Unsafe managed app file path.");
        string full = Path.GetFullPath(Path.Combine(directory, relative.Replace('/', Path.DirectorySeparatorChar)));
        if (!full.StartsWith(directory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Managed file escapes the app folder.");
        UpdateApply.RejectReparse(Path.GetDirectoryName(full)!);
        return full;
    }

    internal void Apply()
    {
        Directory.CreateDirectory(backup);
        foreach (string relative in previous)
        {
            string destination = Resolve(backup, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Move(Resolve(target, relative), destination);
            saved.Add(relative);
        }
        foreach (string relative in replacement)
        {
            string destination = Resolve(target, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Move(Resolve(stage, relative), destination);
            placed.Add(relative);
        }
    }

    internal void Rollback()
    {
        // Mapped executable images cannot be deleted; move them out before restoring the old files.
        foreach (string relative in placed)
        {
            string destination = Resolve(stage, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Move(Resolve(target, relative), destination);
        }
        foreach (string relative in saved)
        {
            string destination = Resolve(target, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Move(Resolve(backup, relative), destination);
        }
    }
}
