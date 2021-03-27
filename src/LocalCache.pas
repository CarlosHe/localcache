unit LocalCache;

interface

uses
  System.Rtti, System.Generics.Collections, System.Classes, System.SyncObjs;

type

  TLocalCacheManager = class
  private
    { private declarations }
    FCriticalSection: TCriticalSection;
    FLocalCacheList: TObjectDictionary<string, TValue>;
    class var
      FDefaultManager: TLocalCacheManager;
  protected
    { protected declarations }
    function GetLocalCacheList: TObjectDictionary<string, TValue>;
    function CacheListToString: string;
    function GetFileName: string;
    procedure LoadFromFile;
    procedure LoadCacheListFromString(AData: string);
    procedure MakeCacheDir;
    procedure SaveToFile;
    class function GetDefaultManager: TLocalCacheManager; static;
  public
    { public declarations }
    constructor Create;
    destructor Destroy; override;
    class destructor UnInitialize;
    function SetValue(const AKey: String; AValue: TValue): TLocalCacheManager; overload;
    function SetValue<T>(const AKey: String; AValue: T): TLocalCacheManager; overload;
    function GetValue(const AKey: String; out AValue: TValue): TLocalCacheManager; overload;
    function GetValue<T>(const AKey: String; out AValue: T): TLocalCacheManager; overload;
    function TryGetValue(const AKey: String; out AValue: TValue; ADefault: TValue): TLocalCacheManager; overload;
    function TryGetValue<T>(const AKey: String; out AValue: T; ADefault: T): TLocalCacheManager; overload;
    function RemoveKey(const AKey: String): TLocalCacheManager; overload;
    class property DefaultManager: TLocalCacheManager read GetDefaultManager;

  end;

implementation

uses
  System.SysUtils, System.Json, System.IOUtils, REST.Json, System.NetEncoding, System.TypInfo;

{ TLocalCacheManager }

function TLocalCacheManager.GetLocalCacheList: TObjectDictionary<string, TValue>;
begin
  if FLocalCacheList = nil then
    FLocalCacheList := TObjectDictionary<string, TValue>.Create;
  Result := FLocalCacheList;
end;

class destructor TLocalCacheManager.UnInitialize;
begin
  FreeAndNil(FDefaultManager);
end;

function TLocalCacheManager.CacheListToString: string;
var
  LKey: string;
  LJSONObject: TJSONObject;
  LTypeKind: TTypeKind;
begin
  Result := '';
  LJSONObject := TJSONObject.Create;
  try
    for LKey in GetLocalCacheList.Keys do
    begin
      LTypeKind := GetLocalCacheList.Items[LKey].Kind;
      case LTypeKind of
        tkInteger, tkInt64, tkFloat:
          LJSONObject.AddPair(LKey, TJsonNumber.Create(GetLocalCacheList.Items[LKey].AsExtended));
        tkEnumeration:
          LJSONObject.AddPair(LKey, TJsonBool.Create(GetLocalCacheList.Items[LKey].AsBoolean));
        tkString, tkUString, tkLString, tkWString, tkWChar, tkChar:
          LJSONObject.AddPair(LKey, GetLocalCacheList.Items[LKey].AsString);
      end;
    end;
    Result := LJSONObject.ToJSON;
  finally
    LJSONObject.Free;
  end;
end;

constructor TLocalCacheManager.Create;
begin
  FCriticalSection := TCriticalSection.Create;
  LoadFromFile;
end;

destructor TLocalCacheManager.Destroy;
begin
  FCriticalSection.Free;
  FLocalCacheList.Free;
  inherited;
end;

class function TLocalCacheManager.GetDefaultManager: TLocalCacheManager;
begin
  if FDefaultManager = nil then
    FDefaultManager := TLocalCacheManager.Create;
  Result := FDefaultManager;
end;

function TLocalCacheManager.GetFileName: string;
var
  LFileName: string;
begin
  LFileName := TPath.GetDocumentsPath;
{$IFDEF MSWINDOWS}
  LFileName := TPath.Combine(LFileName, TPath.GetFileNameWithoutExtension(ParamStr(0)));
{$ENDIF}
  LFileName := TPath.Combine(LFileName, 'cache');
  LFileName := TPath.Combine(LFileName, 'localcache.json');
  Result := LFileName;
end;

function TLocalCacheManager.GetValue(const AKey: String; out AValue: TValue): TLocalCacheManager;
begin
  Result := Self;
  FCriticalSection.Enter;
  try
    GetLocalCacheList.TryGetValue(AKey, AValue);
  finally
    FCriticalSection.Leave;
  end;
end;

function TLocalCacheManager.GetValue<T>(const AKey: String; out AValue: T): TLocalCacheManager;
var
  LValue: TValue;
begin
  Result := GetValue(AKey, LValue);
  if (TTypeInfo(System.TypeInfo(T)^).Kind in [tkInteger, tkInt64]) and (LValue.Kind = tkFloat) then
    TValue.From<Integer>(Trunc(LValue.AsExtended)).TryAsType(AValue)
  else
    LValue.TryAsType(AValue);
end;

procedure TLocalCacheManager.LoadCacheListFromString(AData: string);
var
  LJSONObject: TJSONObject;
  I: Integer;
begin
  GetLocalCacheList.Clear;
  LJSONObject := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  try
    for I := 0 to Pred(LJSONObject.Count) do
    begin
      if LJSONObject.Pairs[I].JsonValue is TJsonBool then
        GetLocalCacheList.Add(
          LJSONObject.Pairs[I].JsonString.Value,
          LJSONObject.Pairs[I].JsonValue.AsType<Boolean>
          )
      else if LJSONObject.Pairs[I].JsonValue is TJsonNumber then
        GetLocalCacheList.Add(
          LJSONObject.Pairs[I].JsonString.Value,
          LJSONObject.Pairs[I].JsonValue.AsType<Double>
          )
      else if LJSONObject.Pairs[I].JsonValue is TJSONString then
        GetLocalCacheList.Add(
          LJSONObject.Pairs[I].JsonString.Value,
          LJSONObject.Pairs[I].JsonValue.AsType<string>
          );
    end;

  finally
    LJSONObject.Free;
  end;
end;

procedure TLocalCacheManager.LoadFromFile;
var
  LStringStream: TStringStream;
begin
  LStringStream := TStringStream.Create;
  try
    if not FileExists(GetFileName) then
      Exit;
    LStringStream.LoadFromFile(GetFileName);
    LoadCacheListFromString(LStringStream.DataString);
  finally
    LStringStream.Free;
  end;
end;

procedure TLocalCacheManager.MakeCacheDir;
var
  LPath: string;
begin
  LPath := TPath.GetDirectoryName(GetFileName);
  if not TDirectory.Exists(LPath) then
    TDirectory.CreateDirectory(LPath);
end;

function TLocalCacheManager.RemoveKey(const AKey: String): TLocalCacheManager;
begin
  Result := Self;
  FCriticalSection.Enter;
  try
    if GetLocalCacheList.ContainsKey(AKey) then
    begin
      GetLocalCacheList.Remove(AKey);
      SaveToFile;
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TLocalCacheManager.SaveToFile;
var
  LStringStream: TStringStream;
begin
  LStringStream := TStringStream.Create(CacheListToString, TEncoding.UTF8);
  try
    MakeCacheDir;
    LStringStream.SaveToFile(GetFileName);
  finally
    LStringStream.Free;
  end;
end;

function TLocalCacheManager.SetValue(const AKey: String; AValue: TValue): TLocalCacheManager;
begin
  Result := Self;
  FCriticalSection.Enter;
  try
    GetLocalCacheList.AddOrSetValue(AKey, AValue);
    SaveToFile;
  finally
    FCriticalSection.Leave;
  end;
end;

function TLocalCacheManager.SetValue<T>(const AKey: String; AValue: T): TLocalCacheManager;
var
  LValue: TValue;
begin
  LValue := TValue.From<T>(AValue);
  Result := SetValue(AKey, LValue);
end;

function TLocalCacheManager.TryGetValue(const AKey: String; out AValue: TValue; ADefault: TValue): TLocalCacheManager;
begin
  Result := Self;
  FCriticalSection.Enter;
  try
    if not GetLocalCacheList.TryGetValue(AKey, AValue) then
      AValue := ADefault;
  finally
    FCriticalSection.Leave;
  end;
end;

function TLocalCacheManager.TryGetValue<T>(const AKey: String; out AValue: T; ADefault: T): TLocalCacheManager;
var
  LValue: TValue;
begin
  Result := TryGetValue(AKey, LValue, TValue.From<T>(ADefault));
  if (TTypeInfo(System.TypeInfo(T)^).Kind in [tkInteger, tkInt64]) and (LValue.Kind = tkFloat) then
    TValue.From<Integer>(Trunc(LValue.AsExtended)).TryAsType(AValue)
  else
    LValue.TryAsType(AValue);
end;

end.
