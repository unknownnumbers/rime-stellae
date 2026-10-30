; Independent Rime stellae installation script
!include stellae_identity.nsh
!include FileFunc.nsh
!include LogicLib.nsh
!include MUI2.nsh
!include x64.nsh
!include winVer.nsh

Unicode true
Var ProfilePolicyPowerShell

;--------------------------------
; General

!ifndef WEASEL_VERSION
!define WEASEL_VERSION 0.1.0
!endif

!ifndef WEASEL_BUILD
!define WEASEL_BUILD 0
!endif

!define WEASEL_ROOT $INSTDIR
!define REG_UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${STELLAE_NAMESPACE}"

; The name of the installer
Name "${STELLAE_DISPLAY_ZH} ${WEASEL_VERSION}"

; The file to write
OutFile "archives\${STELLAE_BINARY_BASE}-${PRODUCT_VERSION}-installer.exe"

VIProductVersion "${WEASEL_VERSION}.${WEASEL_BUILD}"
VIAddVersionKey /LANG=2052 "ProductName" "${STELLAE_DISPLAY_ZH}"
VIAddVersionKey /LANG=2052 "Comments" "Powered by RIME | 中州韻輸入法引擎"
VIAddVersionKey /LANG=2052 "CompanyName" "${STELLAE_PRODUCT_NAME} contributors"
VIAddVersionKey /LANG=2052 "LegalCopyright" "Copyleft RIME Developers"
VIAddVersionKey /LANG=2052 "FileDescription" "${STELLAE_DISPLAY_ZH}輸入法"
VIAddVersionKey /LANG=2052 "FileVersion" "${WEASEL_VERSION}"

!define MUI_ICON ..\resource\weasel.ico
SetCompressor /SOLID lzma


; Request application privileges for Windows Vista
RequestExecutionLevel admin

;--------------------------------

; Pages

!insertmacro MUI_PAGE_LICENSE "LICENSE.txt"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TEXT "$(NO_SCHEMAS)"
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "$(OPEN_USER_FOLDER)"
!define MUI_FINISHPAGE_RUN_FUNCTION OpenUserFolder
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\README.txt"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

;--------------------------------

; Languages

!insertmacro MUI_LANGUAGE "TradChinese"
LangString NO_SCHEMAS ${LANG_TRADCHINESE} "本安裝包未附輸入方案. 請添加自己的方案後重新部署. 安裝不會自動下載方案或搬入其他輸入法資料."
LangString OPEN_USER_FOLDER ${LANG_TRADCHINESE} "打開使用者資料夾"
LangString DISPLAYNAME ${LANG_TRADCHINESE} "${STELLAE_DISPLAY_ZH}輸入法"
LangString LNKFORMANUAL ${LANG_TRADCHINESE} "【${STELLAE_DISPLAY_ZH}】說明書"
LangString LNKFORSETTING ${LANG_TRADCHINESE} "【${STELLAE_DISPLAY_ZH}】輸入法設定"
LangString LNKFORDICT ${LANG_TRADCHINESE} "【${STELLAE_DISPLAY_ZH}】用戶詞典管理"
LangString LNKFORSYNC ${LANG_TRADCHINESE} "【${STELLAE_DISPLAY_ZH}】用戶資料同步"
LangString LNKFORDEPLOY ${LANG_TRADCHINESE} "【${STELLAE_DISPLAY_ZH}】重新部署"
LangString LNKFORSERVER ${LANG_TRADCHINESE} "${STELLAE_DISPLAY_ZH}算法服務"
LangString LNKFORUSERFOLDER ${LANG_TRADCHINESE} "【${STELLAE_DISPLAY_ZH}】用戶文件夾"
LangString LNKFORAPPFOLDER ${LANG_TRADCHINESE} "【${STELLAE_DISPLAY_ZH}】程序文件夾"
LangString LNKFORUPDATER ${LANG_TRADCHINESE} "【${STELLAE_DISPLAY_ZH}】檢查新版本"
LangString LNKFORSETUP ${LANG_TRADCHINESE} "【${STELLAE_DISPLAY_ZH}】安裝選項"
LangString LNKFORUNINSTALL ${LANG_TRADCHINESE} "卸載${STELLAE_DISPLAY_ZH}"
LangString CONFIRMATION ${LANG_TRADCHINESE} "安裝前，請先卸載舊版本的${STELLAE_DISPLAY_ZH}。$\n$\n按下「確定」移除舊版本，按下「取消」放棄本次安裝。"
LangString SYSTEMVERSIONNOTOK ${LANG_TRADCHINESE} "您的系统不被支持，最低系統要求:Windows 8.1!"
LangString AUTOCHKUPDATE ${LANG_TRADCHINESE} "自動檢查版本更新？"

!insertmacro MUI_LANGUAGE "SimpChinese"
LangString NO_SCHEMAS ${LANG_SIMPCHINESE} "本安装包未附输入方案. 请添加自己的方案后重新部署. 安装不会自动下载方案或搬入其他输入法资料."
LangString OPEN_USER_FOLDER ${LANG_SIMPCHINESE} "打开用户文件夹"
LangString DISPLAYNAME ${LANG_SIMPCHINESE} "${STELLAE_DISPLAY_ZH}输入法"
LangString LNKFORMANUAL ${LANG_SIMPCHINESE} "【${STELLAE_DISPLAY_ZH}】说明书"
LangString LNKFORSETTING ${LANG_SIMPCHINESE} "【${STELLAE_DISPLAY_ZH}】输入法设定"
LangString LNKFORDICT ${LANG_SIMPCHINESE} "【${STELLAE_DISPLAY_ZH}】用户词典管理"
LangString LNKFORSYNC ${LANG_SIMPCHINESE} "【${STELLAE_DISPLAY_ZH}】用户资料同步"
LangString LNKFORDEPLOY ${LANG_SIMPCHINESE} "【${STELLAE_DISPLAY_ZH}】重新部署"
LangString LNKFORSERVER ${LANG_SIMPCHINESE} "${STELLAE_DISPLAY_ZH}算法服务"
LangString LNKFORUSERFOLDER ${LANG_SIMPCHINESE} "【${STELLAE_DISPLAY_ZH}】用户文件夹"
LangString LNKFORAPPFOLDER ${LANG_SIMPCHINESE} "【${STELLAE_DISPLAY_ZH}】程序文件夹"
LangString LNKFORUPDATER ${LANG_SIMPCHINESE} "【${STELLAE_DISPLAY_ZH}】检查新版本"
LangString LNKFORSETUP ${LANG_SIMPCHINESE} "【${STELLAE_DISPLAY_ZH}】安装选项"
LangString LNKFORUNINSTALL ${LANG_SIMPCHINESE} "卸载${STELLAE_DISPLAY_ZH}"
LangString CONFIRMATION ${LANG_SIMPCHINESE} '安装前，请先卸载旧版本的${STELLAE_DISPLAY_ZH}。$\n$\n点击 "确定" 移除旧版本，或点击 "取消" 放弃本次安装。'
LangString SYSTEMVERSIONNOTOK ${LANG_SIMPCHINESE} "您的系統不被支持，最低系统要求:Windows 8.1!"
LangString AUTOCHKUPDATE ${LANG_SIMPCHINESE} "自动检查版本更新？"

!insertmacro MUI_LANGUAGE "English"
LangString NO_SCHEMAS ${LANG_ENGLISH} "No input schemes are bundled. Add your own scheme, then deploy. Installation does not download schemes or copy data from other input methods."
LangString OPEN_USER_FOLDER ${LANG_ENGLISH} "Open the user folder"
LangString DISPLAYNAME ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME}"
LangString LNKFORMANUAL ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME} Manual"
LangString LNKFORSETTING ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME} Settings"
LangString LNKFORDICT ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME} Dictionary Manager"
LangString LNKFORSYNC ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME} Sync User Profile"
LangString LNKFORDEPLOY ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME} Deploy"
LangString LNKFORSERVER ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME} Server"
LangString LNKFORUSERFOLDER ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME} User Folder"
LangString LNKFORAPPFOLDER ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME} App Folder"
LangString LNKFORUPDATER ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME} Check for Updates"
LangString LNKFORSETUP ${LANG_ENGLISH} "${STELLAE_PRODUCT_NAME} Installation Preference"
LangString LNKFORUNINSTALL ${LANG_ENGLISH} "Uninstall ${STELLAE_PRODUCT_NAME}"
LangString CONFIRMATION ${LANG_ENGLISH} "Before installation, please uninstall the old version of ${STELLAE_PRODUCT_NAME}.$\n$\nPress 'OK' to remove the old version, or 'Cancel' to abort installation."
LangString SYSTEMVERSIONNOTOK ${LANG_ENGLISH} "Your system not supported, minimium system required: Windows 8.1!"
LangString AUTOCHKUPDATE ${LANG_ENGLISH} "Automatically check for updates?"

;--------------------------------

Function .onInit
  SetRegView 32
  ${If} ${IsNativeARM64}
    Abort "This build supports x64 and x86 Windows."
  ${EndIf}
  ; if not version >= 8.1, quit and MessageBox(if not silent)
  ${IfNot} ${AtLeastWin8.1}
    IfSilent toquit
    MessageBox MB_OK '$(SYSTEMVERSIONNOTOK)'
toquit:
    Quit
  ${EndIf}

  ReadRegStr $R0 HKLM "${STELLAE_REG_KEY}" "InstallDir"
  StrCmp $R0 "" choose_directory
  StrCpy $INSTDIR $R0
  Goto skip
choose_directory:
  ; The default installation directory
  ; install x64 build for NativeARM64_WINDOWS11 and NativeAMD64_WINDOWS11
  ${If} ${AtLeastWin11} ; Windows 11 and above
    ${If} ${IsNativeARM64}
      StrCpy $INSTDIR "$PROGRAMFILES64\${STELLAE_PROGRAM_DIRECTORY}"
    ${ElseIf} ${IsNativeAMD64}
      StrCpy $INSTDIR "$PROGRAMFILES64\${STELLAE_PROGRAM_DIRECTORY}"
    ${Else}
      StrCpy $INSTDIR "$PROGRAMFILES\${STELLAE_PROGRAM_DIRECTORY}"
    ${Endif}
  ; install x64 build for NativeAMD64_BELLOW_WINDOWS11
  ${Else} ; Windows 10 or bellow
    ${If} ${IsNativeAMD64}
      StrCpy $INSTDIR "$PROGRAMFILES64\${STELLAE_PROGRAM_DIRECTORY}"
    ${Else}
      StrCpy $INSTDIR "$PROGRAMFILES\${STELLAE_PROGRAM_DIRECTORY}"
    ${Endif}
  ${Endif}
skip:
  InitPluginsDir
  SetOutPath "$PLUGINSDIR\profile-policy"
  File "InstallProfilePolicy.ps1"
  File "NativeProfileSnapshot.ps1"
  StrCpy $ProfilePolicyPowerShell "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  ${If} ${RunningX64}
    StrCpy $ProfilePolicyPowerShell "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  ${EndIf}
  ClearErrors
  ExecWait '"$ProfilePolicyPowerShell" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\profile-policy\InstallProfilePolicy.ps1" -Action Capture -StateFile "$PLUGINSDIR\profile-policy\input-before.json"' $R4
  IfErrors profile_capture_failed
  IntCmp $R4 0 profile_capture_ready
profile_capture_failed:
  Abort "Could not read the current Windows input settings. No installation changes were made."
profile_capture_ready:
  ReadRegStr $R0 HKLM \
  "Software\Microsoft\Windows\CurrentVersion\Uninstall\${STELLAE_NAMESPACE}" \
  "UninstallString"
  StrCmp $R0 "" done

  StrCpy $0 "Upgrade"
  IfSilent uninst 0
  MessageBox MB_OKCANCEL|MB_ICONINFORMATION "$(CONFIRMATION)" IDOK uninst
  Abort

uninst:
  ; Backup data directory from previous installation, user files may exist
  ReadRegStr $R1 HKLM ${STELLAE_REG_KEY} "WeaselRoot"
  StrCmp $R1 "" done
  IfFileExists "$R1\${STELLAE_SETUP_EXE}" 0 done
  IfFileExists "$R1\WeaselServer.exe" 0 upgrade_own_directory
  Abort "The registered directory also contains Weasel. Its files have been preserved."
upgrade_own_directory:
  IfFileExists $R1\data\*.* 0 call_uninstaller
  CreateDirectory $TEMP\${STELLAE_BINARY_BASE}-backup
  CopyFiles $R1\data\*.* $TEMP\${STELLAE_BINARY_BASE}-backup

call_uninstaller:
  ExecWait '"$R1\${STELLAE_SERVER_EXE}" /quit'
  ExecWait '"$R1\${STELLAE_SETUP_EXE}" /u'
  ; Remove registry keys
  DeleteRegKey HKLM "${STELLAE_REG_KEY}"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${STELLAE_NAMESPACE}"
  ; don't redirect on 64 bit system for auto run setting
  ${If} ${IsNativeARM64}
    SetRegView 64
  ${ElseIf} ${IsNativeAMD64}
    SetRegView 64
  ${Endif}
  DeleteRegValue HKLM "Software\Microsoft\Windows\CurrentVersion\Run" "${STELLAE_SERVER_TARGET}"
  ; recover back to 32bit view
  SetRegView 32
  ; Remove files and uninstaller
  Delete  "$R1\data\opencc\*.*"
  Delete  "$R1\data\preview\*.*"
  Delete  "$R1\data\*.*"
  RMDir /r "$R1\licenses"
  Delete  "$R1\*.*"
  RMDir   "$R1\data\opencc"
  RMDir   "$R1\data\preview"
  RMDir   "$R1\data"
  RMDir   "$R1"
  SetShellVarContext all
  Delete  "$SMPROGRAMS\$(DISPLAYNAME)\*.*"
  RMDir  "$SMPROGRAMS\$(DISPLAYNAME)"
  ; Prompt reboot
  SetRebootFlag true
  Sleep 800

done:
FunctionEnd

; Registry key to check for directory (so if you install again, it will
; overwrite the old one automatically)
InstallDirRegKey HKLM "${STELLAE_REG_KEY}" "InstallDir"

; The stuff to install
Section "${STELLAE_PRODUCT_NAME}"
  SetRegView 32

  SectionIn RO

  ; A distinct product must never overwrite an official Weasel directory.
  IfFileExists "$INSTDIR\WeaselServer.exe" 0 own_directory
  Abort "This directory belongs to Weasel. Select a separate directory."
own_directory:
  ; Write the new installation path into the registry
  ; redirect on 64 bit system
  ; HKLM ${STELLAE_REG_KEY} "InstallDir" "$INSTDIR"
  WriteRegStr HKLM ${STELLAE_REG_KEY} "InstallDir" "$INSTDIR"

  ; Reset INSTDIR for the new version
  StrCpy $INSTDIR "${WEASEL_ROOT}"

  IfFileExists "$INSTDIR\${STELLAE_SERVER_EXE}" 0 +2
  ExecWait '"$INSTDIR\${STELLAE_SERVER_EXE}" /quit'

  SetOverwrite try
  ; Set output path to the installation directory.
  SetOutPath $INSTDIR

  IfFileExists $TEMP\${STELLAE_BINARY_BASE}-backup\*.* 0 program_files
  CreateDirectory $INSTDIR\data
  CopyFiles $TEMP\${STELLAE_BINARY_BASE}-backup\*.* $INSTDIR\data
  RMDir /r $TEMP\${STELLAE_BINARY_BASE}-backup

program_files:
  File "LICENSE.txt"
  File "README.txt"
  File "LICENSE-DOCS"
  File "SOURCES.md"
  File "THIRD_PARTY_NOTICES.md"
  File "package-manifest.json"
  File "package-license-index.json"
  SetOutPath "$INSTDIR\licenses"
  File /r "licenses\*"
  SetOutPath $INSTDIR
  File "7-zip-license.txt"
  File "7z.dll"
  File "7z.exe"
  File "COPYING-curl.txt"
  File "curl.exe"
  File "curl-ca-bundle.crt"
  File "rime-install.bat"
  File "rime-install-config.bat"
  File "start_service.bat"
  File "stop_service.bat"
  File "${STELLAE_BINARY_BASE}.dll"
  ${If} ${RunningX64}
    File "${STELLAE_BINARY_BASE}x64.dll"
  ${EndIf}
  File "${STELLAE_BINARY_BASE}.ime"
  ${If} ${RunningX64}
    File "${STELLAE_BINARY_BASE}x64.ime"
  ${EndIf}
  ; install x64 build for NativeARM64_WINDOWS11 and NativeAMD64_WINDOWS11
  ${If} ${AtLeastWin11} ; Windows 11 and above
    ${If} ${IsNativeARM64}
      File "${STELLAE_DEPLOYER_EXE}"
      File "${STELLAE_SERVER_EXE}"
      File "rime.dll"

    ${ElseIf} ${IsNativeAMD64}
      File "${STELLAE_DEPLOYER_EXE}"
      File "${STELLAE_SERVER_EXE}"
      File "rime.dll"

    ${Else}
      File "Win32\${STELLAE_DEPLOYER_EXE}"
      File "Win32\${STELLAE_SERVER_EXE}"
      File "Win32\rime.dll"

    ${Endif}
  ; install x64 build for NativeAMD64_BELLOW_WINDOWS11
  ${Else} ; Windows 10 or bellow
    ${If} ${IsNativeAMD64}
      File "${STELLAE_DEPLOYER_EXE}"
      File "${STELLAE_SERVER_EXE}"
      File "rime.dll"

    ${Else}
      File "Win32\${STELLAE_DEPLOYER_EXE}"
      File "Win32\${STELLAE_SERVER_EXE}"
      File "Win32\rime.dll"

    ${Endif}
  ${Endif}

  File "${STELLAE_SETUP_EXE}"
  ; shared data files
  SetOutPath $INSTDIR\data
  File "data\default.yaml"
  File "data\weasel.yaml"
  File "data\key_bindings.yaml"
  File "data\punctuation.yaml"
  File "data\symbols.yaml"
  ; opencc data files
  SetOutPath $INSTDIR\data\opencc
  File "data\opencc\*.json"
  File "data\opencc\*.ocd*"
  ; images
  SetOutPath $INSTDIR\data\preview
  File "data\preview\*.png"

  SetOutPath $INSTDIR

  ; /T selects the Traditional installation profile (HK).
  StrCpy $R2 "/i"
  ; Retain this product's registered language when upgrading silently.
  ReadRegDWORD $R3 HKCU "${STELLAE_REG_KEY}" "Hant"
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/S" $R1
  ; A fresh silent install uses TC (HK); keep an existing SC choice.
  IfErrors +4 0
  StrCpy $R2 "/t"
  StrCmp $R3 "0" 0 +2
  StrCpy $R2 "/s"
  ${If} $R3 == 1
    StrCpy $R2 "/t"
  ${EndIf}
  ${GetOptions} $R0 "/T" $R1
  IfErrors +2 0
  StrCpy $R2 "/t"

  ClearErrors
  ExecWait '"$INSTDIR\${STELLAE_SETUP_EXE}" $R2' $R4
  IfErrors profile_setup_failed
  IntCmp $R4 0 profile_setup_ready
profile_setup_failed:
  Abort "Rime stellae registration could not be completed."
profile_setup_ready:
  ClearErrors
  ExecWait '"$ProfilePolicyPowerShell" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\profile-policy\InstallProfilePolicy.ps1" -Action Finalize -StateFile "$PLUGINSDIR\profile-policy\input-before.json"' $R4
  IfErrors profile_placement_failed
  IntCmp $R4 0 profile_placement_ready
profile_placement_failed:
  Abort "Rime stellae was registered, but Windows input settings could not be retained."
profile_placement_ready:

  ; Write the uninstall keys for Windows
  WriteRegStr HKLM "${REG_UNINST_KEY}" "DisplayName" "$(DISPLAYNAME)"
  WriteRegStr HKLM "${REG_UNINST_KEY}" "DisplayIcon" '"$INSTDIR\${STELLAE_SERVER_EXE}"'
  WriteRegStr HKLM "${REG_UNINST_KEY}" "DisplayVersion" "${WEASEL_VERSION}.${WEASEL_BUILD}"
  WriteRegStr HKLM "${REG_UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${REG_UNINST_KEY}" "Publisher" "${STELLAE_PRODUCT_NAME} contributors"
  WriteRegStr HKLM "${REG_UNINST_KEY}" "URLInfoAbout" "https://github.com/unknownnumbers/rime-stellae"
  WriteRegStr HKLM "${REG_UNINST_KEY}" "HelpLink" "https://github.com/unknownnumbers/rime-stellae#installation"
  WriteRegDWORD HKLM "${REG_UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${REG_UNINST_KEY}" "NoRepair" 1
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; Deploy an empty scheme list without opening an empty selection dialog.
  ExecWait '"$INSTDIR\${STELLAE_DEPLOYER_EXE}" /deploy'

  ; don't redirect on 64 bit system for auto run setting
  ${If} ${IsNativeARM64}
    SetRegView 64
  ${ElseIf} ${IsNativeAMD64}
    SetRegView 64
  ${Endif}
  ; Write autorun key
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Run" "${STELLAE_SERVER_TARGET}" '"$INSTDIR\${STELLAE_SERVER_EXE}"'
  ; Start ${STELLAE_PRODUCT_NAME}Server
  Exec '"$INSTDIR\${STELLAE_SERVER_EXE}"'

  ; No independent update channel has been configured for this product.
  SetRegView 32
  WriteRegStr HKCU "${STELLAE_REG_KEY}\Updates" "CheckForUpdates" "0"

  ; Prompt reboot
  StrCmp $0 "Upgrade" 0 +2
  SetRebootFlag true

SectionEnd

; Optional section (can be disabled by the user)
Section "Start Menu Shortcuts"
  SetShellVarContext all
  CreateDirectory "$SMPROGRAMS\$(DISPLAYNAME)"
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORMANUAL).lnk" "$INSTDIR\README.txt"
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORSETTING).lnk" "$INSTDIR\${STELLAE_DEPLOYER_EXE}" "" "$SYSDIR\shell32.dll" 21
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORDICT).lnk" "$INSTDIR\${STELLAE_DEPLOYER_EXE}" "/dict" "$SYSDIR\shell32.dll" 6
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORSYNC).lnk" "$INSTDIR\${STELLAE_DEPLOYER_EXE}" "/sync" "$SYSDIR\shell32.dll" 26
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORDEPLOY).lnk" "$INSTDIR\${STELLAE_DEPLOYER_EXE}" "/deploy" "$SYSDIR\shell32.dll" 144
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORSERVER).lnk" "$INSTDIR\${STELLAE_SERVER_EXE}" "" "$INSTDIR\${STELLAE_SERVER_EXE}" 0
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORUSERFOLDER).lnk" "$INSTDIR\${STELLAE_SERVER_EXE}" "/userdir" "$SYSDIR\shell32.dll" 126
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORAPPFOLDER).lnk" "$INSTDIR\${STELLAE_SERVER_EXE}" "/weaseldir" "$SYSDIR\shell32.dll" 19
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORUPDATER).lnk" "$INSTDIR\${STELLAE_SERVER_EXE}" "/update" "$SYSDIR\shell32.dll" 13
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORSETUP).lnk" "$INSTDIR\${STELLAE_SETUP_EXE}" "" "$SYSDIR\shell32.dll" 162
  CreateShortCut "$SMPROGRAMS\$(DISPLAYNAME)\$(LNKFORUNINSTALL).lnk" "$INSTDIR\uninstall.exe" "" "$INSTDIR\uninstall.exe" 0

SectionEnd

;--------------------------------

; Uninstaller

Section "Uninstall"
  SetRegView 32
  IfFileExists "$INSTDIR\WeaselServer.exe" 0 uninstall_own_directory
  Abort "This directory also contains Weasel. Its files have been preserved."
uninstall_own_directory:

  ExecWait '"$INSTDIR\${STELLAE_SERVER_EXE}" /quit'

  ExecWait '"$INSTDIR\${STELLAE_SETUP_EXE}" /u'

  ; Remove registry keys
  DeleteRegKey HKLM "${STELLAE_REG_KEY}"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${STELLAE_NAMESPACE}"
  ; don't redirect on 64 bit system for auto run setting
  ${If} ${IsNativeARM64}
    SetRegView 64
  ${ElseIf} ${IsNativeAMD64}
    SetRegView 64
  ${Endif}
  DeleteRegValue HKLM "Software\Microsoft\Windows\CurrentVersion\Run" "${STELLAE_SERVER_TARGET}"

  ; Remove files and uninstaller
  SetOutPath $TEMP
  Delete  "$INSTDIR\data\opencc\*.*"
  Delete  "$INSTDIR\data\preview\*.*"
  Delete  "$INSTDIR\data\*.*"
  RMDir /r "$INSTDIR\licenses"
  Delete  "$INSTDIR\*.*"
  RMDir  "$INSTDIR\data\opencc"
  RMDir  "$INSTDIR\data\preview"
  RMDir  "$INSTDIR\data"
  RMDir  "$INSTDIR"
  SetShellVarContext all
  Delete  "$SMPROGRAMS\$(DISPLAYNAME)\*.*"
  RMDir  "$SMPROGRAMS\$(DISPLAYNAME)"

  ; Prompt reboot
  SetRebootFlag true

SectionEnd

Function OpenUserFolder
  Exec '"$INSTDIR\${STELLAE_SERVER_EXE}" /userdir'
FunctionEnd
