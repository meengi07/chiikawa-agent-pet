Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

!ifndef VERSION
!error "Pass VERSION, PAYLOAD, OUTPUT and ARTWORK to makensis."
!endif
!ifndef ARTWORK
!error "Pass ARTWORK to makensis."
!endif
Name "Chiikawa Pet ${VERSION}"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\ChiikawaPet"
RequestExecutionLevel user
SetCompressor /SOLID lzma
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "Chiikawa Agent Pet"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "Chiikawa Agent Pet Installer"
VIAddVersionKey "LegalCopyright" "Copyright (c) 2026 meengi07"
BrandingText "Chiikawa Agent Pet"

!define MUI_ICON "${ARTWORK}\AppIcon.ico"
!define MUI_UNICON "${ARTWORK}\AppIcon.ico"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_RIGHT
!define MUI_HEADERIMAGE_BITMAP "${ARTWORK}\installer-header.bmp"
!define MUI_HEADERIMAGE_UNBITMAP "${ARTWORK}\installer-header.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP "${ARTWORK}\installer-sidebar.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "${ARTWORK}\installer-sidebar.bmp"
!define MUI_BGCOLOR "FFF9EF"
!define MUI_TEXTCOLOR "53494A"
!define MUI_WELCOMEFINISHPAGE_INNERCOLOR "FFF9EF"
!define MUI_INSTFILESPAGE_COLORS "53494A FFF9EF"
!define MUI_ABORTWARNING
!define MUI_UNABORTWARNING

!define MUI_WELCOMEPAGE_TITLE "$(PetWelcomeTitle)"
!define MUI_WELCOMEPAGE_TEXT "$(PetWelcomeText)"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "$(PetFinishTitle)"
!define MUI_FINISHPAGE_TEXT "$(PetFinishText)"
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchPet
!define MUI_FINISHPAGE_RUN_TEXT "$(PetLaunchText)"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "$(PetRemovedTitle)"
!define MUI_FINISHPAGE_TEXT "$(PetRemovedText)"
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "Korean"

LangString PetWelcomeTitle ${LANG_ENGLISH} "A little companion for your desktop"
LangString PetWelcomeTitle ${LANG_KOREAN} "데스크톱에서 함께할 작은 친구"
LangString PetWelcomeText ${LANG_ENGLISH} "Meet Chiikawa, Hachiware, Usagi and Momonga on your desktop.$\r$\n$\r$\nClick your pet or its tray icon to see remaining Claude and Codex quota. First sign in with the Windows Claude Code or Codex CLI.$\r$\n$\r$\nInstalls for your account only; no administrator access is needed.$\r$\n$\r$\nClose any running pet, then choose Install."
LangString PetWelcomeText ${LANG_KOREAN} "치이카와, 하치와레, 우사기, 모몽가를 데스크톱에서 만나 보세요.$\r$\n$\r$\n펫이나 알림 영역 아이콘을 클릭하면 Claude와 Codex의 남은 사용량을 볼 수 있습니다. 먼저 Windows의 Claude Code 또는 Codex CLI에서 로그인하세요.$\r$\n$\r$\n내 계정에만 설치하며 관리자 권한은 필요하지 않습니다.$\r$\n$\r$\n실행 중인 펫을 종료한 뒤 설치를 눌러 주세요."
LangString PetFinishTitle ${LANG_ENGLISH} "Your desktop companion is ready"
LangString PetFinishTitle ${LANG_KOREAN} "데스크톱 친구를 만날 준비가 됐어요"
LangString PetFinishText ${LANG_ENGLISH} "Chiikawa Pet ${VERSION} is ready.$\r$\n$\r$\nClick the pet for Claude / Codex quota.$\r$\nDrag to move; the tray icon opens settings."
LangString PetFinishText ${LANG_KOREAN} "Chiikawa Pet ${VERSION} 설치를 마쳤어요.$\r$\n$\r$\n펫 클릭: Claude·Codex 잔여량 확인$\r$\n드래그: 이동 / 알림 영역: 설정"
LangString PetLaunchText ${LANG_ENGLISH} "Launch Chiikawa Pet"
LangString PetLaunchText ${LANG_KOREAN} "Chiikawa Pet 실행"
LangString PetRemovedTitle ${LANG_ENGLISH} "See you next time!"
LangString PetRemovedTitle ${LANG_KOREAN} "다음에 또 만나요!"
LangString PetRemovedText ${LANG_ENGLISH} "Chiikawa Pet has been removed from your Windows account.$\r$\n$\r$\nYour pet preferences and Claude Code / Codex CLI sign-in files have been kept. Reinstall any time to welcome your companion back.$\r$\n$\r$\nChoose Finish to close."
LangString PetRemovedText ${LANG_KOREAN} "현재 Windows 계정에서 Chiikawa Pet을 제거했습니다.$\r$\n$\r$\n펫 설정과 Claude Code / Codex CLI 로그인 파일은 그대로 보존했습니다. 언제든 다시 설치해 친구를 만나세요.$\r$\n$\r$\n마침을 눌러 닫아 주세요."
LangString PetMustClose ${LANG_ENGLISH} "Close the running Chiikawa Pet before installing or uninstalling."
LangString PetMustClose ${LANG_KOREAN} "설치하거나 제거하기 전에 실행 중인 Chiikawa Pet을 종료하세요."

!macro RequirePetClosed
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "Local\ChiikawaAgentPet") p.r0'
  ${If} $0 P<> 0
    System::Call 'kernel32::CloseHandle(p r0)'
    IfSilent +2
    MessageBox MB_OK|MB_ICONSTOP "$(PetMustClose)"
    SetErrorLevel 1
    Abort
  ${EndIf}
!macroend

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "This package requires 64-bit Windows."
    Abort
  ${EndIf}
  SetRegView 64
  SetShellVarContext current
  StrCpy $INSTDIR "$LOCALAPPDATA\Programs\ChiikawaPet"
  System::Call 'kernel32::GetUserDefaultUILanguage() i.r0'
  StrCpy $LANGUAGE ${LANG_ENGLISH}
  ${If} $0 = ${LANG_KOREAN}
    StrCpy $LANGUAGE ${LANG_KOREAN}
  ${EndIf}
  !insertmacro RequirePetClosed
FunctionEnd

Function un.onInit
  SetRegView 64
  SetShellVarContext current
  System::Call 'kernel32::GetUserDefaultUILanguage() i.r0'
  StrCpy $LANGUAGE ${LANG_ENGLISH}
  ${If} $0 = ${LANG_KOREAN}
    StrCpy $LANGUAGE ${LANG_KOREAN}
  ${EndIf}
  !insertmacro RequirePetClosed
FunctionEnd

Function LaunchPet
  SetOutPath "$INSTDIR"
  Exec '"$INSTDIR\ChiikawaPet.exe"'
FunctionEnd

Section "Install"
  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD}\*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Chiikawa Pet"
  CreateShortCut "$SMPROGRAMS\Chiikawa Pet\Chiikawa Pet.lnk" "$INSTDIR\ChiikawaPet.exe"
  CreateShortCut "$SMPROGRAMS\Chiikawa Pet\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet" "DisplayName" "Chiikawa Pet"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet" "DisplayVersion" "${VERSION}"
  ; Preserve a quoted executable path for Windows' uninstall entry.
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet" "DisplayIcon" '"$INSTDIR\ChiikawaPet.exe",0'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetRegView 64
  SetShellVarContext current
  ; The installer has no directory picker: it owns only this fixed app folder.
  StrCpy $INSTDIR "$LOCALAPPDATA\Programs\ChiikawaPet"
  RMDir /r "$INSTDIR"
  Delete "$SMPROGRAMS\Chiikawa Pet\Chiikawa Pet.lnk"
  Delete "$SMPROGRAMS\Chiikawa Pet\Uninstall.lnk"
  RMDir "$SMPROGRAMS\Chiikawa Pet"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet"
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "ChiikawaAgentPet"
  ${If} $0 == '"$INSTDIR\ChiikawaPet.exe"'
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "ChiikawaAgentPet"
  ${EndIf}
  ; Preferences and CLI credentials are stored elsewhere and are preserved.
SectionEnd
