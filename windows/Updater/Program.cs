using System;
using System.IO;
using System.Threading.Tasks;
using ChiikawaPet;

internal static class Program
{
    private static async Task<int> Main(string[] arguments)
    {
        if (arguments.Length != 1) return 2;
        try
        {
            await UpdateApply.Run(arguments[0]);
            return 0;
        }
        catch (Exception error)
        {
            try
            {
                string session = UpdateApply.SessionDirectory(arguments[0]);
                File.WriteAllText(Path.Combine(session, "error"), error.GetType().Name + ": " + error.Message);
            }
            catch (Exception) { }
            return 1;
        }
    }
}
