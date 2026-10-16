using System;
using System.IO;
using System.Threading.Tasks;
using ChiikawaPet;

internal static class Program
{
    private static async Task<int> Main(string[] arguments)
    {
        if (arguments.Length != 1) return 2;
        string? session = null;
        FileStream? lease = null;
        try
        {
            session = UpdateApply.SessionDirectory(arguments[0]);
            lease = new FileStream(Path.Combine(session, "active.lock"), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
            await UpdateApply.Run(arguments[0]);
            return 0;
        }
        catch (Exception error)
        {
            try
            {
                if (session != null && lease != null)
                    File.WriteAllText(Path.Combine(session, "error"), error.GetType().Name + ": " + error.Message);
            }
            catch (Exception) { }
            return 1;
        }
        finally
        {
            if (session != null && lease != null)
            {
                try
                {
                    foreach (string package in Directory.EnumerateFiles(session, "ChiikawaPet-*-win-x64.*"))
                        File.Delete(package);
                }
                catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
            }
            lease?.Dispose();
        }
    }
}
