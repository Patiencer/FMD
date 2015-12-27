unit Batoto;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, WebsiteModules, uData, uBaseUnit, uDownloadsManager,
  accountmanagerdb, synautil, HTMLUtil, RegExpr;

implementation

const
  modulename = 'Batoto';
  urlroot = 'http://bato.to';
  urllogin = 'https://bato.to/forums/index.php?app=core&module=global&section=login&do=process';
  dirurls: array [0..1] of String = (
    '/comic/_/sp/',
    '/comic/_/comics/');
  perpage = 50;
  dirparam = '?sort_col=record_saved&sort_order=desc&per_page=';

var
  locklogin: TRTLCriticalSection;
  onlogin: Boolean = False;

function Login(var AHTTP: THTTPSendThread): Boolean;
var
  query: TXQueryEngineHTML;
  loginform: THTMLForm;
  key: string;
begin
  Result := False;
  if AHTTP = nil then Exit;
  if Account.Enabled[modulename] = False then Exit;
  if Account.Username[modulename] = '' then Exit;

  if TryEnterCriticalsection(locklogin) > 0 then
    with AHTTP do begin
      onlogin := True;
      Account.Status[modulename] := asChecking;
      Reset;
      Cookies.Clear;
      if GET(urlroot) then begin
        loginform := THTMLForm.Create;
        query := TXQueryEngineHTML.Create;
        try
          query.ParseHTML(StreamToString(Document));
          key := query.XPathString('//input[@name="auth_key"]/@value');
          if key <> '' then begin
            with loginform do begin
              Put('auth_key', key);
              Put('referer', 'https://bato.to/');
              Put('ips_username', Account.Username[modulename]);
              Put('ips_password', Account.Password[modulename]);
              Put('rememberMe', '1');
            end;
            Clear;
            Headers.Values['Referer'] := ' https://bato.to/';
            if POST(urllogin, loginform.GetData) then begin
              if ResultCode = 200 then begin
                Result := Cookies.Values['pass_hash'] <> '';
                if Result then begin
                  Account.Cookies[modulename] := GetCookies;
                  Account.Status[modulename] := asValid;
                end else
                  Account.Status[modulename] := asInvalid;
                Account.Save;
              end;
            end;
          end;
        finally
          query.Free;
          loginform.Free
        end;
      end;
      onlogin := False;
      if Account.Status[modulename] = asChecking then
        Account.Status[modulename] := asUnknown;
      LeaveCriticalsection(locklogin);
    end
  else
  begin
    while onlogin do Sleep(1000);
    if Result then AHTTP.Cookies.Text := Account.Cookies[modulename];
  end;
end;

function GETWithLogin(var AHTTP: THTTPSendThread; AURL: String): Boolean;
var
  s: String;
begin
  Result := False;
  AHTTP.Cookies.Text := Account.Cookies['Batoto'];
  if AHTTP.GET(AURL) then begin
    Result := True;
    if (Account.Enabled[modulename] = False) or (Account.Username[modulename] = '') then Exit;
    s := StreamToString(AHTTP.Document);
    Result := (Pos('class=''logged_in''', s) > 0) or (Pos('class="logged_in"', s) > 0);
    if not Result then
      if Login(AHTTP) then
         Result := AHTTP.GET(AURL);
    if not Result then begin
      AHTTP.Document.Clear;
      WriteStrToStream(AHTTP.Document, s);
    end;
  end;
end;

function GetDirectoryPageNumber(var MangaInfo: TMangaInformation;
  var Page: Integer; Module: TModuleContainer): Integer;
var
  Parse: TStringList;

  procedure ScanParse;
  var
    i: Integer;
    s: String;
  begin
    if Parse.Count > 0 then
      for i := 0 to Parse.Count - 1 do
        if (Pos('Page 1 of ', Parse.Strings[i]) > 0) then
        begin
          s := GetString(Parse.Strings[i] + '~!@', 'Page 1 of ', '~!@');
          Page := StrToInt(TrimLeft(TrimRight(s)));
          Break;
        end;
  end;

begin
  Result := NET_PROBLEM;
  Page := 1;
  if MangaInfo = nil then Exit;
  Parse := TStringList.Create;
  try
    MangaInfo.FHTTP.Cookies.Text := Account.Cookies[modulename];
    if MangaInfo.GetPage(TObject(Parse),
      Module.RootURL + dirurls[Module.CurrentDirectoryIndex] +
      dirparam + IntToStr(perpage), 3) then
    begin
      Result := INFORMATION_NOT_FOUND;
      ParseHTML(Parse.Text, Parse);
      if Parse.Count > 0 then
      begin
        Result := NO_ERROR;
        ScanParse;
      end;
    end;
  finally
    Parse.Free;
  end;
end;

function GetNameAndLink(var MangaInfo: TMangaInformation;
  const ANames, ALinks: TStringList; const AURL: String; Module: TModuleContainer): Integer;
var
  Parse: TStringList;
  s: String;
  p: Integer;

  procedure ScanParse;
  var
    i, j: Integer;
  begin
    j := -1;
    for i := 0 to Parse.Count - 1 do
      if (GetTagName(Parse[i]) = 'table') and
        (GetVal(Parse[i], 'class') = 'ipb_table topic_list hover_rows') then
      begin
        j := i;
        Break;
      end;
    if (j > -1) and (j < Parse.Count) then
      for i := j to Parse.Count - 1 do
        if Pos('</table', Parse[i]) <> 0 then
          Break
        else
        if GetTagName(Parse[i]) = 'a' then
        begin
          ALinks.Add(GetVal(Parse[i], 'href'));
          ANames.Add(CommonStringFilter(Parse[i + 1]));
        end;
  end;

begin
  Result := NET_PROBLEM;
  if MangaInfo = nil then Exit;
  s := Module.RootURL + dirurls[Module.CurrentDirectoryIndex] +
    dirparam + IntToStr(perpage);
  p := StrToIntDef(AURL, 0);
  if p > 0 then
    s += '&st=' + (IntToStr(p * perpage));
  Parse := TStringList.Create;
  try
    MangaInfo.FHTTP.Cookies.Text := Account.Cookies[modulename];
    if MangaInfo.GetPage(TObject(Parse), s, 3) then
    begin
      Result := INFORMATION_NOT_FOUND;
      ParseHTML(Parse.Text, Parse);
      if Parse.Count > 0 then
      begin
        Result := NO_ERROR;
        ScanParse;
      end;
    end;
  finally
    Parse.Free;
  end;
end;

function GetInfo(var MangaInfo: TMangaInformation; const AURL: String;
  const Reconnect: Integer; Module: TModuleContainer): Integer;
var
  query: TXQueryEngineHTML;
  v, w: IXQValue;
  s, t, l: String;
  i: Integer;
begin
  if MangaInfo = nil then Exit(UNKNOWN_ERROR);
  Result := NET_PROBLEM;
  with MangaInfo do begin
    mangaInfo.website := modulename;
    mangaInfo.url := FillHost(urlroot, AURL);
    while onlogin do Sleep(1000);
    FHTTP.Cookies.Text := Account.Cookies[modulename];
    if GETWithLogin(FHTTP, mangaInfo.url) then begin
      Result := NO_ERROR;
      query := TXQueryEngineHTML.Create;
      try
        query.ParseHTML(StreamToString(FHTTP.Document));
        with mangaInfo do begin
          coverLink := Query.XPathString('//div[@class="ipsBox"]//img/@src');
          if title = '' then
            title := Query.XPathString('//h1[@class="ipsType_pagetitle"]');
          for v in query.XPath('//table[@class="ipb_table"]//tr') do begin
            s := v.toString;
            if Pos('Author:', s) > 0 then authors:= GetRightValue('Author:', s)
            else if Pos('Artist:', s) > 0 then artists:= GetRightValue('Artist:', s)
            else if Pos('Description:', s) > 0 then summary:= GetRightValue('Description:', s)
            else if Pos('Status:', s) > 0 then begin
              if Pos('Ongoing', s) > 0 then status := '1'
              else status := '0';
            end;
          end;
          v := query.XPath('//table[@class="ipb_table"]//tr[starts-with(*, "Genres:")]/td/a');
          if v.Count > 0 then begin
            genres := '';
            for i := 1 to v.Count do AddCommaString(genres, v.get(i).toString);
          end;

          if OptionBatotoShowAllLang then
            s := '//table[@class="ipb_table chapters_list"]//tr[starts-with(@class, "row lang")]'
          else s := '//table[@class="ipb_table chapters_list"]//tr[starts-with(@class, "row lang_English")]';
          for v in query.XPath(s) do begin
            w := query.Engine.evaluateXPath3('td[1]/a', v.toNode);
            chapterLinks.Add(w.toNode.getAttribute('href'));
            t := w.toString;
            if OptionBatotoShowAllLang then begin
              l := query.Engine.evaluateXPath3('td[2]/div', v.toNode).toNode.getAttribute('title');
              if l <> '' then t += ' ['+ l +']';
            end;
            if OptionBatotoShowScanGroup then begin
              l := query.Engine.evaluateXPath3('td[3]', v.toNode).toString;
              if l <> '' then t += ' ['+ l +']';
            end;
            chapterName.Add(t);
          end;
          InvertStrings([chapterLinks, chapterName])
        end;
      finally
        query.Free;
      end;
    end else Result := INFORMATION_NOT_FOUND;
  end;
end;

function GetPageNumber(var DownloadThread: TDownloadThread; const AURL: String;
  Module: TModuleContainer): Boolean;
var
  source: TStringList;
  query: TXQueryEngineHTML;
  v: IXQValue;
  cid: String;
begin
  Result := False;
  if DownloadThread = nil then Exit;
  with DownloadThread.manager.container, DownloadThread.FHTTP do begin
    Cookies.Text := Account.Cookies[modulename];
    Headers.Values['Referer'] := ' ' + urlroot + '/reader';
    cid := SeparateRight(AURL, '/reader#');
    if GET(urlroot + '/areader?id=' + cid + '&p=1') then begin
      Result := True;
      source := TStringList.Create;
      query := TXQueryEngineHTML.Create;
      try
        source.LoadFromStream(Document);
        query.ParseHTML(source.Text);
        PageContainerLinks.Text := cid;
        if query.XPathString('//select[@id="page_select"]') <> '' then
          PageNumber := Query.XPath('//div[1]/ul/li/select[@id="page_select"]/option/@value').Count
        else begin
        // long-strip view
          PageLinks.Clear;
          for v in query.XPath('//div/img/@src') do
            PageLinks.Add(v.toString);
        end;
      finally
        query.Free;
        source.Free;
      end;
    end;
  end;
end;

function GetImageURL(var DownloadThread: TDownloadThread; const AURL: String;
  Module: TModuleContainer): Boolean;
var
  source: TStringList;
  query: TXQueryEngineHTML;
  rurl: String;
begin
  Result := False;
  if DownloadThread = nil then Exit;
  with DownloadThread.manager.container, DownloadThread.FHTTP do begin
    if PageContainerLinks.Text = '' then Exit;
    Cookies.Text := Account.Cookies[modulename];
    rurl := urlroot + '/areader?id=' + PageContainerLinks[0] + '&p=' + IntToStr(DownloadThread.WorkCounter + 1);
    Headers.Values['Referer'] := ' ' + Module.RootURL + '/reader';
    if GET(rurl) then begin
      Result := True;
      source := TStringList.Create;
      query := TXQueryEngineHTML.Create;
      try
        source.LoadFromStream(Document);
        query.ParseHTML(source.Text);
        PageLinks[DownloadThread.workCounter] := query.XPathString('//div[@id="full_image"]//img/@src');
      finally
        query.Free;
        source.Free;
      end;
    end;
  end;
end;

procedure RegisterModule;
begin
  with AddModule do
  begin
    Website := modulename;
    RootURL := urlroot;
    MaxTaskLimit := 1;
    MaxConnectionLimit := 3;
    AccountSupport := True;
    SortedList := True;
    InformationAvailable := True;
    TotalDirectory := Length(dirurls);
    OnGetDirectoryPageNumber := @GetDirectoryPageNumber;
    OnGetNameAndLink := @GetNameAndLink;
    OnGetInfo := @GetInfo;
    OnGetPageNumber := @GetPageNumber;
    OnGetImageURL := @GetImageURL;
    OnLogin := @Login;
  end;
end;

initialization
  InitCriticalSection(locklogin);
  RegisterModule;

finalization
  DoneCriticalsection(locklogin);

end.
