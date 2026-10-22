using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace ChiikawaPet;

internal sealed record UsageCredential(string Token, string? AccountID, string? Email, string? UserID,
    string? Plan, string AuthSource, string Fingerprint, string? AccessEmail = null);
internal sealed record ClaudeIdentity(string AccountID, string? Email, string? OrganizationID, string? Plan);

internal static class UsageCredentials
{
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly UnicodeEncoding Utf16 = new(false, false, true);

    internal static async Task<UsageCredential> Read(UsageAccount account, DateTimeOffset now)
    {
        try
        {
            if (account.Provider is not ("Claude" or "Codex")) throw new InvalidOperationException("지원하지 않는 사용량 제공자입니다.");
            if (!Path.IsPathFullyQualified(account.Directory)) throw new InvalidOperationException("로그인 홈은 명시적인 절대 경로여야 합니다.");
            var path = account.CredentialFile ?? Path.Combine(account.Directory,
                account.Provider == "Claude" ? ".credentials.json" : "auth.json");
            string? json = null;
            InvalidOperationException? fileFailure = null;
            try { json = await ReadLimited(path); }
            catch (Exception error) when ((error is IOException or UnauthorizedAccessException)
                && account.Provider == "Claude" && account.VaultFile != null)
            { fileFailure = new InvalidOperationException("cswap 세션의 로그인 파일을 읽을 수 없습니다."); }
            if (json != null)
            {
                try
                {
                    if (account.CredentialFileIsBase64) json = DecodeVault(json);
                    return Parse(account, json, now, account.CredentialFileIsBase64 ? "cswap vault (read-only)" : "CLI file (read-only)");
                }
                catch (UsageIdentityException) { throw; }
                catch (InvalidOperationException error) when (account.Provider == "Claude" && account.VaultFile != null)
                { fileFailure = error; }
            }
            if (account.Provider == "Claude" && account.VaultFile != null)
            {
                var encoded = await ReadLimited(account.VaultFile);
                if (encoded != null)
                {
                    json = DecodeVault(encoded);
                    return Parse(account, json, now, "cswap vault (read-only)");
                }
                if (fileFailure != null) throw fileFailure;
            }
            if (account.Provider == "Codex" && account.UseCredentialManager)
            {
                if (IsWsl(account.Directory))
                    throw new InvalidOperationException("WSL 홈은 해당 배포판의 auth.json만 읽습니다. Linux keyring은 Windows Credential Manager와 공유되지 않습니다.");
                json = ReadCodexKeyring(account.Directory);
                if (json != null) return Parse(account, json, now, "Windows Credential Manager (Codex, read-only)");
            }
            throw new InvalidOperationException(Usage.LoginMessage(account.Provider));
        }
        catch (UnauthorizedAccessException) { throw new InvalidOperationException("선택한 로그인 파일을 읽을 권한이 없습니다."); }
        catch (IOException) { throw new InvalidOperationException("선택한 로그인 파일을 읽을 수 없습니다. WSL 경로라면 배포판과 공유 경로를 확인하세요."); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or DecoderFallbackException)
        { throw new InvalidOperationException("선택한 로그인 경로 또는 파일 인코딩이 올바르지 않습니다."); }
    }

    internal static UsageCredential Parse(UsageAccount account, string json, DateTimeOffset now, string authSource)
    {
        var (token, storedAccount) = Usage.ParseCredentials(account.Provider, json, now);
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            string? email = null;
            string? accessEmail = null;
            string? userID = null;
            string? plan = null;
            if (account.Provider == "Claude")
            {
                var oauth = Usage.Object(root, "claudeAiOauth")!.Value;
                plan = Usage.Text(oauth, "subscriptionType");
                var tier = Usage.Text(oauth, "rateLimitTier");
                if (!string.IsNullOrEmpty(tier)) plan = plan == null ? tier : plan + " · " + tier;
            }
            else
            {
                var tokens = Usage.Object(root, "tokens")!.Value;
                var access = Jwt(token, now, true);
                var idToken = Usage.Text(tokens, "id_token");
                var identity = idToken == null ? null : Jwt(idToken, now, false);
                if (access is { } accessClaims)
                {
                    var accessProfile = Usage.Object(accessClaims, "https://api.openai.com/profile");
                    accessEmail = Usage.Text(accessClaims, "email")
                        ?? (accessProfile is { } profileClaims ? Usage.Text(profileClaims, "email") : null);
                }
                foreach (var claims in new[] { access, identity })
                {
                    if (claims is not { } payload) continue;
                    var auth = Usage.Object(payload, "https://api.openai.com/auth");
                    var profile = Usage.Object(payload, "https://api.openai.com/profile");
                    var claimAccount = auth is { } scoped ? Usage.Text(scoped, "chatgpt_account_id") : null;
                    var claimUser = auth is { } user ? Usage.Text(user, "chatgpt_user_id") ?? Usage.Text(user, "user_id") : null;
                    var claimEmail = Usage.Text(payload, "email") ?? (profile is { } named ? Usage.Text(named, "email") : null);
                    if (claimAccount != null && !Equal(claimAccount, storedAccount)) throw new UsageIdentityException();
                    if (email != null && claimEmail != null && !Equal(email, claimEmail)) throw new UsageIdentityException();
                    if (userID != null && claimUser != null && !Equal(userID, claimUser)) throw new UsageIdentityException();
                    email ??= claimEmail;
                    userID ??= claimUser;
                    plan ??= auth is { } subscription ? Usage.Text(subscription, "chatgpt_plan_type") : null;
                }
                VerifyIdentity(account, storedAccount, email, null, userID);
            }
            var fingerprint = Usage.Hash(account.Provider + "\0" + token + "\0" + storedAccount + "\0" + email + "\0" + userID);
            return new UsageCredential(token, storedAccount, email, userID, plan, authSource, fingerprint, accessEmail);
        }
        catch (JsonException) { throw new InvalidOperationException(Usage.LoginMessage(account.Provider)); }
        catch (ArgumentOutOfRangeException) { throw new InvalidOperationException("Codex 인증의 만료 시각이 올바르지 않습니다."); }
    }

    private static JsonElement? Jwt(string token, DateTimeOffset now, bool enforceExpiry)
    {
        var parts = token.Split('.');
        if (parts.Length == 1) return null;
        if (parts.Length != 3 || parts.Any(string.IsNullOrEmpty)) throw new InvalidOperationException("Codex 인증 토큰 형식이 올바르지 않습니다.");
        try
        {
            var encoded = parts[1].Replace('-', '+').Replace('_', '/');
            encoded = encoded.PadRight((encoded.Length + 3) / 4 * 4, '=');
            var bytes = Convert.FromBase64String(encoded);
            using var document = JsonDocument.Parse(bytes);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new InvalidOperationException("Codex 인증 토큰 형식이 올바르지 않습니다.");
            var expiry = Usage.Number(root, "exp");
            if (enforceExpiry && expiry is double seconds && seconds <= now.ToUnixTimeSeconds())
                throw new InvalidOperationException("Codex 인증이 만료되었습니다. 해당 CLI 또는 xswap에서 로그인 상태를 갱신하세요.");
            return root.Clone();
        }
        catch (FormatException) { throw new InvalidOperationException("Codex 인증 토큰 형식이 올바르지 않습니다."); }
        catch (JsonException) { throw new InvalidOperationException("Codex 인증 토큰 형식이 올바르지 않습니다."); }
    }

    internal static ClaudeIdentity ParseClaudeProfile(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var account = Usage.Object(root, "account") ?? throw new InvalidOperationException("Claude 프로필 신원을 확인할 수 없습니다.");
            var id = Usage.Text(account, "uuid");
            if (string.IsNullOrWhiteSpace(id)) throw new InvalidOperationException("Claude 프로필 신원을 확인할 수 없습니다.");
            var organization = Usage.Object(root, "organization");
            var org = organization is { } workspace ? Usage.Text(workspace, "uuid") : null;
            var plan = organization is { } subscription ? Usage.Text(subscription, "rate_limit_tier")
                ?? Usage.Text(subscription, "organization_type") : null;
            return new ClaudeIdentity(id, Usage.Text(account, "email") ?? Usage.Text(account, "email_address"), org, plan);
        }
        catch (JsonException) { throw new InvalidOperationException("Claude 프로필 신원을 확인할 수 없습니다."); }
    }

    internal static void VerifyIdentity(UsageAccount expected, string? accountID, string? email,
        string? organizationID = null, string? userID = null)
    {
        if ((expected.ExpectedAccountID != null && !Equal(expected.ExpectedAccountID, accountID))
            || (expected.ExpectedOrganizationID != null && !Equal(expected.ExpectedOrganizationID, organizationID))
            || (expected.ExpectedEmail != null && !Equal(expected.ExpectedEmail, email))
            || (expected.ExpectedUserID != null && !Equal(expected.ExpectedUserID, userID))) throw new UsageIdentityException();
    }
    internal static bool Equal(string? first, string? second) => string.Equals(first, second, StringComparison.OrdinalIgnoreCase);
    internal static bool IsWsl(string path)
    {
        path = path.Replace('/', '\\');
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) path = @"\\" + path[8..];
        return path.StartsWith(@"\\wsl$\", StringComparison.OrdinalIgnoreCase)
            || path.StartsWith(@"\\wsl.localhost\", StringComparison.OrdinalIgnoreCase);
    }

    internal static async Task<string?> ReadLimited(string path, int maximumBytes = 262144)
    {
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
                4096, FileOptions.Asynchronous);
            if (file.Length > maximumBytes) throw new InvalidOperationException("선택한 사용량/로그인 파일이 너무 큽니다.");
            using var buffer = new MemoryStream((int)file.Length);
            var bytes = new byte[4096];
            int count;
            while ((count = await file.ReadAsync(bytes).ConfigureAwait(false)) > 0)
            {
                if (buffer.Length + count > maximumBytes) throw new InvalidOperationException("선택한 사용량/로그인 파일이 너무 큽니다.");
                buffer.Write(bytes, 0, count);
            }
            return Utf8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length).TrimStart('\uFEFF');
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }
    private static string DecodeVault(string encoded)
    {
        try
        {
            var bytes = Convert.FromBase64String(encoded.Trim());
            return Utf8.GetString(bytes);
        }
        catch (Exception error) when (error is FormatException or DecoderFallbackException)
        { throw new InvalidOperationException("cswap 저장 자격 증명을 읽을 수 없습니다. cswap run으로 해당 계정을 갱신하세요."); }
    }

    // Codex storage.rs + keyring-rs 3.6 windows.rs: cli|SHA256(canonical-home)[..16].Codex Auth; password is UTF-16LE.
    internal static string CodexTarget(string canonicalHome) => "cli|" + Usage.Hash(canonicalHome)[..16] + ".Codex Auth";
    private static string? ReadCodexKeyring(string directory)
    {
        if (!OperatingSystem.IsWindows()) throw new InvalidOperationException("Credential Manager는 Windows에서만 지원됩니다.");
        var canonical = CanonicalHome(directory);
        var target = CodexTarget(canonical);
        if (!CredRead(target, 1, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == 1168) return null;
            throw new InvalidOperationException($"Codex Credential Manager 항목을 읽을 수 없습니다 (Windows {error}).");
        }
        try
        {
            var credential = Marshal.PtrToStructure<NativeCredential>(pointer);
            if (credential.Type != 1 || credential.CredentialBlobSize is 0 or > 262144 || credential.CredentialBlobSize % 2 != 0
                || credential.CredentialBlob == IntPtr.Zero || Marshal.PtrToStringUni(credential.TargetName) != target)
                throw new InvalidOperationException("Codex Credential Manager 항목 형식이 올바르지 않습니다.");
            var bytes = new byte[credential.CredentialBlobSize];
            try
            {
                Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
                return Utf16.GetString(bytes);
            }
            finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); }
        }
        finally { CredFree(pointer); }
    }
    private static string CanonicalHome(string directory)
    {
        using var handle = CreateFile(directory, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid) return directory;
        var path = new StringBuilder(32768);
        var length = GetFinalPathNameByHandle(handle, path, (uint)path.Capacity, 0);
        if (length == 0 || length >= path.Capacity) throw new InvalidOperationException("Codex 홈의 정규 경로를 확인할 수 없습니다.");
        return path.ToString();
    }

    internal static UsageAccount[] DiscoverSaved(List<string> warnings, bool useCredentialManager)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var claudeRoot = Path.Combine(home, ".claude-swap-backup");
        var codexRoots = new List<string>();
        var configured = Environment.GetEnvironmentVariable("XSWAP_HOME");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            try { codexRoots.Add(Usage.ExpandDirectory(configured, home)); }
            catch (Exception error) when (error is ArgumentException or NotSupportedException)
            { warnings.Add("XSWAP_HOME 경로가 올바르지 않아 저장 계정을 검색하지 않았습니다."); }
        }
        else
        {
            var native = Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if (string.IsNullOrWhiteSpace(native) || !Path.IsPathFullyQualified(native))
                native = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            codexRoots.Add(Path.Combine(native, "codex-swap"));
            var xdg = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
            if (!string.IsNullOrWhiteSpace(xdg) && Path.IsPathFullyQualified(xdg))
                codexRoots.Add(Path.Combine(xdg, "codex-swap"));
        }
        var accounts = new List<UsageAccount>();
        ReadRegistry(Path.Combine(claudeRoot, "sequence.json"), "cswap", warnings, json =>
            accounts.AddRange(ParseClaudeSaved(json, claudeRoot, warnings)));
        foreach (var root in codexRoots.DistinctBy(Usage.NormalizeSourcePath))
            ReadRegistry(Path.Combine(root, "accounts.json"), "xswap", warnings, json =>
                accounts.AddRange(ParseCodexSaved(json, root, warnings, useCredentialManager)));
        return accounts.ToArray();
    }

    private static void ReadRegistry(string path, string tool, List<string> warnings, Action<string> consume)
    {
        try
        {
            var json = ReadLimited(path).GetAwaiter().GetResult();
            if (json != null) consume(json);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException
            or JsonException or ArgumentException)
        { warnings.Add(tool + " 저장 계정 목록을 읽을 수 없거나 지원하지 않는 형식입니다. 원본 파일은 변경하지 않았습니다."); }
    }

    internal static UsageAccount[] ParseClaudeSaved(string json, string root, List<string> warnings)
    {
        using var document = JsonDocument.Parse(json);
        var saved = Usage.Object(document.RootElement, "accounts") ?? throw new InvalidOperationException();
        var accounts = new List<UsageAccount>();
        foreach (var slot in saved.EnumerateObject().OrderBy(slot => slot.Name, StringComparer.Ordinal))
        {
            try
            {
                var email = Usage.Text(slot.Value, "email");
                var id = Usage.Text(slot.Value, "uuid");
                var org = Usage.Text(slot.Value, "organizationUuid");
                if (slot.Name.Length == 0 || !slot.Name.All(char.IsAsciiDigit) || !SafeComponent(email)
                    || !Guid.TryParse(id, out _) || !Guid.TryParse(org, out _)) throw new InvalidOperationException();
                var slug = new string(email!.Normalize(NormalizationForm.FormC).Select(character =>
                    char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-' ? character : '_').ToArray());
                var directory = Path.Combine(root, "sessions", slot.Name + "-" + slug);
                var label = Usage.Text(slot.Value, "organizationName");
                accounts.Add(new UsageAccount("cswap:" + Usage.Hash(root + "\0" + id + "\0" + org), "Claude",
                    (string.IsNullOrWhiteSpace(label) ? "cswap " + slot.Name : label) + " · " + email, directory)
                {
                    ExpectedAccountID = id, ExpectedOrganizationID = org, ExpectedEmail = email,
                    VaultFile = Path.Combine(root, "credentials", ".creds-" + slot.Name + "-" + email + ".enc"),
                    SwapCacheFile = Path.Combine(root, "cache", "usage.json")
                });
            }
            catch (InvalidOperationException) { warnings.Add("cswap 계정 한 개에 안전하게 검증할 수 있는 계정/조직 신원이 없어 제외했습니다."); }
        }
        return accounts.ToArray();
    }

    internal static UsageAccount[] ParseCodexSaved(string json, string root, List<string> warnings, bool useCredentialManager = false)
    {
        using var document = JsonDocument.Parse(json);
        var registry = document.RootElement;
        if (Usage.Number(registry, "schemaVersion") != 1 || ResolveSavedHome(Usage.Text(registry, "mainHome"), root) == null)
            throw new InvalidOperationException();
        var accounts = new List<UsageAccount>();
        var slots = new HashSet<double>();
        foreach (var saved in Usage.Array(registry, "accounts"))
        {
            try
            {
                var number = Usage.Number(saved, "number");
                var directory = ResolveSavedHome(Usage.Text(saved, "home"), root);
                var identity = Usage.Object(saved, "identity");
                if (number == null || number <= 0 || number > uint.MaxValue || number != Math.Floor(number.Value) || !slots.Add(number.Value)
                    || directory == null || identity == null) throw new InvalidOperationException();
                var id = Usage.Text(identity.Value, "accountId");
                var email = Usage.Text(identity.Value, "email");
                var user = Usage.Text(identity.Value, "userId");
                if (!SafeComponent(id) || (!SafeComponent(email) && !SafeComponent(user))) throw new InvalidOperationException();
                var alias = Usage.Text(saved, "alias");
                accounts.Add(new UsageAccount("xswap:" + Usage.Hash(root + "\0" + id + "\0" + (user ?? email)), "Codex",
                    (string.IsNullOrWhiteSpace(alias) ? "xswap " + number : alias) + " · " + (email ?? user), directory)
                { ExpectedAccountID = id, ExpectedEmail = email, ExpectedUserID = user, UseCredentialManager = useCredentialManager });
            }
            catch (InvalidOperationException) { warnings.Add("xswap 계정 한 개의 홈 또는 소유자 신원을 검증할 수 없어 제외했습니다."); }
        }
        return accounts.ToArray();
    }

    private static bool SafeComponent(string? text) => !string.IsNullOrWhiteSpace(text) && text.Length <= 320
        && !text.Any(character => char.IsControl(character) || char.IsWhiteSpace(character) || "/\\|:<>\"?*".Contains(character));
    private static string? ResolveSavedHome(string? path, string root)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Contains('\0')) return null;
        if (Path.IsPathFullyQualified(path)) return path;
        if (!path.StartsWith('/') || !IsWsl(root)) return null;
        var normalizedRoot = Usage.NormalizeSourcePath(root)!;
        var segments = normalizedRoot.Split('\\', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length < 2 || path.Split('/').Any(segment => segment == "..")) return null;
        return "\\\\" + segments[0] + "\\" + segments[1] + "\\" + path.TrimStart('/').Replace('/', '\\');
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeCredential
    {
        public uint Flags, Type;
        public IntPtr TargetName, Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes, TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
}
