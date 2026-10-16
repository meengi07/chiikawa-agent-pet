using System;
using System.Linq;
using System.Text.RegularExpressions;

namespace ChiikawaPet;

internal static class Language
{
    public static string Current { get; set; } = "en";
    public static string T(string text) => Current == "ko" ? text : English(text);
    public static string English(string text)
    {
        var exact = Words.FirstOrDefault(pair => pair.Korean == text);
        if (exact.Korean != null) return exact.English;
        foreach (var (pattern, replacement) in Patterns)
            if (pattern.IsMatch(text)) { text = pattern.Replace(text, replacement); break; }
        foreach (var (korean, english) in Words) text = text.Replace(korean, english, StringComparison.Ordinal);
        return text;
    }
    private static readonly (string Korean, string English)[] Words =
    [
        ("업데이트하지 못했습니다. 네트워크와 앱 폴더 쓰기 권한을 확인하거나 공식 설치 파일로 다시 설치하세요.", "Update failed. Check your network and app-folder write access, or reinstall the official package."),
        ("업데이트하지 못했습니다. 이전 버전을 복원했습니다.", "Update failed. The previous version was restored."),
        ("자동 업데이트 꺼짐", "Automatic updates are off"),
        ("자동 업데이트는 Windows x64에서만 지원합니다.", "Automatic updates support Windows x64 only."),
        ("미리보기에서는 업데이트하지 않습니다.", "Updates are disabled in preview mode."),
        ("새 버전을 설치하고 펫을 다시 시작할까요?", "Install the new version and restart your pet?"),
        ("업데이트 다운로드 및 검증 중…", "Downloading and verifying update…"),
        ("업데이트를 확인하지 않았습니다", "Updates have not been checked"),
        ("업데이트 확인 중…", "Checking for updates…"),
        ("새 업데이트가 있습니다", "An update is available"),
        ("최신 버전입니다", "You’re up to date"),
        ("업데이트 확인…", "Check for Updates…"),
        ("자동 업데이트", "Automatic Updates"),
        ("Windows 터미널에서 codex login 후 새로고침하세요. Credential Manager 저장은 현재 지원하지 않습니다.", "Run codex login in a Windows terminal, then refresh. Credential Manager storage is not supported."),
        ("Claude 인증이 만료되었거나 사용량 권한이 없습니다. Claude Code에서 /login 후 다시 시도하세요.", "Claude authentication expired or lacks usage access. Use /login in Claude Code and retry."),
        ("펫 설정을 저장할 수 없습니다. %LOCALAPPDATA%\\ChiikawaPet 폴더의 쓰기 권한을 확인하세요.", "Cannot save settings. Check write access to %LOCALAPPDATA%\\ChiikawaPet."),
        ("펫 리소스 또는 설정을 읽을 수 없습니다. 실행 파일을 다시 압축 해제하고 설정 파일을 확인하세요.", "Cannot read pet resources or settings. Extract the app again and check its settings file."),
        ("Codex 인증이 만료되었습니다. Codex를 실행하거나 codex login 후 다시 시도하세요.", "Codex authentication expired. Run Codex or codex login and retry."),
        ("API 키는 구독 잔여량이 없습니다. codex login으로 ChatGPT 계정을 연결하세요.", "API keys have no subscription quota. Connect a ChatGPT account with codex login."),
        ("Claude 인증이 만료되었습니다. Claude Code에서 /login 후 새로고침하세요.", "Claude authentication expired. Use /login in Claude Code, then refresh."),
        ("Windows의 Claude Code에서 /login 후 새로고침하세요.", "Use /login in Claude Code on Windows, then refresh."),
        ("표정은 정상 조회된 한도 중 가장 낮은 잔여량 기준 · 2분마다 갱신", "Expression uses the lowest current quota · updates every 2 minutes"),
        ("실행 옵션: --preview 0~100 [--show-usage]", "Options: --preview 0–100 [--show-usage]"),
        ("로그인 키체인 접근이 필요합니다. 새로고침 버튼을 눌러 허용하세요.", "Keychain access is required. Click Refresh to authorize it."),
        ("아래 새로고침 버튼으로 연결 · 인증 정보는 이 Mac에만", "Use Refresh to connect · credentials stay on this Mac"),
        ("이미 실행 중입니다. 알림 영역의 펫 아이콘을 클릭하세요.", "Already running. Click the pet icon in the notification area."),
        ("사용량 서버에 연결할 수 없습니다. 네트워크를 확인하세요.", "Cannot reach the usage server. Check your network."),
        ("앱 실행 중 오류가 발생했습니다. 펫을 다시 실행하세요.", "An application error occurred. Restart the pet."),
        ("Claude Code에서 /login 후 새로고침하세요.", "Sign in with /login in Claude Code, then refresh."),
        ("사용량 조회 시간이 초과되었습니다. 다시 새로고침하세요.", "Usage request timed out. Refresh again."),
        ("클릭: 사용량 · 드래그: 이동 · 우클릭: 펫 종류", "Click: usage · drag: move · right-click: characters"),
        ("Codex의 ChatGPT 로그인 정보를 연결합니다.", "Connect your Codex ChatGPT login."),
        ("숨겨도 메뉴바에서 사용량과 펫을 확인할 수 있어요.", "Menu-bar controls stay available when hidden."),
        ("터미널에서 codex login 후 새로고침하세요.", "Run codex login in a terminal, then refresh."),
        ("클릭: 사용량 · 드래그: 이동 · 우클릭: 메뉴", "Click: usage · drag: move · right-click: menu"),
        ("Claude Code의 로그인 정보를 연결합니다.", "Connect your Claude Code login."),
        ("표정은 조회된 한도 중 가장 낮은 잔여량 기준", "Expression uses the lowest current quota"),
        ("표정 미리보기 · 실제 사용량이 아닙니다", "Expression preview · simulated usage"),
        ("사용량 응답에 유효한 한도가 없습니다.", "The usage response contains no valid quotas."),
        ("로그인 정보 연결 및 사용량 새로고침", "Connect accounts and refresh usage"),
        ("펫 크기를 기본값 65%로 재설정", "Reset pet size to 65%"),
        ("CLI 로그인 정보를 연결합니다.", "Connect your CLI login."),
        ("미리보기 · 조회하지 않습니다", "Preview · no account requests"),
        ("울먹… 잠깐 쉬었다 가자", "Sniff… Time for a break"),
        ("연결하면 기분을 알려줄게", "Connect to see how I feel"),
        ("사용량 새로고침 및 연결", "Refresh usage and connect"),
        ("사용량 새로고침 / 연결", "Refresh usage / connect"),
        ("이제 얼마 안 남았어…", "Not much left…"),
        ("화면 가운데로 데려오기", "Move to screen center"),
        ("와아! 아직 한가득!", "Yay! Plenty left!"),
        ("오늘도 같이 힘내자", "Let’s do our best today"),
        ("조금씩 아껴 쓰자…", "Let’s save a little…"),
        (" · 2분마다 갱신", " · updates every 2 minutes"),
        ("기본 크기 65%", "Default size 65%"),
        ("느긋하게 산책하기", "Gentle wandering"),
        (" · 이전 데이터", " · previous data"),
        ("Sonnet 주간", "Sonnet weekly"),
        ("화면에 펫 표시", "Show desktop pet"),
        ("65% (기본)", "65% (default)"),
        ("사용량 새로고침", "Refresh usage"),
        ("기본값 65%", "Default 65%"),
        ("Opus 주간", "Opus weekly"),
        ("첫 번째 한도", "Primary limit"),
        ("두 번째 한도", "Secondary limit"),
        ("치이카와 펫", "Chiikawa Pet"),
        ("펫 표시 중", "Pet visible"),
        ("사용량 보기", "Show usage"),
        ("조회 중…", "Refreshing…"),
        ("연결 필요", "Connect account"),
        ("치이카와", "Chiikawa"),
        ("하치와레", "Hachiware"),
        ("펫 크기", "Pet size"),
        ("펫 표시", "Show pet"),
        ("펫 숨김", "Pet hidden"),
        ("펫 종료", "Quit pet"),
        ("% 남음", "% left"),
        ("펫 종류", "Character"),
        ("새로고침", "Refresh"),
        ("우사기", "Usagi"),
        ("모몽가", "Momonga"),
        ("5시간", "5 hours"),
        ("종료", "Quit"),
        ("닫기", "Close"),
        ("주간", "Weekly"),
    ];
    private static readonly (Regex Pattern, string Replacement)[] Patterns =
    [
        (new Regex("^(.+)의 에너지 · (.+)$"), "$1’s energy · $2"),
        (new Regex("^(.+)의 에너지$", RegexOptions.CultureInvariant), "$1’s energy"),
        (new Regex("^(.+) 펫$", RegexOptions.CultureInvariant), "$1 pet"),
        (new Regex("^(.+) 사용량$", RegexOptions.CultureInvariant), "$1 usage"),
        (new Regex("^(.+) · 사용량 보기$", RegexOptions.CultureInvariant), "$1 · Show usage"),
        (new Regex("^(.+) 선택$", RegexOptions.CultureInvariant), "Select $1"),
        (new Regex("^(.+) 초기화$", RegexOptions.CultureInvariant), "Resets $1"),
        (new Regex("^(.+) 조회(.*)$", RegexOptions.CultureInvariant), "Fetched $1$2"),
        (new Regex("^펫 크기 (.+)$", RegexOptions.CultureInvariant), "Pet size $1"),
        (new Regex("^(.+) 남음$", RegexOptions.CultureInvariant), "$1 left"),
        (new Regex("^표정 미리보기 (.+) · 실제 사용량이 아닙니다$", RegexOptions.CultureInvariant), "Expression preview $1 · simulated usage"),
        (new Regex("^(.+) 로그인 파일을 읽을 권한이 없습니다.$", RegexOptions.CultureInvariant), "Access denied reading $1 credentials."),
        (new Regex("^(.+) 로그인 파일을 읽을 수 없습니다.$", RegexOptions.CultureInvariant), "Cannot read $1 credentials."),
        (new Regex("^(.+) 인증이 만료되었거나 사용량 권한이 없습니다. (.+)$", RegexOptions.CultureInvariant), "$1 authentication expired or lacks usage access. $2"),
        (new Regex("^사용량 서버 오류 \\(HTTP ([0-9]+)\\). 나중에 새로고침하세요.$", RegexOptions.CultureInvariant), "Usage server error (HTTP $1). Refresh later."),
        (new Regex("^([0-9]+)일 한도$", RegexOptions.CultureInvariant), "$1-day limit"),
        (new Regex("^([0-9]+)시간$", RegexOptions.CultureInvariant), "$1 hours"),
        (new Regex("^([0-9]+)초 한도$", RegexOptions.CultureInvariant), "$1-second limit"),
        (new Regex("^(.+), 잔여량 (.+)퍼센트. (.+)$", RegexOptions.CultureInvariant), "$1, $2 percent remaining. $3"),
        (new Regex("^(.+), 잔여량을 아직 몰라요. (.+)$", RegexOptions.CultureInvariant), "$1, quota unknown. $2"),
    ];
}
