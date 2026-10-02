; 參考 YourDesk 的每位使用者 NSIS 安裝流程，使用 FilmDevelop 的獨立產品識別。
Unicode true
RequestExecutionLevel user
ManifestSupportedOS Win10
ManifestDPIAware true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!include "FileFunc.nsh"

!define PRODUCT_KEY "Software\FilmDevelop"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\FilmDevelop"
!define PRODUCT_ID "person.vader.FilmDevelop.Windows"

Name "FilmDevelop"
Caption "FilmDevelop 安裝程式"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\FilmDevelop"
InstallDirRegKey HKCU "${PRODUCT_KEY}" "InstallDir"
SetCompressor /SOLID lzma
SetCompressorDictSize 32
SetOverwrite on
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "${NUMERIC_VERSION}"
VIAddVersionKey /LANG=1028 "ProductName" "FilmDevelop"
VIAddVersionKey /LANG=1028 "FileDescription" "FilmDevelop 安裝程式"
VIAddVersionKey /LANG=1028 "FileVersion" "${DISPLAY_VERSION}"
VIAddVersionKey /LANG=1028 "ProductVersion" "${DISPLAY_VERSION}"
VIAddVersionKey /LANG=1028 "CompanyName" "VaderChen"
VIAddVersionKey /LANG=1028 "LegalCopyright" "Copyright 2026 VaderChen"

!define MUI_ICON "${ICON_FILE}"
!define MUI_UNICON "${ICON_FILE}"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TEXT "此精靈將安裝 FilmDevelop ${DISPLAY_VERSION}。$\r$\n$\r$\n適用於 Windows 10／11 x64，安裝於目前使用者帳戶。$\r$\n$\r$\n缺少 Microsoft Visual C++ x64 執行環境時，將從 Microsoft 下載並安裝；Windows 可能要求管理員確認。首次啟動若缺少 WebView2 Runtime，也會提示安裝。"
!define MUI_FINISHPAGE_RUN "$INSTDIR\FilmDevelop.exe"
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!define MUI_FINISHPAGE_RUN_TEXT "啟動 FilmDevelop"
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\README.txt"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!define MUI_FINISHPAGE_SHOWREADME_TEXT "開啟使用說明"
!define MUI_DIRECTORYPAGE_TEXT_TOP "請選擇空資料夾，或先前由 FilmDevelop 安裝程式建立的資料夾。程式預設只安裝於目前使用者帳戶。"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "TradChinese"

!macro StopWithError CODE TEXT
 SetErrorLevel ${CODE}
 IfSilent +2 0
 MessageBox MB_OK|MB_ICONSTOP "${TEXT}"
 Abort
!macroend

!macro CheckFileClosed FILE ID
retry_${ID}:
 IfFileExists "$INSTDIR\${FILE}" 0 done_${ID}
 System::Call 'kernel32::CreateFileW(w "$INSTDIR\${FILE}", i 0x40000000, i 0, p 0, i 3, i 0, p 0) p.r0'
 ${If} $0 == -1
  IfSilent 0 +3
   SetErrorLevel 2
   Abort
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "無法寫入 $INSTDIR\${FILE}。$\r$\n請關閉 FilmDevelop 及正在使用此檔案的程式，並確認資料夾可寫入，再按「重試」。" IDRETRY retry_${ID}
  SetErrorLevel 2
  Abort
 ${EndIf}
 System::Call 'kernel32::CloseHandle(p r0)'
done_${ID}:
!macroend

; 安裝、檔案占用檢查、解除安裝共用同一份建置清單。
!include "${PAYLOAD_INCLUDE}"

Function .onInit
 SetShellVarContext current
 SetRegView 64
 ${IfNot} ${IsNativeAMD64}
  !insertmacro StopWithError 4 "此安裝程式僅適用於 Windows x64（AMD64），不支援 x86 或 ARM64。"
 ${EndIf}
 ${IfNot} ${AtLeastWin10}
  !insertmacro StopWithError 4 "FilmDevelop 需要 Windows 10 或更新版本。"
 ${EndIf}
 ; 避免兩個安裝程序同時更新相同產品；作業系統會在程序結束時釋放 Handle。
 System::Call 'kernel32::CreateMutexW(p 0, i 0, w "Local\FilmDevelop.Installer") p.r0 ?e'
 Pop $1
 ${If} $0 == 0
 ${OrIf} $1 == 183
  !insertmacro StopWithError 2 "另一個 FilmDevelop 安裝或解除安裝程序正在執行。"
 ${EndIf}
FunctionEnd

Function CheckInstallDirectory
 ${GetRoot} "$INSTDIR" $0
 ${If} $0 == ""
 ${OrIf} $INSTDIR == $0
 ${OrIf} $INSTDIR == "$0\"
  SetErrors
  Return
 ${EndIf}
 ReadINIStr $0 "$INSTDIR\.filmdevelop-installed.ini" "Install" "Product"
 ${If} $0 == "${PRODUCT_ID}"
  ClearErrors
  Return
 ${EndIf}
 ; 新安裝只能使用空目錄；舊安裝必須有本產品的標記，避免覆蓋其他資料。
 ClearErrors
 FindFirst $0 $1 "$INSTDIR\*.*"
 ${If} ${Errors}
  ClearErrors
  Return
 ${EndIf}
check_next:
 ${If} $1 != "."
 ${AndIf} $1 != ".."
 ${AndIf} $1 != ""
  FindClose $0
  SetErrors
  Return
 ${EndIf}
 ClearErrors
 FindNext $0 $1
 IfErrors check_empty check_next
check_empty:
 FindClose $0
 ClearErrors
FunctionEnd

Function .onVerifyInstDir
 Call CheckInstallDirectory
 ${If} ${Errors}
  Abort
 ${EndIf}
FunctionEnd

Function un.onInit
 SetShellVarContext current
 SetRegView 64
 System::Call 'kernel32::CreateMutexW(p 0, i 0, w "Local\FilmDevelop.Installer") p.r0 ?e'
 Pop $1
 ${If} $0 == 0
 ${OrIf} $1 == 183
  !insertmacro StopWithError 2 "另一個 FilmDevelop 安裝或解除安裝程序正在執行。"
 ${EndIf}
 ReadINIStr $0 "$INSTDIR\.filmdevelop-installed.ini" "Install" "Product"
 ${If} $0 != "${PRODUCT_ID}"
  !insertmacro StopWithError 3 "找不到 FilmDevelop 安裝標記，已保留此目錄。"
 ${EndIf}
FunctionEnd

Section "FilmDevelop"
 Call CheckInstallDirectory
 ${If} ${Errors}
  !insertmacro StopWithError 3 "請選擇空資料夾或既有的 FilmDevelop 安裝資料夾。"
 ${EndIf}
 !insertmacro CheckPayloadClosed
 !insertmacro CheckFileClosed "Uninstall.exe" "uninstaller"
 ; 先完成必要環境檢查，再更新使用者的程式檔案。
 InitPluginsDir
 SetOutPath "$PLUGINSDIR"
 File /oname=ensure-prerequisites.ps1 "${PAYLOAD_DIR}/Prerequisites/ensure-prerequisites.ps1"
 File /oname=prerequisites.json "${PAYLOAD_DIR}/Prerequisites/prerequisites.json"
 StrCpy $0 ""
 IfSilent 0 +2
  StrCpy $0 "-Silent"
 nsExec::ExecToLog '"$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\ensure-prerequisites.ps1" $0'
 Pop $1
 ${If} $1 == 3010
  SetRebootFlag true
 ${ElseIf} $1 != 0
  !insertmacro StopWithError 5 "Microsoft Visual C++ x64 執行環境尚未就緒。$\r$\n請確認網路、管理員安裝權限，或先安裝 Microsoft 官方 x64 套件，再重試。既有 FilmDevelop 尚未更新。"
 ${EndIf}
 ClearErrors
 !insertmacro InstallPayload
 ${If} ${Errors}
  !insertmacro StopWithError 3 "檔案安裝未完成，請確認磁碟空間與資料夾權限後重新執行。"
 ${EndIf}
 WriteUninstaller "$INSTDIR\Uninstall.exe"
 SetOutPath "$INSTDIR"
 CreateDirectory "$SMPROGRAMS\FilmDevelop"
 CreateShortcut "$SMPROGRAMS\FilmDevelop\FilmDevelop.lnk" "$INSTDIR\FilmDevelop.exe"
 CreateShortcut "$SMPROGRAMS\FilmDevelop\解除安裝 FilmDevelop.lnk" "$INSTDIR\Uninstall.exe"
 CreateShortcut "$DESKTOP\FilmDevelop.lnk" "$INSTDIR\FilmDevelop.exe"
 WriteRegStr HKCU "${PRODUCT_KEY}" "InstallDir" "$INSTDIR"
 WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "FilmDevelop"
 WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${DISPLAY_VERSION}"
 WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "VaderChen"
 WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
 WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\FilmDevelop.exe,0"
 WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
 WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
 WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" ${INSTALLED_SIZE_KB}
 WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
 WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
 ${If} ${Errors}
  !insertmacro StopWithError 3 "捷徑或解除安裝資訊寫入失敗，請重新執行安裝。"
 ${EndIf}
 IfRebootFlag 0 +3
  SetErrorLevel 3010
  Goto install_done
 SetErrorLevel 0
install_done:
SectionEnd

Section "Uninstall"
 !insertmacro CheckPayloadClosed
 ClearErrors
 !insertmacro RemovePayloadFiles
 ${If} ${Errors}
  !insertmacro StopWithError 3 "部分檔案無法移除，請關閉相關程式後重新執行解除安裝。"
 ${EndIf}
 ; 標記最後刪除，失敗時仍可重試；只移除本安裝程式擁有的檔案。
 Delete "$INSTDIR\Uninstall.exe"
 ${If} ${Errors}
  !insertmacro StopWithError 3 "解除安裝尚未完成，請確認資料夾可寫入後重試。"
 ${EndIf}
 Delete "$INSTDIR\.filmdevelop-installed.ini"
 !insertmacro RemovePayloadDirectories
 ; 搬動安裝位置後，舊目錄的解除安裝不可移除新版的登錄與捷徑。
 ReadRegStr $0 HKCU "${PRODUCT_KEY}" "InstallDir"
 ${If} $0 == $INSTDIR
  Delete "$DESKTOP\FilmDevelop.lnk"
  Delete "$SMPROGRAMS\FilmDevelop\FilmDevelop.lnk"
  Delete "$SMPROGRAMS\FilmDevelop\解除安裝 FilmDevelop.lnk"
  RMDir "$SMPROGRAMS\FilmDevelop"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegValue HKCU "${PRODUCT_KEY}" "InstallDir"
  DeleteRegKey /ifempty HKCU "${PRODUCT_KEY}"
 ${EndIf}
 SetOutPath "$TEMP"
 RMDir "$INSTDIR"
 SetErrorLevel 0
SectionEnd
