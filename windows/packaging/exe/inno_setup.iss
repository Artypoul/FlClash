[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
CloseApplications=no
SetupLogging=yes
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed={{ARCH}}
ArchitecturesInstallIn64BitMode={{ARCH}}

[Code]
const
  HelperServiceName = 'FlashcoHelperService';

var
  GuardFailureMessage: String;
  PartialPostInstallFailure: Boolean;
  PartialPostInstallFailureMessage: String;

function NormalizeFullPath(const Value: String): String;
var
  Path: String;
begin
  Result := '';
  Path := Trim(Value);
  StringChangeEx(Path, '/', '\', True);

  if not (((Length(Path) >= 3) and (Copy(Path, 2, 2) = ':\')) or
      (Copy(Path, 1, 2) = '\\')) then
  begin
    Exit;
  end;

  Result := ExpandFileName(Path);
  if (Length(Result) > 3) and (Copy(Result, Length(Result), 1) = '\') then
  begin
    Delete(Result, Length(Result), 1);
  end;
end;

function TryExtractExecutablePath(const CommandLine: String; var ExecutablePath: String): Boolean;
var
  ClosingQuote: Integer;
  Remainder: String;
  i: Integer;
begin
  Result := False;
  ExecutablePath := '';
  if CommandLine = '' then
  begin
    Exit;
  end;

  if Copy(CommandLine, 1, 1) = '"' then
  begin
    ClosingQuote := Pos('"', Copy(CommandLine, 2, Length(CommandLine)));
    if ClosingQuote = 0 then
    begin
      Exit;
    end;
    ExecutablePath := Copy(CommandLine, 2, ClosingQuote - 1);
    Remainder := Copy(CommandLine, ClosingQuote + 2, Length(CommandLine));
    if (Remainder <> '') and (Copy(Remainder, 1, 1) <> ' ') and
        (Copy(Remainder, 1, 1) <> #9) then
    begin
      Exit;
    end;
  end
  else
  begin
    i := 1;
    while (i <= Length(CommandLine)) and
        (Copy(CommandLine, i, 1) <> ' ') and (Copy(CommandLine, i, 1) <> #9) do
    begin
      i := i + 1;
    end;
    ExecutablePath := Copy(CommandLine, 1, i - 1);
  end;

  Result := ExecutablePath <> '';
end;

function QueryHelperService(var Found: Boolean; var BinaryPath, State: String;
    var FailureMessage: String): Boolean;
var
  Locator: Variant;
  Services: Variant;
  Objects: Variant;
  Service: Variant;
  Count: Integer;
begin
  Result := False;
  Found := False;
  BinaryPath := '';
  State := '';
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Services := Locator.ConnectServer('.', 'root\CIMV2');
    Objects := Services.ExecQuery(
      'SELECT PathName, State FROM Win32_Service WHERE Name=''' + HelperServiceName + '''');
    Count := Objects.Count;
    if Count < 0 then
    begin
      FailureMessage := 'Windows could not verify the Helper service registration.';
      Exit;
    end;
    if Count = 0 then
    begin
      Result := True;
      Exit;
    end;
    if Count <> 1 then
    begin
      FailureMessage := 'Windows returned an unexpected number of Helper service registrations.';
      Exit;
    end;

    Service := Objects.ItemIndex(0);
    if VarIsNull(Service.PathName) or VarIsEmpty(Service.PathName) or
        VarIsNull(Service.State) or VarIsEmpty(Service.State) then
    begin
      FailureMessage := 'Windows did not provide the Helper service path and state.';
      Exit;
    end;
    BinaryPath := Service.PathName;
    State := Service.State;
    if (Trim(BinaryPath) = '') or (Trim(State) = '') then
    begin
      FailureMessage := 'Windows returned an incomplete Helper service path or state.';
      Exit;
    end;
    if not (SameText(State, 'Stopped') or SameText(State, 'Start Pending') or
        SameText(State, 'Stop Pending') or SameText(State, 'Running') or
        SameText(State, 'Continue Pending') or SameText(State, 'Pause Pending') or
        SameText(State, 'Paused')) then
    begin
      FailureMessage := 'Windows returned an unknown Helper service state.';
      Exit;
    end;
    Found := True;
    Result := True;
  except
    FailureMessage := 'Windows could not verify the Helper service registration: ' + GetExceptionMessage;
  end;
end;

function HelperOwnershipConflict(): Boolean;
var
  Found: Boolean;
  BinaryPath: String;
  State: String;
  ServiceExePath: String;
  ExpectedPath: String;
begin
  Result := True;
  if not QueryHelperService(Found, BinaryPath, State, GuardFailureMessage) then
  begin
    Exit;
  end;
  if not Found then
  begin
    Result := False;
    Exit;
  end;

  if not TryExtractExecutablePath(BinaryPath, ServiceExePath) then
  begin
    GuardFailureMessage := 'The registered Helper service has an unrecognized executable command line.';
    Exit;
  end;
  ServiceExePath := NormalizeFullPath(ServiceExePath);
  ExpectedPath := NormalizeFullPath(ExpandConstant('{app}\FlashcoHelperService.exe'));
  if (ServiceExePath = '') or (ExpectedPath = '') then
  begin
    GuardFailureMessage := 'Windows could not verify the Helper service executable path.';
    Exit;
  end;
  if not SameText(ServiceExePath, ExpectedPath) then
  begin
    GuardFailureMessage := 'A Helper service with the same service name belongs to another installation. Remove it from that installation first.';
    Exit;
  end;

  Result := False;
end;

function HelperServiceStillRegistered(var FailureMessage: String): Boolean;
var
  Found: Boolean;
  BinaryPath: String;
  State: String;
begin
  Result := True;
  if not QueryHelperService(Found, BinaryPath, State, FailureMessage) then
  begin
    Exit;
  end;
  if Found then
  begin
    FailureMessage := 'The Helper service is still registered. It was left unchanged; retry after it has stopped.';
    Exit;
  end;
  Result := False;
end;

function HasRunningInstalledApp(): Boolean;
var
  Locator: Variant;
  Services: Variant;
  Objects: Variant;
  Process: Variant;
  Count: Integer;
  i: Integer;
  ImagePath: String;
  ExpectedPath: String;
begin
  Result := True;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Services := Locator.ConnectServer('.', 'root\CIMV2');
    Objects := Services.ExecQuery(
      'SELECT ExecutablePath FROM Win32_Process WHERE Name=''Flashco.exe''');
    Count := Objects.Count;
    if Count < 0 then
    begin
      GuardFailureMessage := 'Windows could not verify whether Flashco is running.';
      Exit;
    end;

    ExpectedPath := NormalizeFullPath(ExpandConstant('{app}\Flashco.exe'));
    if ExpectedPath = '' then
    begin
      GuardFailureMessage := 'Windows could not verify the Flashco installation path.';
      Exit;
    end;

    for i := 0 to Count - 1 do
    begin
      Process := Objects.ItemIndex(i);
      if VarIsNull(Process.ExecutablePath) or VarIsEmpty(Process.ExecutablePath) then
      begin
        GuardFailureMessage := 'Windows could not identify the path of a running Flashco process. Close Flashco and retry.';
        Exit;
      end;
      ImagePath := NormalizeFullPath(Process.ExecutablePath);
      if ImagePath = '' then
      begin
        GuardFailureMessage := 'Windows returned an invalid path for a running Flashco process.';
        Exit;
      end;
      if SameText(ImagePath, ExpectedPath) then
      begin
        GuardFailureMessage := 'Flashco is still running from this installation. Turn off the VPN and choose Exit from the Flashco tray menu, then retry.';
        Exit;
      end;
    end;

    Result := False;
  except
    GuardFailureMessage := 'Windows could not verify whether Flashco is running: ' + GetExceptionMessage;
  end;
end;

function StopInstalledHelper(var FailureMessage: String): Boolean;
var
  Found: Boolean;
  BinaryPath: String;
  State: String;
  ServiceExePath: String;
  ExpectedPath: String;
  HelperPath: String;
  ResultCode: Integer;
begin
  Result := False;
  if not QueryHelperService(Found, BinaryPath, State, FailureMessage) then
  begin
    Exit;
  end;
  if not Found then
  begin
    Result := True;
    Exit;
  end;

  if not TryExtractExecutablePath(BinaryPath, ServiceExePath) then
  begin
    FailureMessage := 'The registered Helper service has an unrecognized executable command line.';
    Exit;
  end;
  ServiceExePath := NormalizeFullPath(ServiceExePath);
  ExpectedPath := NormalizeFullPath(ExpandConstant('{app}\FlashcoHelperService.exe'));
  if (ServiceExePath = '') or (ExpectedPath = '') or
      not SameText(ServiceExePath, ExpectedPath) then
  begin
    FailureMessage := 'The registered Helper service does not belong to this installation. It was left unchanged.';
    Exit;
  end;

  HelperPath := ExpandConstant('{app}\FlashcoHelperService.exe');
  if not FileExists(HelperPath) then
  begin
    FailureMessage := 'The installed Helper executable is missing, so its service could not be removed safely.';
    Exit;
  end;
  if not Exec(HelperPath, 'uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    FailureMessage := 'Windows could not start the installed Helper to remove its service.';
    Exit;
  end;
  if ResultCode <> 0 then
  begin
    FailureMessage := 'The installed Helper failed to remove its service (exit code ' + IntToStr(ResultCode) + ').';
    Exit;
  end;
  if not QueryHelperService(Found, BinaryPath, State, FailureMessage) then
  begin
    Exit;
  end;
  if Found then
  begin
    FailureMessage := 'The Helper reported success, but Windows still reports its service as registered.';
    Exit;
  end;
  Result := True;
end;

function ClearStaleProxy(var FailureMessage: String): Boolean;
var
  AppPath: String;
  ResultCode: Integer;
begin
  Result := False;
  AppPath := ExpandConstant('{app}\{{EXECUTABLE_NAME}}');
  if not FileExists(AppPath) then
  begin
    FailureMessage := 'Flashco is missing, so stale proxy settings could not be cleared.';
    Exit;
  end;
  if not Exec(AppPath, '--clear-stale-proxy', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    FailureMessage := 'Windows could not start Flashco to clear stale proxy settings.';
    Exit;
  end;
  if ResultCode <> 0 then
  begin
    FailureMessage := 'Flashco could not clear stale proxy settings (exit code ' + IntToStr(ResultCode) + ').';
    Exit;
  end;
  Result := True;
end;

function PointsIntoApp(Value: String): Boolean;
begin
  Result := Pos(Lowercase(AddBackslash(ExpandConstant('{app}'))), Lowercase(Value)) > 0;
end;

// The value name is appName and the schemes are protocolSchemes, both in
// lib/common.
procedure RemoveUserRegistrations;
var
  Schemes: TArrayOfString;
  Value: String;
  i: Integer;
begin
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', '{{APP_NAME}}', Value) and PointsIntoApp(Value) then
  begin
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', '{{APP_NAME}}');
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run', '{{APP_NAME}}');
  end;

  Schemes := ['clash', 'clashmeta', 'flashco'];
  for i := 0 to GetArrayLength(Schemes)-1 do
  begin
    if RegQueryStringValue(HKCU, 'Software\Classes\' + Schemes[i] + '\shell\open\command', '', Value) and PointsIntoApp(Value) then
    begin
      RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\' + Schemes[i]);
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  FailureMessage: String;
begin
  Result := '';
  GuardFailureMessage := '';
  if HasRunningInstalledApp() then
  begin
    Result := GuardFailureMessage;
    Exit;
  end;
  if HelperOwnershipConflict() then
  begin
    Result := GuardFailureMessage;
    Exit;
  end;
  if not StopInstalledHelper(FailureMessage) then
  begin
    Result := FailureMessage;
    Exit;
  end;
  if HelperServiceStillRegistered(FailureMessage) then
  begin
    Result := FailureMessage;
    Exit;
  end;
  GuardFailureMessage := '';
  if HasRunningInstalledApp() then
  begin
    Result := GuardFailureMessage;
    Exit;
  end;
  if HelperOwnershipConflict() then
  begin
    Result := GuardFailureMessage;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  FailureMessage: String;
begin
  if CurStep = ssPostInstall then
  begin
    if not ClearStaleProxy(FailureMessage) then
    begin
      PartialPostInstallFailure := True;
      PartialPostInstallFailureMessage := FailureMessage;
      Log('Post-install stale proxy cleanup failed: ' + FailureMessage);
    end;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and PartialPostInstallFailure then
  begin
    WizardForm.FinishedHeadingLabel.Caption := 'Installation completed with a warning';
    WizardForm.FinishedLabel.Caption := 'Flashco files were installed, but stale proxy cleanup failed. Review proxy settings before launching Flashco.' + #13#10 + PartialPostInstallFailureMessage;
    WizardForm.AdjustLabelHeight(WizardForm.FinishedLabel);
  end;
end;

function ShouldLaunchAfterInstall(): Boolean;
begin
  Result := not PartialPostInstallFailure;
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := 0;
  if PartialPostInstallFailure then
  begin
    Result := 9;
  end;
end;

function InitializeUninstall(): Boolean;
var
  FailureMessage: String;
begin
  Result := False;
  GuardFailureMessage := '';
  if HasRunningInstalledApp() then
  begin
    MsgBox(GuardFailureMessage, mbError, MB_OK);
    Exit;
  end;
  if HelperOwnershipConflict() then
  begin
    MsgBox(GuardFailureMessage, mbError, MB_OK);
    Exit;
  end;
  if not StopInstalledHelper(FailureMessage) then
  begin
    MsgBox(FailureMessage, mbError, MB_OK);
    Exit;
  end;
  if HelperServiceStillRegistered(FailureMessage) then
  begin
    MsgBox(FailureMessage, mbError, MB_OK);
    Exit;
  end;
  GuardFailureMessage := '';
  if HasRunningInstalledApp() then
  begin
    MsgBox(GuardFailureMessage, mbError, MB_OK);
    Exit;
  end;
  if HelperOwnershipConflict() then
  begin
    MsgBox(GuardFailureMessage, mbError, MB_OK);
    Exit;
  end;
  if not ClearStaleProxy(FailureMessage) then
  begin
    MsgBox(FailureMessage + ' Uninstall was canceled; review the application state before retrying.', mbError, MB_OK);
    Exit;
  end;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RemoveUserRegistrations;
  end;
end;

[Languages]
{% for locale in LOCALES %}
{% if locale.lang == 'en' %}Name: "english"; MessagesFile: "compiler:Default.isl"{% endif %}
{% if locale.lang == 'hy' %}Name: "armenian"; MessagesFile: "compiler:Languages\\Armenian.isl"{% endif %}
{% if locale.lang == 'bg' %}Name: "bulgarian"; MessagesFile: "compiler:Languages\\Bulgarian.isl"{% endif %}
{% if locale.lang == 'ca' %}Name: "catalan"; MessagesFile: "compiler:Languages\\Catalan.isl"{% endif %}
{% if locale.lang == 'zh' %}
Name: "chineseSimplified"; MessagesFile: {% if locale.file %}{{ locale.file }}{% else %}"compiler:Languages\\ChineseSimplified.isl"{% endif %}
{% endif %}
{% if locale.lang == 'co' %}Name: "corsican"; MessagesFile: "compiler:Languages\\Corsican.isl"{% endif %}
{% if locale.lang == 'cs' %}Name: "czech"; MessagesFile: "compiler:Languages\\Czech.isl"{% endif %}
{% if locale.lang == 'da' %}Name: "danish"; MessagesFile: "compiler:Languages\\Danish.isl"{% endif %}
{% if locale.lang == 'nl' %}Name: "dutch"; MessagesFile: "compiler:Languages\\Dutch.isl"{% endif %}
{% if locale.lang == 'fi' %}Name: "finnish"; MessagesFile: "compiler:Languages\\Finnish.isl"{% endif %}
{% if locale.lang == 'fr' %}Name: "french"; MessagesFile: "compiler:Languages\\French.isl"{% endif %}
{% if locale.lang == 'de' %}Name: "german"; MessagesFile: "compiler:Languages\\German.isl"{% endif %}
{% if locale.lang == 'he' %}Name: "hebrew"; MessagesFile: "compiler:Languages\\Hebrew.isl"{% endif %}
{% if locale.lang == 'is' %}Name: "icelandic"; MessagesFile: "compiler:Languages\\Icelandic.isl"{% endif %}
{% if locale.lang == 'it' %}Name: "italian"; MessagesFile: "compiler:Languages\\Italian.isl"{% endif %}
{% if locale.lang == 'ja' %}Name: "japanese"; MessagesFile: "compiler:Languages\\Japanese.isl"{% endif %}
{% if locale.lang == 'no' %}Name: "norwegian"; MessagesFile: "compiler:Languages\\Norwegian.isl"{% endif %}
{% if locale.lang == 'pl' %}Name: "polish"; MessagesFile: "compiler:Languages\\Polish.isl"{% endif %}
{% if locale.lang == 'pt' %}Name: "portuguese"; MessagesFile: "compiler:Languages\\Portuguese.isl"{% endif %}
{% if locale.lang == 'ru' %}Name: "russian"; MessagesFile: "compiler:Languages\\Russian.isl"{% endif %}
{% if locale.lang == 'sk' %}Name: "slovak"; MessagesFile: "compiler:Languages\\Slovak.isl"{% endif %}
{% if locale.lang == 'sl' %}Name: "slovenian"; MessagesFile: "compiler:Languages\\Slovenian.isl"{% endif %}
{% if locale.lang == 'es' %}Name: "spanish"; MessagesFile: "compiler:Languages\\Spanish.isl"{% endif %}
{% if locale.lang == 'tr' %}Name: "turkish"; MessagesFile: "compiler:Languages\\Turkish.isl"{% endif %}
{% if locale.lang == 'uk' %}Name: "ukrainian"; MessagesFile: "compiler:Languages\\Ukrainian.isl"{% endif %}
{% endfor %}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if CREATE_DESKTOP_ICON != true %}unchecked{% else %}checkedonce{% endif %}
[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
[Run]
Filename: "{app}\\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Check: ShouldLaunchAfterInstall; Flags: {% if PRIVILEGES_REQUIRED == 'admin' %}runascurrentuser{% endif %} nowait postinstall skipifsilent
