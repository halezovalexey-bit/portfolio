// MYCODING SAFETY CANDIDATE - NOT DEPLOYED / NOT ACCEPTED FOR LIVE USE.
// Original Mech1/Mech2 signal functions retained; safety and bookkeeping changed.
// Persistent peak: warning >=6%, latch >=10%, no live automatic bootstrap/reset.
// Strict broker stops only. Legacy soft-stop positions remain managed.
// Journal is a sandbox-only raw-deal ledger, not the old reports_course CSV.
#property copyright "Hermes course project"
#property link      "D:/mql5-ml"
#property version   "5.00"
#property description "MYCODING safety candidate: demo-only; persistent account/magic peak guard; fail-closed protected sends; raw deal ledger."

// MYCODING HFNEWS1 risk-only parser. SHA256 detects corruption, NOT a digital signature.
// No instructions, titles, paths, order directions or durable permissions from news.
enum HFNewsMode { OBSERVE=0, ENTRY_GUARD=1 };
input group "=== MYCODING news risk policy v1 ==="
input HFNewsMode InpNewsMode=OBSERVE; // shadow only until separate acceptance
input bool InpNewsFailClosed=true;
string HFNewsFile="HFNEWS_V1.snapshot"; // terminal-local Files only, no FILE_COMMON
bool HFNewsUInt(string s,long &v){int n=StringLen(s);if(n<1||n>10)return false;for(int i=0;i<n;i++){ushort c=StringGetCharacter(s,i);if(c<48||c>57)return false;}v=StringToInteger(s);return v>=0&&v<=4102444800;}
bool HFNewsHex(string s){if(StringLen(s)!=64)return false;for(int i=0;i<64;i++){ushort c=StringGetCharacter(s,i);if(!((c>=48&&c<=57)||(c>=97&&c<=102)))return false;}return true;}
string HFNewsHash(string s){uchar data[],key[],out[];int n=StringToCharArray(s,data,0,WHOLE_ARRAY,CP_UTF8);if(n<1)return "";ArrayResize(data,n-1);if(CryptEncode(CRYPT_HASH_SHA256,data,key,out)!=32)return "";string h="";for(int i=0;i<32;i++)h+=StringFormat("%02x",out[i]);return h;}
bool HFNewsFlag(string s){return s=="0"||s=="1";}
bool HFNewsEvaluate(string text,long now,string symbol,bool &healthy,bool &blocked,string &reason)
{
 healthy=false;blocked=false;reason="INVALID";
 if(now<=0||now>4102444800||StringLen(text)<1||StringLen(text)>65536||StringFind(text,"\r")>=0||StringSubstr(text,StringLen(text)-1)!="\n")return false;
 for(int i=0;i<StringLen(text);i++){ushort c=StringGetCharacter(text,i);if(c!=10&&(c<32||c>126))return false;}
 string lines[];int n=StringSplit(text,10,lines);if(n<7||lines[n-1]!="")return false;
 string body="";for(int i=0;i<n-2;i++)body+=lines[i]+"\n";
 if(lines[n-2]!="SHA256|"+HFNewsHash(body))return false;
 string head[];if(StringSplit(lines[0],124,head)!=4||head[0]!="HFNEWS1")return false;
 long gen,expiry,count;if(!HFNewsUInt(head[1],gen)||!HFNewsUInt(head[2],expiry)||!HFNewsUInt(head[3],count)||gen<=0||expiry<=gen||expiry-gen>1200||gen>now||now>expiry||count>256||n!=count+7)return false;
 string symbols[4]={"EURUSD","GBPUSD","XAUUSD","XAGUSD"};bool found=false,coverage=false;
 for(int i=0;i<4;i++){string c[];if(StringSplit(lines[i+1],124,c)!=3||c[0]!="C"||c[1]!=symbols[i]||!HFNewsFlag(c[2]))return false;if(c[1]==symbol){found=true;coverage=c[2]=="1";}}
 if(!found)return false;
 string ids[];ArrayResize(ids,(int)count);bool veto=false;string why="CLEAR";
 for(int i=0;i<count;i++){
  string e[];if(StringSplit(lines[i+5],124,e)!=11||e[0]!="E"||!HFNewsHex(e[1]))return false;
  for(int j=0;j<i;j++)if(ids[j]==e[1])return false;ids[i]=e[1];
  if((e[2]!="USD"&&e[2]!="EUR"&&e[2]!="GBP")||(e[3]!="rates"&&e[3]!="labor"&&e[3]!="inflation")||(e[4]!="S"&&e[4]!="P"&&e[4]!="N"))return false;
  for(int k=7;k<11;k++)if(!HFNewsFlag(e[k]))return false;
  long pub,schedule;if(!HFNewsUInt(e[5],pub)||!HFNewsUInt(e[6],schedule)||pub<=0||pub>gen||(e[4]=="S"&&schedule<=0)||(e[4]!="S"&&schedule!=0))return false;
  bool relevant=e[2]=="USD"||(e[2]=="EUR"&&symbol=="EURUSD")||(e[2]=="GBP"&&symbol=="GBPUSD");
  if(relevant&&e[7]=="1"&&e[8]=="0"&&e[9]=="1"&&e[10]=="1"){
   if(e[4]=="N"){coverage=false;why="UNKNOWN_EVENT_TIME";}
   if(e[4]=="S"&&now>=schedule-900&&now<=schedule+1800){veto=true;why="SCHEDULED_HIGH_IMPACT";}
   if(e[4]=="P"&&now>=pub&&now<=pub+1800){veto=true;why="PUBLICATION_RISK_WINDOW";}
  }
 }
 healthy=coverage;blocked=veto;reason=coverage||why=="UNKNOWN_EVENT_TIME"?why:"COVERAGE_UNKNOWN";return true;
}
bool HFNewsAdmit(bool healthy,bool blocked,HFNewsMode mode,bool failclosed){if(mode!=OBSERVE&&mode!=ENTRY_GUARD)return false;return mode==OBSERVE||(!blocked&&(healthy||!failclosed));}
long HFNewsClockUTC(){if(MQLInfoInteger(MQL_TESTER))return 0;return (long)TimeGMT();} // tester TimeGMT equals server time: no guessed offset
string HFNewsRead(){int h=FileOpen(HFNewsFile,FILE_READ|FILE_BIN);if(h==INVALID_HANDLE)return "";ulong size=FileSize(h);if(size<1||size>65536){FileClose(h);return "";}uchar data[];ArrayResize(data,(int)size);uint got=FileReadArray(h,data,0,(int)size);FileClose(h);if(got!=size)return "";return CharArrayToString(data,0,(int)size,CP_UTF8);}
bool HFNewsEntryGate(string symbol)
{
 bool healthy,blocked;string reason;long utc=HFNewsClockUTC();bool valid=HFNewsEvaluate(HFNewsRead(),utc,symbol,healthy,blocked,reason);
 bool allowed=HFNewsAdmit(valid&&healthy,blocked,InpNewsMode,InpNewsFailClosed);
 static string last="";static long logged=0;string state=symbol+"|"+(string)InpNewsMode+"|"+reason+"|"+(string)allowed;
 if(state!=last||utc-logged>=60){Print("MYCODING NEWS mode=",EnumToString(InpNewsMode)," symbol=",symbol," utc=",utc," reason=",reason," entry=",allowed," protective_exits=UNCHANGED; OBSERVE is shadow only");last=state;logged=utc;}
 return allowed;
}

// No include needed: SymbolInfoDouble / iTime / iATR are built-in MQL5 functions.

//====================================================================
//  INPUTS
//====================================================================
input group "=== account guard ==="
input long   InpExpectedLogin     = 0; // only this account may trade
input bool   InpRequireDemo       = true;      // only demo accounts
input bool   InpAllowTester       = true;      // waive login check inside Strategy Tester
input long   InpMagic             = 20260929;  // project magic (foreign magic never touched)

input group "=== mechanisms ==="
input bool   InpMech1             = true;      // weekend gap fade
input bool   InpMech2             = true;      // 55-day breakout continuation
input string InpMech1Symbols      = "EURUSD,GBPUSD,USDJPY";
input string InpMech2Symbols      = "XAUUSD,XAGUSD";

input group "=== mech 1 (gap fade, rules from the report) ==="
input double InpGapStopMult       = 1.0;       // stop = 1.0 * |gap| from entry
input int    InpGapTimeoutHours   = 168;       // 168 h = the measured primary horizon
input int    InpBreakHours        = 8;         // bar-time hole that counts as a weekend break
input double InpAtrQualityMin     = 0.35;      // skip gap if ATR before break < 0.35 * its 500-bar mean

input group "=== mech 2 (breakout continuation) ==="
input int    InpBreakoutLookback  = 55;        // 55-day extreme
input int    InpHoldDaysMech2     = 60;        // hold 60 days (t 4.42 gold / t 2.60 silver)
input double InpMech2StopAtrMult  = 1.5;       // protective stop 1.5 * ATR(D1)  (ADDED, not in report)

input group "=== risk ==="
input double InpRiskPercent       = 0.25;      // MYCODING default risk % equity
input double InpMaxLots           = 5.0;       // hard volume cap per trade
input double InpMaxNotionalEquity = 10.0;      // max notional = 10 x equity

input group "=== budget ==="
input int    InpMaxEntriesYearSym = 60;        // per instrument / calendar year
input int    InpMaxEntriesYearAll = 180;       // whole portfolio / calendar year

input group "=== journal / logging ==="
// MYCODING old absolute/junction CSV inputs removed: no live journal targets.
input bool   InpVerbose           = true;

//====================================================================
//  GLOBALS
//====================================================================
#define CMT_M1 "HF-M1GAP"
#define CMT_M2 "HF-M2BRK"

string   g_journal_file  = "";
string   g_journal_how   = "";
int      g_journal_h     = INVALID_HANDLE;
bool     g_trade_allowed = false;
string   g_block_reason  = "";
datetime g_last_gap_bar  = 0;      // last H1 bar already evaluated for a weekend gap
datetime g_last_d1_bar   = 0;      // last D1 bar already evaluated for a breakout
int      g_reject_lot    = 0;
int      g_skip_budget   = 0;
int      g_skip_quality  = 0;
int      g_h_atr_h1      = INVALID_HANDLE;
int      g_h_atr_d1      = INVALID_HANDLE;

//====================================================================
//  small helpers
//====================================================================
void Log(const string s)
{
   if(InpVerbose) Print(s);
}

bool StrHas(const string csv, const string item)
{
   string parts[];
   int n = StringSplit(csv, ',', parts);
   for(int i = 0; i < n; i++)
   {
      string p = parts[i];
      StringTrimLeft(p); StringTrimRight(p);
      StringToUpper(p);
      if(p == item) return true;
   }
   return false;
}

string SymUp(const string s)
{
   string t = s; StringToUpper(t); return t;
}

double NormLots(const string sym,double lots)
{
 double step=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP),minv=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN),maxv=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
 if(!MathIsValidNumber(lots)||lots<=0||!MathIsValidNumber(step)||step<=0||!MathIsValidNumber(minv)||minv<=0||!MathIsValidNumber(maxv)||maxv<minv)return 0;
 double cap=MathMin(lots,maxv);double units=MathFloor(cap/step);double result=NormalizeDouble(units*step,8);
 if(result>cap+1e-12)result=NormalizeDouble((units-1)*step,8);
 if(result<minv||result<=0||result>cap+1e-12||MathAbs(result/step-MathRound(result/step))>1e-6)return 0;
 return result;
}

ENUM_ORDER_TYPE_FILLING PickFilling(const string sym)
{
   int modes = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((modes & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

// money risk of 1 lot when the price moves 'dist' (price units)
double RiskPerLot(const string sym,double dist,ENUM_ORDER_TYPE side=ORDER_TYPE_BUY,double price=0)
{
   // MYCODING broker profit calculator, account currency; inconsistent tick-value metadata is not trusted.
   if(!MathIsValidNumber(dist)||dist<=0)return 0;
   if(price<=0)price=SymbolInfoDouble(sym,side==ORDER_TYPE_BUY?SYMBOL_ASK:SYMBOL_BID);
   double result=0,stop=side==ORDER_TYPE_BUY?price-dist:price+dist;
   if(stop<=0||!OrderCalcProfit(side,sym,1.0,price,stop,result)||!MathIsValidNumber(result)||result>=0)return 0;
   return -result;
}

// points per 1 price unit
double PointsPerPrice(const string sym)
{
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) return 0.0;
   return 1.0 / pt;
}

//====================================================================
//  JOURNAL
//====================================================================
// MYCODING raw ledger: deal IDs are strings (no double precision loss).
void WriteJournalHeader()
{
 FileWrite(g_journal_h,"deal","position_id","order","time","symbol","entry","volume","price","profit","commission","swap","fee","magic","login","END");
}
void JournalInit()
{
 g_journal_file=SafetyKey()+"_deals.csv";
 Print("MYCODING JOURNAL sandbox ledger ",g_journal_file,"; handles reopened exclusively per append");
}
bool OwnComment(string c){return StringFind(c,CMT_M1)==0||StringFind(c,CMT_M2)==0;}
// MYCODING conservative whole-position provenance, including reversal inventory.
string QuarantineFile(string sym){return SafetyKey()+"_"+sym+"_mixed.quarantine";}
// MYCODING D2: sticky per-instance fault, never cleared by a later healthy ledger/replay.
// Restart re-detects mixed inventory from history before any send; no auto owner reset.
bool g_quarantine_fault=false;
bool Quarantine(string sym,ulong pos,string reason)
{
 string text="MYCODING mixed ownership; position="+(string)pos+" "+reason+"; OWNER REVIEW REQUIRED\r\n";
 int h=FileOpen(QuarantineFile(sym),FILE_WRITE|FILE_TXT|FILE_ANSI);
 if(h==INVALID_HANDLE){g_quarantine_fault=true;Print("MYCODING QUARANTINE PERSIST FAILED ",sym);return false;}
 ResetLastError();uint n=FileWriteString(h,text);FileFlush(h);bool ok=n==(uint)StringLen(text)&&GetLastError()==0;FileClose(h);
 if(ok){h=FileOpen(QuarantineFile(sym),FILE_READ|FILE_TXT|FILE_ANSI);ok=h!=INVALID_HANDLE;if(ok){ok=FileReadString(h)==StringSubstr(text,0,StringLen(text)-2)&&FileIsEnding(h);FileClose(h);}}
 if(!ok){g_quarantine_fault=true;Print("MYCODING QUARANTINE PERSIST FAILED ",sym);}else Print("MYCODING MIXED QUARANTINE PERSISTED ",sym," position=",pos);
 return ok;
}
// MYCODING D1: a failed history API is not foreign ownership.
enum OwnershipStatus { OWN, FOREIGN, MIXED, UNKNOWN_ERROR };
bool g_history_fault=false;
OwnershipStatus HistoryFault(){g_history_fault=true;return UNKNOWN_ERROR;}
OwnershipStatus PositionOwnership(ulong pos,string sym,bool persist=true)
{
 ResetLastError();if(pos==0||!HistorySelectByPosition(pos))return HistoryFault();
 bool owned=false,foreign=false;int count=HistoryDealsTotal();if(GetLastError()!=0||count<=0)return HistoryFault();
 for(int i=0;i<count;i++){
  ResetLastError();ulong d=HistoryDealGetTicket(i);long ty=HistoryDealGetInteger(d,DEAL_TYPE);
  if(d==0||GetLastError()!=0)return HistoryFault();
  if(ty!=DEAL_TYPE_BUY&&ty!=DEAL_TYPE_SELL)continue;
  long e=HistoryDealGetInteger(d,DEAL_ENTRY);if(GetLastError()!=0)return HistoryFault();
  if(e!=DEAL_ENTRY_IN&&e!=DEAL_ENTRY_INOUT)continue;
  string ds=HistoryDealGetString(d,DEAL_SYMBOL),comment=HistoryDealGetString(d,DEAL_COMMENT);long magic=HistoryDealGetInteger(d,DEAL_MAGIC);
  if(GetLastError()!=0)return HistoryFault();
  if(ds==sym&&magic==InpMagic&&OwnComment(comment))owned=true;else foreign=true;
 }
 if(owned&&foreign){if(persist&&!Quarantine(sym,pos,"foreign IN/INOUT"))g_quarantine_fault=true;return MIXED;}
 if(owned)return OWN;if(foreign)return FOREIGN;return HistoryFault();
}
bool PositionOwned(ulong pos,string sym,bool persist=true){return PositionOwnership(pos,sym,persist)==OWN;}
OwnershipStatus DealOwnership(ulong deal)
{
 ResetLastError();if(deal==0||!HistoryDealSelect(deal))return HistoryFault();
 string sym=HistoryDealGetString(deal,DEAL_SYMBOL);long ty=HistoryDealGetInteger(deal,DEAL_TYPE);
 if(GetLastError()!=0)return HistoryFault();
 if(sym!=_Symbol||(ty!=DEAL_TYPE_BUY&&ty!=DEAL_TYPE_SELL))return FOREIGN;
 ulong pos=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);if(GetLastError()!=0)return HistoryFault();
 return PositionOwnership(pos,sym);
}
bool DealOwned(ulong deal){return DealOwnership(deal)==OWN;}
// MYCODING canonical history equality, no money tokens trusted from disk.
string LedgerHeader(){return "deal,position_id,order,time,symbol,entry,volume,price,profit,commission,swap,fee,magic,login,END";}
// MYCODING F1: valid zero is data; getter failure is never canonical truth.
bool AccountingInteger(ulong d,ENUM_DEAL_PROPERTY_INTEGER p,long &v)
{
 ResetLastError();bool ok=HistoryDealGetInteger(d,p,v);if(!ok||GetLastError()!=0){g_history_fault=true;return false;}return true;
}
bool AccountingDouble(ulong d,ENUM_DEAL_PROPERTY_DOUBLE p,double &v)
{
 ResetLastError();bool ok=HistoryDealGetDouble(d,p,v);if(!ok||GetLastError()!=0||!MathIsValidNumber(v)){g_history_fault=true;return false;}return true;
}
bool AccountingString(ulong d,ENUM_DEAL_PROPERTY_STRING p,string &v)
{
 ResetLastError();bool ok=HistoryDealGetString(d,p,v);if(!ok||GetLastError()!=0){g_history_fault=true;return false;}return true;
}
string DealRow(ulong d)
{
 ResetLastError();if(d==0||!HistoryDealSelect(d)||GetLastError()!=0){g_history_fault=true;return "";}
 long pos,order,tm,entry,magic;string sym;double vol,price,profit,commission,swap,fee;
 if(!AccountingInteger(d,DEAL_POSITION_ID,pos)||!AccountingInteger(d,DEAL_ORDER,order)||!AccountingInteger(d,DEAL_TIME_MSC,tm)||!AccountingString(d,DEAL_SYMBOL,sym)||!AccountingInteger(d,DEAL_ENTRY,entry)||
 !AccountingDouble(d,DEAL_VOLUME,vol)||!AccountingDouble(d,DEAL_PRICE,price)||!AccountingDouble(d,DEAL_PROFIT,profit)||!AccountingDouble(d,DEAL_COMMISSION,commission)||!AccountingDouble(d,DEAL_SWAP,swap)||!AccountingDouble(d,DEAL_FEE,fee)||!AccountingInteger(d,DEAL_MAGIC,magic))return "";
 ResetLastError();long login=AccountInfoInteger(ACCOUNT_LOGIN);if(GetLastError()!=0){g_history_fault=true;return "";}
 return (string)d+","+(string)pos+","+(string)order+","+(string)tm+","+sym+","+(string)entry+","+DoubleToString(vol,8)+","+DoubleToString(price,8)+","+DoubleToString(profit,8)+","+DoubleToString(commission,8)+","+DoubleToString(swap,8)+","+DoubleToString(fee,8)+","+(string)magic+","+(string)login+",END";
}
bool ValidateLedgerHandle(int h)
{
 FileSeek(h,0,SEEK_SET);if(FileIsEnding(h)||FileReadString(h)!=LedgerHeader())return false;
 string seen[];int n=0;
 while(!FileIsEnding(h)){
  string line=FileReadString(h);if(line=="")continue;
  string f[];if(StringSplit(line,',',f)!=15)return false;
  ulong d=(ulong)StringToInteger(f[0]);if(d==0||(string)d!=f[0])return false;
  for(int j=0;j<n;j++)if(seen[j]==f[0])return false;
  ArrayResize(seen,++n);seen[n-1]=f[0];
  ResetLastError();if(!HistoryDealSelect(d)||GetLastError()!=0){g_history_fault=true;return false;}
  string sym;long pos;
  if(!AccountingString(d,DEAL_SYMBOL,sym)||!AccountingInteger(d,DEAL_POSITION_ID,pos))return false;
  if(!PositionOwned((ulong)pos,sym))return false;
  string canonical=DealRow(d);if(canonical==""||line!=canonical)return false;
 }
 return true;
}
void LedgerFault()
{
 // Preserve original exactly. Backup is append-only named with unique timestamp/counter.
 static int seq=0;string backup=g_journal_file+".corrupt_"+(string)(long)TimeCurrent()+"_"+(string)(seq++);
 bool copied=FileIsExist(g_journal_file)&&FileCopy(g_journal_file,0,backup,0);
 Print("MYCODING LEDGER UNHEALTHY; entries blocked; original retained; backup_ok=",copied,"; history rebuild needs owner approval ",backup);
}
bool LedgerHealthy()
{
 if(g_journal_file=="")JournalInit();
 if(!FileIsExist(g_journal_file)){
  if(!MQLInfoInteger(MQL_TESTER))return false;
  int seed=FileOpen(g_journal_file,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
  if(seed==INVALID_HANDLE)return false;
  if(FileSize(seed)==0)FileWriteString(seed,LedgerHeader()+"\r\n");FileFlush(seed);FileClose(seed);
 }
 int h=FileOpen(g_journal_file,FILE_READ|FILE_TXT|FILE_ANSI);if(h==INVALID_HANDLE)return false;
 bool ok=ValidateLedgerHandle(h);FileClose(h);if(!ok)LedgerFault();return ok;
}
bool JournalDeal(ulong deal)
{
 if(!DealOwned(deal))return false;
 if(!LedgerHealthy())return false;
 int h=FileOpen(g_journal_file,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);if(h==INVALID_HANDLE)return false;
 bool ok=ValidateLedgerHandle(h),found=false;
 if(ok){FileSeek(h,0,SEEK_SET);while(!FileIsEnding(h)){string row=FileReadString(h);if(StringFind(row,(string)deal+",")==0)found=true;}}
 if(!ok){FileClose(h);LedgerFault();return false;}if(found){FileClose(h);return true;}
 string row=DealRow(deal);if(row==""){FileClose(h);return false;}
 FileSeek(h,0,SEEK_END);ResetLastError();uint n=FileWriteString(h,row+"\r\n");FileFlush(h);ok=n>0&&GetLastError()==0;FileClose(h);return ok;
}

// MYCODING explicit recovery helper, callable only by separately approved offline/tester harness.
// No automatic production caller; approval MUST NOT be inferred from an input/deploy.
bool RebuildLedgerFromHistory(bool approved)
{
 if(!approved||!MQLInfoInteger(MQL_TESTER))return false;
 int lock=FileOpen(SafetyKey()+"_entry.lock",FILE_READ|FILE_WRITE|FILE_BIN);if(lock==INVALID_HANDLE)return false;
 if(g_journal_file=="")JournalInit();
 static int seq=0;string suffix=(string)(long)TimeCurrent()+"_"+(string)(seq++),backup=g_journal_file+".recovery_original_"+suffix,temp=g_journal_file+".rebuild_"+suffix;
 if(FileIsExist(g_journal_file)&&!FileCopy(g_journal_file,0,backup,0)){FileClose(lock);return false;}
 ResetLastError();if(!HistorySelect(0,TimeCurrent())||GetLastError()!=0){g_history_fault=true;FileClose(lock);return false;}
 ulong ids[];ResetLastError();int n=HistoryDealsTotal();if(GetLastError()!=0){g_history_fault=true;FileClose(lock);return false;}
 ArrayResize(ids,n);for(int i=0;i<n;i++){ResetLastError();ids[i]=HistoryDealGetTicket(i);if(ids[i]==0||GetLastError()!=0){g_history_fault=true;FileClose(lock);return false;}}
 int h=FileOpen(temp,FILE_WRITE|FILE_TXT|FILE_ANSI);if(h==INVALID_HANDLE){FileClose(lock);return false;}
 bool ok=FileWriteString(h,LedgerHeader()+"\r\n")>0;
 for(int i=0;i<n&&ok;i++){
  ResetLastError();if(!HistoryDealSelect(ids[i])||GetLastError()!=0){g_history_fault=true;ok=false;break;}
  long ty;if(!AccountingInteger(ids[i],DEAL_TYPE,ty)){ok=false;break;}if(ty!=DEAL_TYPE_BUY&&ty!=DEAL_TYPE_SELL)continue;
  long pos;string sym;if(!AccountingInteger(ids[i],DEAL_POSITION_ID,pos)||!AccountingString(ids[i],DEAL_SYMBOL,sym)){ok=false;break;}
  OwnershipStatus status=PositionOwnership((ulong)pos,sym);
  if(status==UNKNOWN_ERROR||status==MIXED){ok=false;break;}
  if(status==OWN){string row=DealRow(ids[i]);if(row==""||FileWriteString(h,row+"\r\n")==0)ok=false;}
  if(FileIsExist(QuarantineFile(sym)))ok=false; // ambiguous history cannot be silently discarded
 }
 FileFlush(h);FileClose(h);
 if(ok){h=FileOpen(temp,FILE_READ|FILE_TXT|FILE_ANSI);ok=h!=INVALID_HANDLE&&ValidateLedgerHandle(h);if(h!=INVALID_HANDLE)FileClose(h);}
 if(ok)ok=FileMove(temp,0,g_journal_file,FILE_REWRITE);
 // MYCODING D1 recovery regression: an approved, fully validated history rebuild is itself
 // a complete accounting revalidation. Clear only history/accounting fault, NEVER mixed fault.
 if(ok)g_history_fault=false;
 FileClose(lock);return ok;
}

bool ReplayHistory()
{
 if(!HistorySelect(0,TimeCurrent())){g_history_fault=true;Print("MYCODING HISTORY unavailable");return false;}
 ulong deals[];ResetLastError();int n=HistoryDealsTotal();ArrayResize(deals,n);bool ok=GetLastError()==0;
 for(int i=0;i<n;i++){ResetLastError();deals[i]=HistoryDealGetTicket(i);if(deals[i]==0||GetLastError()!=0)ok=false;}
 for(int i=0;i<n;i++){
  OwnershipStatus status=DealOwnership(deals[i]);
  if(status==UNKNOWN_ERROR)ok=false;
  else if(status==OWN&&!JournalDeal(deals[i]))ok=false;
 }
 g_history_fault=!ok;return ok&&!g_quarantine_fault;
}

//====================================================================
//  ACCOUNT GUARD
//====================================================================
// MYCODING: durable state is local to this terminal, shared by account/server/magic.
// No automatic live bootstrap/reset. Missing/corrupt state requires owner review.
string SafetyKey()
{
   string server=AccountInfoString(ACCOUNT_SERVER);
   StringReplace(server,"/","_"); StringReplace(server,"\\","_"); StringReplace(server,":","_");
   return "HFSAFE_"+server+"_"+(string)AccountInfoInteger(ACCOUNT_LOGIN)+"_"+(string)InpMagic;
}
string GuardFile(){return SafetyKey()+"_guard.bin";}
bool StoreGuard(int h,double peak,double latch)
{
   FileSeek(h,0,SEEK_SET);
   ResetLastError();
   FileWriteDouble(h,1); FileWriteDouble(h,peak); FileWriteDouble(h,latch); FileWriteDouble(h,peak+latch+7919);
   FileFlush(h); return GetLastError()==0;
}
void TesterSeedGuard()
{
   if(!MQLInfoInteger(MQL_TESTER))return;
   int h=FileOpen(GuardFile(),FILE_READ|FILE_WRITE|FILE_BIN);
   if(h==INVALID_HANDLE)return;
   if(FileSize(h)==0){StoreGuard(h,AccountInfoDouble(ACCOUNT_EQUITY),0);Print("MYCODING TESTER ONLY bootstrap guard");}
   FileClose(h);
}
bool PeakGuard()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(!MathIsValidNumber(eq)||eq<=0)return false;
   int h=FileOpen(GuardFile(),FILE_READ|FILE_WRITE|FILE_BIN);
   if(h==INVALID_HANDLE)return false; // exclusive OS file lock; contention blocks, never steals
   if(FileSize(h)!=32){FileClose(h);Print("MYCODING GUARD missing/corrupt state - entries blocked");return false;}
   double v=FileReadDouble(h),peak=FileReadDouble(h),latch=FileReadDouble(h),check=FileReadDouble(h);
   if(v!=1||!MathIsValidNumber(peak)||peak<=0||(latch!=0&&latch!=1)||check!=peak+latch+7919){FileClose(h);return false;}
   double old=peak,old_latch=latch;
   peak=MathMax(peak,eq);
   double dd=100*(peak-eq)/peak;
   if(dd>=10)latch=1;
   bool saved=true;
   if(peak!=old||latch!=old_latch)saved=StoreGuard(h,peak,latch);
   FileClose(h);
   static bool warned=false;
   if(dd>=6&&!warned){PrintFormat("MYCODING GUARD WARNING drawdown=%.4f%% peak=%.2f latch=%.0f",dd,peak,latch);warned=true;}
   return saved&&latch==0;
}
bool FreshAccount()
{
   bool tester=(bool)MQLInfoInteger(MQL_TESTER);
   if(tester&&InpAllowTester)return true;
   return AccountInfoInteger(ACCOUNT_LOGIN)==InpExpectedLogin &&
          AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO;
}
// MYCODING unadjusted sampled peak domain: freeze nontrade cashflows at approved anchor.
// Any deposit/withdrawal/charge/change blocks entries; no automated peak rebasing.
string CashflowSignature()
{
 if(!HistorySelect(0,TimeCurrent()))return "";string text="CF_V2";
 for(int i=0;i<HistoryDealsTotal();i++){
  ulong d=HistoryDealGetTicket(i);long ty=HistoryDealGetInteger(d,DEAL_TYPE);
  if(ty==DEAL_TYPE_BUY||ty==DEAL_TYPE_SELL)continue;
  text+="|"+(string)d+":"+(string)ty;
  text+=":"+DoubleToString(HistoryDealGetDouble(d,DEAL_PROFIT),8)+":"+DoubleToString(HistoryDealGetDouble(d,DEAL_COMMISSION),8)+":"+DoubleToString(HistoryDealGetDouble(d,DEAL_SWAP),8)+":"+DoubleToString(HistoryDealGetDouble(d,DEAL_FEE),8);
 }
 return text;
}
bool CashflowStable()
{
 string signature=CashflowSignature(),f=SafetyKey()+"_cashflow.anchor";if(signature=="")return false;
 if(!FileIsExist(f)){
  if(!MQLInfoInteger(MQL_TESTER))return false;
  int seed=FileOpen(f,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);if(seed==INVALID_HANDLE)return false;
  if(FileSize(seed)==0)FileWriteString(seed,signature+"\r\n");FileFlush(seed);FileClose(seed);Print("MYCODING TESTER ONLY cashflow anchor");
 }
 int h=FileOpen(f,FILE_READ|FILE_TXT|FILE_ANSI);if(h==INVALID_HANDLE)return false;
 bool ok=FileReadString(h)==signature&&FileIsEnding(h);FileClose(h);
 if(!ok)Print("MYCODING CASHFLOW CHANGE/ANCHOR CORRUPTION; entries blocked; no peak reset");return ok;
}
bool EntrySafety()
{
   if(!FreshAccount())return false;
   if(!MQLInfoInteger(MQL_TESTER)&&(!TerminalInfoInteger(TERMINAL_CONNECTED)||!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)||!MQLInfoInteger(MQL_TRADE_ALLOWED)))return false;
   return !g_quarantine_fault&&!g_history_fault&&PeakGuard()&&CashflowStable()&&LedgerHealthy();
}
bool CheckAccount()
{
   long login   = AccountInfoInteger(ACCOUNT_LOGIN);
   long mode    = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   bool is_demo = (mode == ACCOUNT_TRADE_MODE_DEMO);
   bool is_test = (bool)MQLInfoInteger(MQL_TESTER);
   bool login_ok = (login == InpExpectedLogin);
   bool mode_ok  = (InpRequireDemo ? is_demo : true);

   bool allowed = (login_ok && mode_ok);
   if(!allowed && is_test && InpAllowTester)
      allowed = true;                       // tester waiver, printed loudly below

   g_trade_allowed = allowed;
   if(!allowed)
   {
      g_block_reason = StringFormat("login=%I64d (need %I64d), trade_mode=%I64d (demo=%s)",
                                    login, InpExpectedLogin, mode, (is_demo ? "yes" : "NO"));
   }
   else
   {
      g_block_reason = "";
   }
   PrintFormat("GUARD: login=%I64d  trade_mode=%I64d (demo=%s)  tester=%s  login_ok=%s  ->  trading %s%s",
               login, mode, (is_demo ? "yes" : "no"), (is_test ? "yes" : "no"),
               (login_ok ? "yes" : "no"), (allowed ? "ACCOUNT_ELIGIBLE_ONLY" : "BLOCKED"),
               (!login_ok && allowed) ? "  [TESTER WAIVER ACTIVE]" : "");
   if(!allowed)
      Print("GUARD: blocked - reason: ", g_block_reason);
   return allowed;
}

//====================================================================
//  POSITION HELPERS  (own magic only - foreign positions are invisible)
//====================================================================
bool OwnPos(const string sym, const string cmt_prefix, ulong &ticket, double &lots,
            double &open_price, double &sl, double &tp, datetime &opened, long &type)
{
   if(sym!=_Symbol||!FreshAccount())return false; // MYCODING chart owns only its symbol
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;   // foreign magic: skip
      string ps = PositionGetString(POSITION_SYMBOL);
      if(ps != sym) continue;
      string pc = PositionGetString(POSITION_COMMENT);
      if(StringFind(pc, cmt_prefix) != 0) continue;                   // foreign comment: skip
      ulong provenance_id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(!PositionOwned(provenance_id,sym)||!PositionSelectByTicket(tk))continue;
      ticket     = tk;
      lots       = PositionGetDouble(POSITION_VOLUME);
      open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      sl         = PositionGetDouble(POSITION_SL);
      tp         = PositionGetDouble(POSITION_TP);
      opened     = (datetime)PositionGetInteger(POSITION_TIME);
      type       = PositionGetInteger(POSITION_TYPE);
      return true;
   }
   return false;
}

bool CloseOwn(const string sym,const string cmt_prefix,const string reason)
{
 if(sym!=_Symbol||!FreshAccount())return false;
 int lock=FileOpen(SafetyKey()+"_entry.lock",FILE_READ|FILE_WRITE|FILE_BIN);if(lock==INVALID_HANDLE)return false;
 bool ok=CloseOwnLocked(sym,cmt_prefix,reason);FileClose(lock);return ok;
}
bool CloseOwnLocked(const string sym, const string cmt_prefix, const string reason)
{
 if(FileIsExist(PendingFile(sym,"EXIT"))||FileIsExist(PendingFile(sym,"ENTRY"))||SymbolOrder(sym))return false;
   ulong tk; double lots, op, sl, tp; datetime t; long ty;
   if(!OwnPos(sym, cmt_prefix, tk, lots, op, sl, tp, t, ty)) return false;

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = sym;
   req.position  = tk;
   req.volume    = lots;
   req.deviation = 50;
   req.magic     = InpMagic;
   req.comment   = cmt_prefix + "-CLOSE";
   req.type      = (ty == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price     = (ty == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID)
                                             : SymbolInfoDouble(sym, SYMBOL_ASK);
   req.type_filling = PickFilling(sym);
   ulong pos=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   if(!BeginIntent(sym,"EXIT",req))return false;
   ulong before[];if(!CaptureDeals(before))return false;long sent_msc=(long)TimeCurrent()*1000;
   bool ok=OrderSend(req,res);
   if(!RecordResult(sym,"EXIT",res))return false;
   bool done=ok&&(res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_DONE_PARTIAL);
   if(!done){if(DefinitiveReject(res.retcode))FileDelete(PendingFile(sym,"EXIT"));Print("MYCODING EXIT unresolved/reject retcode=",res.retcode);return false;}
   if(!FreshExecution(req,res,before,sent_msc)||SymbolOrder(sym)||!HistoryDealSelect(res.deal))return false;
   long e=HistoryDealGetInteger(res.deal,DEAL_ENTRY);double v=HistoryDealGetDouble(res.deal,DEAL_VOLUME);
   if((e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_OUT_BY)||(ulong)HistoryDealGetInteger(res.deal,DEAL_POSITION_ID)!=pos||HistoryDealGetString(res.deal,DEAL_SYMBOL)!=sym||v<=0||v>lots+1e-9||!PositionOwned(pos,sym))return false;
   double residual=0;if(PositionSelectByTicket(tk)){
    if((ulong)PositionGetInteger(POSITION_IDENTIFIER)!=pos||PositionGetInteger(POSITION_TYPE)!=ty)return false;
    residual=PositionGetDouble(POSITION_VOLUME);
   }
   if(MathAbs(residual-(lots-v))>1e-8)return false;
   JournalDeal(res.deal);if(!FileDelete(PendingFile(sym,"EXIT")))return false;
   PrintFormat("MYCODING CLOSE confirmed deal=%I64u executed=%.8f residual=%.8f reason=%s",res.deal,v,residual,reason);
   return true;
}

//--- software levels for positions whose broker-side stops were rejected -------------
string SoftName(const ulong posid, const string tag)
{
   return StringFormat("HF%s%s", IntegerToString((long)posid), tag);
}

void SetSoftLevels(const ulong posid, const double sl, const double tp)
{
   if(posid == 0) return;
   GlobalVariableSet(SoftName(posid, "SL"), sl);
   GlobalVariableSet(SoftName(posid, "TP"), tp);
}

bool GetSoftLevels(const ulong posid, double &sl, double &tp)
{
   if(posid == 0) return false;
   if(!GlobalVariableCheck(SoftName(posid, "SL"))) return false;
   sl = GlobalVariableGet(SoftName(posid, "SL"));
   tp = GlobalVariableGet(SoftName(posid, "TP"));
   return true;
}

void ClearSoftLevels(const ulong posid)
{
   if(posid == 0) return;
   if(GlobalVariableCheck(SoftName(posid, "SL"))) GlobalVariableDel(SoftName(posid, "SL"));
   if(GlobalVariableCheck(SoftName(posid, "TP"))) GlobalVariableDel(SoftName(posid, "TP"));
}

// exit exactly on the rule levels when the broker refused to hold them
void EnforceSoftLevels()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;      // foreign magic: skip
      string sym = PositionGetString(POSITION_SYMBOL);
      string cmt = PositionGetString(POSITION_COMMENT);
      if(!OwnComment(cmt)) continue;
      ulong posid = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      double sl, tp;
      if(!GetSoftLevels(posid, sl, tp)) continue;
      static ulong warned=0;
      if(warned!=posid){PrintFormat("MYCODING LEGACY SOFT-STOPS WARNING position_id=%I64u; protection depends on terminal/connectivity",posid);warned=posid;}
      long ty = PositionGetInteger(POSITION_TYPE);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      string why = "";
      if(ty == POSITION_TYPE_BUY)
      {
         if(sl > 0.0 && bid <= sl) why = "soft STOP (rule level)";
         else if(tp > 0.0 && bid >= tp) why = "soft TARGET (rule level)";
      }
      else
      {
         if(sl > 0.0 && ask >= sl) why = "soft STOP (rule level)";
         else if(tp > 0.0 && ask <= tp) why = "soft TARGET (rule level)";
      }
      if(why != "")
      {
         string pref = (StringFind(cmt, CMT_M1) >= 0 ? CMT_M1 : CMT_M2);
         CloseOwn(sym, pref, why);
      }
   }
}

//====================================================================
//  EXIT JOURNAL (single source of truth for every close)
//====================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
 if(!FreshAccount()||trans.type!=TRADE_TRANSACTION_DEAL_ADD||trans.deal==0)return;
 JournalDeal(trans.deal);
 // Partial exits must not delete legacy soft levels for the remaining position.
}

//====================================================================
//  BUDGET
//====================================================================
int EntriesThisYear(const string sym, const string cmt_prefix)
{
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   datetime y0 = StringToTime(StringFormat("%04d.01.01 00:00", st.year));
   if(!HistorySelect(y0, TimeCurrent() + 86400)) return -1;
   int deals = HistoryDealsTotal(), cnt = 0;
   ulong orders[];ArrayResize(orders,deals);
   for(int i = 0; i < deals; i++)
   {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0) continue;
      if((long)HistoryDealGetInteger(dt, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(dt, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      if(sym != "" && HistoryDealGetString(dt, DEAL_SYMBOL) != sym) continue;
      string c = HistoryDealGetString(dt, DEAL_COMMENT);
      if(cmt_prefix != "" && StringFind(c, cmt_prefix) < 0) continue;
      ulong order=(ulong)HistoryDealGetInteger(dt,DEAL_ORDER);
      if(order==0)return -1;
      bool found=false;for(int j=0;j<cnt;j++)if(orders[j]==order)found=true;
      if(!found)orders[cnt++]=order;
   }
   return cnt;
}

// MYCODING conservative durable reservation, never refunds an uncertain/failed send.
// Caller must hold portfolio _entry.lock. Format year,total,5 symbol counts,END.
bool UIntToken(string t,int &v)
{
 if(t==""||StringLen(t)>9)return false;
 for(int j=0;j<StringLen(t);j++)if(StringGetCharacter(t,j)<'0'||StringGetCharacter(t,j)>'9')return false;
 v=(int)StringToInteger(t);return (string)v==t;
}
bool BudgetRow(string row,int &year,int &total,int &c[])
{
 string f[];if(StringSplit(row,',',f)!=8||f[7]!="END"||!UIntToken(f[0],year)||!UIntToken(f[1],total))return false;
 if(year<2000||year>2100||total>180)return false;int sum=0;
 for(int i=0;i<5;i++){if(!UIntToken(f[i+2],c[i])||c[i]>60)return false;sum+=c[i];}
 return sum==total;
}
string BudgetText(int y,int n,int &c[]){string s=(string)y+","+(string)n;for(int i=0;i<5;i++)s+=","+(string)c[i];return s+",END";}
bool ReserveBudget(string sym)
{
 string syms[5]={"EURUSD","GBPUSD","USDJPY","XAUUSD","XAGUSD"};int index=-1;
 for(int i=0;i<5;i++)if(sym==syms[i])index=i;
 if(index<0||InpMaxEntriesYearSym<=0||InpMaxEntriesYearAll<=0)return false;
 MqlDateTime st;TimeToStruct(TimeCurrent(),st);
 string f=SafetyKey()+"_budget.csv",w=SafetyKey()+"_budget.witness";
 if(!FileIsExist(f)&&!MQLInfoInteger(MQL_TESTER))return false;
 int h=FileOpen(f,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);if(h==INVALID_HANDLE)return false;
 int y=0,n=0,c[5]={0,0,0,0,0},lasty=0,lastn=0,lastc[5]={0,0,0,0,0};string last="";bool valid=true;
 while(!FileIsEnding(h)){
  string row=FileReadString(h);if(row==""){valid=false;break;}
  if(!BudgetRow(row,y,n,c)){valid=false;break;}
  if(last!=""){
   if(y==lasty){int increments=0;if(n!=lastn+1)valid=false;for(int i=0;i<5;i++){int d=c[i]-lastc[i];if(d==1)increments++;else if(d!=0)valid=false;}if(increments!=1)valid=false;}
   else{if(y!=lasty+1||n!=1)valid=false;}
  }
  if(!valid)break;last=row;lasty=y;lastn=n;for(int i=0;i<5;i++)lastc[i]=c[i];
 }
 if(!valid){FileClose(h);Print("MYCODING BUDGET semantic corruption/rollback - blocked");return false;}
 if(last==""){
  if(!MQLInfoInteger(MQL_TESTER)||FileIsExist(w)){FileClose(h);return false;}
  last=BudgetText(st.year,0,c);lasty=st.year;lastn=0;
  FileWriteString(h,last+"\r\n");FileFlush(h);Print("MYCODING TESTER ONLY budget initial seed");
 }
 if(!FileIsExist(w)){
  if(!MQLInfoInteger(MQL_TESTER)){FileClose(h);return false;}
  int seed=FileOpen(w,FILE_WRITE|FILE_TXT|FILE_ANSI);if(seed==INVALID_HANDLE){FileClose(h);return false;}
  FileWriteString(seed,last+"\r\n");FileFlush(seed);FileClose(seed);Print("MYCODING TESTER ONLY witness initial seed");
 }
 int wh=FileOpen(w,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);if(wh==INVALID_HANDLE){FileClose(h);return false;}
 string witness=FileReadString(wh);
 if(witness!=last||!FileIsEnding(wh)||lasty>st.year||st.year>lasty+1){FileClose(wh);FileClose(h);Print("MYCODING BUDGET witness mismatch/missing state - blocked");return false;}
 if(lasty!=st.year){lastn=0;for(int i=0;i<5;i++)lastc[i]=0;}
 // History is a lower bound, not a reason to silently rewrite durable reservations.
 int historical=EntriesThisYear("","");if(historical<0||historical>lastn){FileClose(wh);FileClose(h);return false;}
 for(int i=0;i<5;i++){int history=EntriesThisYear(syms[i],"");if(history<0||history>lastc[i]){FileClose(wh);FileClose(h);return false;}}
 if(lastn>=MathMin(180,InpMaxEntriesYearAll)||lastc[index]>=MathMin(60,InpMaxEntriesYearSym)){FileClose(wh);FileClose(h);return false;}
 lastn++;lastc[index]++;string next=BudgetText(st.year,lastn,lastc);ResetLastError();
 // Witness FIRST: interrupted append fails closed rather than rolling back reservations.
 // MYCODING D3: validated witness is replaced with a truncating handle under caller's portfolio lock.
 // A torn/failed replacement leaves a mismatch/corrupt witness and MUST NOT append or send.
 FileClose(wh);wh=FileOpen(w,FILE_WRITE|FILE_TXT|FILE_ANSI);
 if(wh==INVALID_HANDLE){FileClose(h);return false;}
 ResetLastError();uint nw=FileWriteString(wh,next+"\r\n");FileFlush(wh);bool ok=nw==(uint)StringLen(next)+2&&GetLastError()==0;FileClose(wh);
 if(ok){wh=FileOpen(w,FILE_READ|FILE_TXT|FILE_ANSI);ok=wh!=INVALID_HANDLE;if(ok){ok=FileReadString(wh)==next&&FileIsEnding(wh);FileClose(wh);}}
 if(ok){FileSeek(h,0,SEEK_END);ResetLastError();uint nb=FileWriteString(h,next+"\r\n");FileFlush(h);ok=nb==(uint)StringLen(next)+2&&GetLastError()==0;}FileClose(h);return ok;
}

bool BudgetOk(const string sym, const string cmt_prefix)
{
   int per_sym = EntriesThisYear(sym, cmt_prefix);
   int all     = EntriesThisYear("", "");
   if(per_sym<0||all<0)return false;
   if(per_sym >= MathMin(60,InpMaxEntriesYearSym))
   {
      g_skip_budget++;
      PrintFormat("BUDGET: %s %s already %d entries this year (limit %d) - skip", sym, cmt_prefix, per_sym, InpMaxEntriesYearSym);
      return false;
   }
   if(all >= MathMin(180,InpMaxEntriesYearAll))
   {
      g_skip_budget++;
      PrintFormat("BUDGET: portfolio already %d entries this year (limit %d) - skip %s", all, InpMaxEntriesYearAll, sym);
      return false;
   }
   return true;
}

//====================================================================
//  OPENING
//====================================================================
// MYCODING durable pre-send intent: unknown outcome never auto-retries or auto-resets.
string PendingFile(string sym,string kind){return SafetyKey()+"_"+sym+"_"+kind+".pending";}
bool BeginIntent(string sym,string kind,const MqlTradeRequest &r)
{
 string f=PendingFile(sym,kind);if(FileIsExist(f))return false;
 int h=FileOpen(f,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');if(h==INVALID_HANDLE)return false;
 if(FileSize(h)!=0){FileClose(h);return false;}
 ResetLastError();uint n=FileWrite(h,"INTENT_V2",kind,sym,(string)TimeCurrent(),(string)r.position,(string)r.type,DoubleToString(r.volume,8),DoubleToString(r.price,8),DoubleToString(r.sl,8),r.comment,"UNRESOLVED","END");
 FileFlush(h);bool ok=n>0&&GetLastError()==0;FileClose(h);return ok;
}
// MYCODING reject stale history as proof of this send. Capture exact pre-send deal IDs.
bool CaptureDeals(ulong &ids[])
{
 if(!HistorySelect(0,TimeCurrent()))return false;int n=HistoryDealsTotal();ArrayResize(ids,n);
 for(int i=0;i<n;i++){ids[i]=HistoryDealGetTicket(i);if(ids[i]==0)return false;}return true;
}
bool FreshExecution(const MqlTradeRequest &r,const MqlTradeResult &z,ulong &before[],long sent_msc)
{
 if(z.deal==0||z.order==0)return false;for(int i=0;i<ArraySize(before);i++)if(before[i]==z.deal)return false;
 if(!HistoryDealSelect(z.deal))return false;
 return (ulong)HistoryDealGetInteger(z.deal,DEAL_ORDER)==z.order&&HistoryDealGetInteger(z.deal,DEAL_TIME_MSC)>=sent_msc&&HistoryDealGetInteger(z.deal,DEAL_TYPE)==(long)r.type&&HistoryDealGetString(z.deal,DEAL_SYMBOL)==r.symbol&&HistoryDealGetInteger(z.deal,DEAL_MAGIC)==r.magic;
}
bool RecordResult(string sym,string kind,const MqlTradeResult &z)
{
 int h=FileOpen(PendingFile(sym,kind),FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');if(h==INVALID_HANDLE)return false;
 FileSeek(h,0,SEEK_END);ResetLastError();uint n=FileWrite(h,"RESULT_V2",z.retcode,(string)z.order,(string)z.deal,z.request_id,DoubleToString(z.volume,8),DoubleToString(z.price,8),"END");
 FileFlush(h);bool ok=n>0&&GetLastError()==0;FileClose(h);return ok;
}
bool DefinitiveReject(uint code)
{
 return code==TRADE_RETCODE_INVALID_STOPS||code==TRADE_RETCODE_INVALID_VOLUME||code==TRADE_RETCODE_INVALID_PRICE||code==TRADE_RETCODE_INVALID_FILL||code==TRADE_RETCODE_NO_MONEY||code==TRADE_RETCODE_TRADE_DISABLED||code==TRADE_RETCODE_MARKET_CLOSED||code==TRADE_RETCODE_INVALID;
}
bool SymbolOrder(string sym)
{
 for(int i=0;i<OrdersTotal();i++)if(OrderGetTicket(i)>0&&OrderGetString(ORDER_SYMBOL)==sym)return true;
 return false;
}
bool ConfirmEntry(const MqlTradeRequest &r,const MqlTradeResult &z)
{
 if(z.deal==0||SymbolOrder(r.symbol)||!HistoryDealSelect(z.deal))return false;
 long e=HistoryDealGetInteger(z.deal,DEAL_ENTRY);
 if(e!=DEAL_ENTRY_IN||HistoryDealGetInteger(z.deal,DEAL_MAGIC)!=InpMagic||HistoryDealGetString(z.deal,DEAL_SYMBOL)!=r.symbol||!OwnComment(HistoryDealGetString(z.deal,DEAL_COMMENT)))return false;
 double v=HistoryDealGetDouble(z.deal,DEAL_VOLUME);ulong pos=(ulong)HistoryDealGetInteger(z.deal,DEAL_POSITION_ID);
 return v>0&&v<=r.volume+1e-9&&PositionOwned(pos,r.symbol);
}
// MYCODING serialize fresh guard, sizing and send across all chart instances.
ulong OpenMarket(const string sym,bool is_buy,double sl,double tp,string cmt,string note,double gap_bp,double atr_d1,double hold_h)
{
 int lock=FileOpen(SafetyKey()+"_entry.lock",FILE_READ|FILE_WRITE|FILE_BIN);
 if(lock==INVALID_HANDLE){Print("MYCODING entry lock busy - skip");return 0;}
 ulong result=OpenMarketLocked(sym,is_buy,sl,tp,cmt,note,gap_bp,atr_d1,hold_h);
 FileClose(lock);return result;
}
ulong OpenMarketLocked(const string sym, bool is_buy, double sl, double tp, string cmt, string note,
                 double gap_bp, double atr_d1, double hold_h)
{
   // MYCODING news veto precedes mutable accounting/reservation; exits never use this gate.
   if(!HFNewsEntryGate(sym))return 0;
   if(!ReplayHistory())return 0;
   if(!EntrySafety()||FileIsExist(QuarantineFile(sym))||FileIsExist(PendingFile(sym,"ENTRY"))||FileIsExist(PendingFile(sym,"EXIT")))return 0;
   // MYCODING no mixing with existing own/foreign position or pending order on this symbol.
   for(int i=0;i<PositionsTotal();i++){if(PositionGetTicket(i)>0&&PositionGetString(POSITION_SYMBOL)==sym){Print("MYCODING existing symbol position - new entry blocked");return 0;}}
   for(int i=0;i<OrdersTotal();i++){if(OrderGetTicket(i)>0&&OrderGetString(ORDER_SYMBOL)==sym)return 0;}
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   // MYCODING safe subset: quote/profit currency must equal equity currency.
   // USDJPY on a USD account is BLOCKED; no guessed JPY->USD conversion.
   if(SymbolInfoString(sym,SYMBOL_CURRENCY_PROFIT)!=AccountInfoString(ACCOUNT_CURRENCY)){
      Print("MYCODING NOTIONAL unsupported currency conversion ",sym);return 0;
   }
   double price = is_buy ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   if(!ValidInputs()||!MathIsValidNumber(price)||price<=0||!MathIsValidNumber(sl)||sl<=0||!MathIsValidNumber(tp)||tp<0)return 0;
   int digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   sl=NormalizeDouble(sl,digits);tp=NormalizeDouble(tp,digits);
   double tick=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   if(!MathIsValidNumber(tick)||tick<=0||sl<=0||(is_buy?sl>=price:sl<=price)||MathAbs(sl/tick-MathRound(sl/tick))>1e-6)return 0;
   if(tp>0&&((is_buy?tp<=price:tp>=price)||MathAbs(tp/tick-MathRound(tp/tick))>1e-6))return 0;
   double dist  = MathAbs(price - sl);
   if(dist <= 0.0) { PrintFormat("SIZE: %s stop distance zero - no trade", sym); return 0; }

   double pnl=0;
   if(!OrderCalcProfit(is_buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,sym,1.0,price,sl,pnl)||!MathIsValidNumber(pnl)||pnl>=0)return 0;
   double rpl=-pnl;
   if(rpl <= 0.0) { PrintFormat("SIZE: %s no tick value - no trade", sym); return 0; }
   double money = eq * InpRiskPercent / 100.0;
   double lots  = money / rpl;
   double cap_notional = (InpMaxNotionalEquity * eq) / MathMax(price, 1e-9);
   double cap_notional_lots = cap_notional;         // approx for FX-like symbols (contract = 100k handled below)
   double cv = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   if(cv > 0.0) cap_notional_lots = cap_notional / cv;
   if(lots > cap_notional_lots) lots = cap_notional_lots;
   if(lots > InpMaxLots) lots = InpMaxLots;
   lots = NormLots(sym, lots);
   double finalrisk=0;
   if(lots>0&&(!OrderCalcProfit(is_buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,sym,lots,price,sl,finalrisk)||!MathIsValidNumber(finalrisk)||finalrisk>=0||-finalrisk>money+1e-8))return 0;
   if(lots <= 0.0)
   {
      g_reject_lot++;
      PrintFormat("SIZE: %s risk=%.2f stop_dist=%.5f -> lot %.4f below minimum - SKIP", sym, money, dist, lots);
      return 0;
   }

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = sym;
   req.volume       = lots;
   req.type         = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price        = price;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = 50;
   req.magic        = InpMagic;
   req.comment      = cmt;
   req.type_filling = PickFilling(sym);
   if(!HFNewsEntryGate(sym)||!EntrySafety()||!ReserveBudget(sym))return 0;
   bool soft_levels = false; // legacy management only; never create new soft-stop entries
   if(!BeginIntent(sym,"ENTRY",req))return 0;
   ulong before[];if(!CaptureDeals(before))return 0;long sent_msc=(long)TimeCurrent()*1000;
   bool ok = OrderSend(req, res);
   if(!RecordResult(sym,"ENTRY",res))return 0;
   bool done = ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL);
   if(!done) { if(DefinitiveReject(res.retcode))FileDelete(PendingFile(sym,"ENTRY")); PrintFormat("MYCODING OPEN UNRESOLVED/REJECT retcode=%u; no retry until proof",res.retcode); return 0; }
   // Requested volume is not executed volume. Only a real history deal is evidence.
   if(!FreshExecution(req,res,before,sent_msc)||!ConfirmEntry(req,res)||!HistoryDealSelect(res.deal)){Print("MYCODING execution unconfirmed; reconcile history");return 0;}
   ulong posid=(ulong)HistoryDealGetInteger(res.deal,DEAL_POSITION_ID);
   PrintFormat("MYCODING OPEN confirmed deal=%I64u position_id=%I64u volume=%.8f",res.deal,posid,HistoryDealGetDouble(res.deal,DEAL_VOLUME));
   JournalDeal(res.deal);
   if(!FileDelete(PendingFile(sym,"ENTRY")))return 0;
   return posid;
}

//====================================================================
//  MECH 1: weekend gap fade
//====================================================================
void Mech1(const string sym)
{
   datetime t0 = iTime(sym, PERIOD_H1, 0);
   datetime t1 = iTime(sym, PERIOD_H1, 1);
   if(t0 == 0 || t1 == 0) return;
   if(t0 == g_last_gap_bar) return;                     // already handled this bar
   long hole = (long)(t0 - t1);
   if(hole <= (long)InpBreakHours * 3600) return;        // no weekend/holiday hole -> not a week open
   g_last_gap_bar = t0;

   if(!MQLInfoInteger(MQL_TESTER) && t1 < TimeCurrent() - 3 * 86400) return;   // stale chart guard (live)

   double prev_close = iClose(sym, PERIOD_H1, 1);
   double open_price = iOpen(sym, PERIOD_H1, 0);
   if(prev_close <= 0.0 || open_price <= 0.0) return;
   double gap = open_price - prev_close;
   double ag  = MathAbs(gap);
   double gap_bp = ag / prev_close * 1e4;
   if(ag <= 0.0)
   {
      Log(StringFormat("M1 %s: zero gap at %s - no trade (report excludes zero gaps)", sym,
                       TimeToString(t0, TIME_DATE | TIME_MINUTES)));
      return;
   }

   // data-quality guard from the report (ATR before the break vs its 500-bar mean)
   double atr_prev = 0.0, atr_norm = 0.0;
   double buf_atr[];
   int got = CopyBuffer(g_h_atr_h1, 0, 1, 500, buf_atr);   // 500 values ending at shift 1
   if(got > 5)
   {
      atr_prev = buf_atr[got - 1];                        // the bar right before the break
      double sum = 0.0; int n = 0;
      for(int i = 0; i < got; i++)
         if(buf_atr[i] > 0.0) { sum += buf_atr[i]; n++; }
      atr_norm = (n > 0 ? sum / n : 0.0);
   }
   if(atr_norm > 0.0 && atr_prev < InpAtrQualityMin * atr_norm)
   {
      g_skip_quality++;
      PrintFormat("M1 %s: SKIP quality guard, ATR(prev)=%.5f < %.2f * mean500=%.5f (gap %.1f bp)",
                  sym, atr_prev, InpAtrQualityMin, atr_norm, gap_bp);
      return;
   }

   ulong tk; double lots, op, sl0, tp0; datetime t_open; long ty;
   if(OwnPos(sym, CMT_M1, tk, lots, op, sl0, tp0, t_open, ty))
   {
      Log(StringFormat("M1 %s: own gap position still open - skip new week", sym));
      return;
   }
   if(!BudgetOk(sym, CMT_M1)) return;

   bool is_buy = (gap < 0.0);                    // AGAINST the gap
   double sl   = is_buy ? (open_price - InpGapStopMult * ag) : (open_price + InpGapStopMult * ag);
   double tp   = prev_close;                     // friday close = full gap fill
   string note = StringFormat("gap=%.2f bp stop=%.4f tp=%.4f", gap_bp, sl, tp);
   OpenMarket(sym, is_buy, sl, tp, CMT_M1, note, gap_bp, 0.0, (double)InpGapTimeoutHours);
}

void ManageMech1Timeouts()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, CMT_M1) != 0) continue;
      datetime tt = (datetime)PositionGetInteger(POSITION_TIME);
      double hours = (double)(TimeCurrent() - tt) / 3600.0;
      if(hours >= (double)InpGapTimeoutHours)
         CloseOwn(sym, CMT_M1, StringFormat("timeout %.0f h (rule 168 h)", hours));
   }
}

//====================================================================
//  MECH 2: 55-day breakout continuation
//====================================================================
void Mech2(const string sym)
{
   datetime d0 = iTime(sym, PERIOD_D1, 0);
   datetime d1 = iTime(sym, PERIOD_D1, 1);
   if(d0 == 0 || d1 == 0) return;
   if(d0 == g_last_d1_bar) return;
   g_last_d1_bar = d0;

   double c1 = iClose(sym, PERIOD_D1, 1);
   int hi_i  = iHighest(sym, PERIOD_D1, MODE_HIGH, InpBreakoutLookback, 2);   // 55 bars before the closed one
   int lo_i  = iLowest(sym, PERIOD_D1, MODE_LOW, InpBreakoutLookback, 2);
   if(hi_i < 0 || lo_i < 0) return;                  // not enough history
   double hi55 = iHigh(sym, PERIOD_D1, hi_i);
   double lo55 = iLow(sym, PERIOD_D1, lo_i);
   if(c1 <= 0.0 || hi55 <= 0.0 || lo55 <= 0.0) return;

   int dir = 0;                                      // +1 long, -1 short, 0 none
   if(c1 > hi55) dir = +1;
   else if(c1 < lo55) dir = -1;
   if(dir == 0) return;

   string what = StringFormat("M2 %s: D1 close %.5f %s %s (hi55=%.5f lo55=%.5f) on %s",
                              sym, c1, (dir > 0 ? ">" : "<"), (dir > 0 ? "55d high" : "55d low"),
                              hi55, lo55, TimeToString(d1, TIME_DATE));

   ulong tk; double lots, op, sl0, tp0; datetime t_open; long ty;
   if(OwnPos(sym, CMT_M2, tk, lots, op, sl0, tp0, t_open, ty))
   {
      Log(what + "  -> own breakout position still open: NO overlap (report rule), skip");
      return;
   }
   if(!BudgetOk(sym, CMT_M2)) return;

   double atr_d1 = 0.0;
   double buf_d1[];
   int got_d1 = CopyBuffer(g_h_atr_d1, 0, 2, 1, buf_d1);   // shift 2 = the bar before the signal bar
   if(got_d1 > 0) atr_d1 = buf_d1[0];
   if(atr_d1 <= 0.0) { Log(what + " -> no ATR(D1), skip"); return; }
   double price = (dir > 0) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   double sl    = (dir > 0) ? (price - InpMech2StopAtrMult * atr_d1)
                            : (price + InpMech2StopAtrMult * atr_d1);
   double tp    = 0.0;                               // rule has NO target: exit on time
   string note  = what;
   Print(what, StringFormat("  ATR(D1)=%.5f stop=%.5f (%.1f x ATR), hold=%d days",
                            atr_d1, sl, InpMech2StopAtrMult, InpHoldDaysMech2));
   OpenMarket(sym, (dir > 0), sl, tp, CMT_M2, note, 0.0, atr_d1, (double)InpHoldDaysMech2 * 24.0);
}

void ManageMech2Timeouts()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, CMT_M2) != 0) continue;
      datetime tt = (datetime)PositionGetInteger(POSITION_TIME);
      double days = (double)(TimeCurrent() - tt) / 86400.0;
      if(days >= (double)InpHoldDaysMech2)
         CloseOwn(sym, CMT_M2, StringFormat("hold %.0f days (rule %d days)", days, InpHoldDaysMech2));
   }
}

//====================================================================
//  LIFECYCLE
//====================================================================
// MYCODING safety domain validation, no signal formula changes.
bool Positive(double v){return MathIsValidNumber(v)&&v>0;}
bool ValidInputs()
{
 return (InpNewsMode==OBSERVE||InpNewsMode==ENTRY_GUARD)&&InpMagic>0&&InpExpectedLogin>0&&InpRequireDemo&&Positive(InpGapStopMult)&&InpGapTimeoutHours>0&&InpBreakHours>0&&Positive(InpAtrQualityMin)&&InpBreakoutLookback>=2&&InpHoldDaysMech2>0&&Positive(InpMech2StopAtrMult)&&Positive(InpRiskPercent)&&InpRiskPercent<=0.25&&Positive(InpMaxLots)&&Positive(InpMaxNotionalEquity)&&InpMaxEntriesYearSym>0&&InpMaxEntriesYearSym<=60&&InpMaxEntriesYearAll>0&&InpMaxEntriesYearAll<=180;
}
int OnInit()
{
   if(!ValidInputs()){Print("MYCODING invalid inputs; initialization failed");return INIT_PARAMETERS_INCORRECT;}
   string m1 = InpMech1Symbols; StringToUpper(m1);
   string m2 = InpMech2Symbols; StringToUpper(m2);

   CheckAccount();
   TesterSeedGuard();
   JournalInit();
   Print("MYCODING ENTRY READINESS: ",EntrySafety()?"PREFLIGHT_ONLY; budget/pending/ownership checked at send":"BLOCKED",
         "; sampled online equity peak, no continuous/historical peak guarantee; owner bootstrap/cashflow policy required");

   g_h_atr_h1 = iATR(_Symbol, PERIOD_H1, 14);
   g_h_atr_d1 = iATR(_Symbol, PERIOD_D1, 14);
   if(g_h_atr_h1 == INVALID_HANDLE || g_h_atr_d1 == INVALID_HANDLE)
   {
      Print("ERROR: ATR handles not created (err=", GetLastError(), ") - refusing to run");
      return INIT_FAILED;
   }

   Print("HermesForward started. Symbols M1=", m1, "  M2=", m2,
         "  risk=", DoubleToString(InpRiskPercent, 2), "%  magic=", (string)InpMagic);
   Print("Server=", AccountInfoString(ACCOUNT_SERVER), "  company=", AccountInfoString(ACCOUNT_COMPANY),
         "  currency=", AccountInfoString(ACCOUNT_CURRENCY),
         "  balance=", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
         "  equity=", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("RULES: M1 = every non-zero weekend gap, trade AGAINST the gap, target friday close, stop ",
         DoubleToString(InpGapStopMult, 2), " x |gap|, timeout ", InpGapTimeoutHours, " h | ",
         "M2 = D1 close beyond ", InpBreakoutLookback, "-day extreme, hold ", InpHoldDaysMech2,
         " days, no overlap, protective stop ", DoubleToString(InpMech2StopAtrMult, 2), " x ATR(D1) [ADDED]");
   Print("BUDGET: ", InpMaxEntriesYearSym, "/symbol/year, ", InpMaxEntriesYearAll, "/portfolio/year");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(FreshAccount())ReplayHistory();
   if(g_journal_h != INVALID_HANDLE) { FileFlush(g_journal_h); FileClose(g_journal_h); }
   if(g_h_atr_h1 != INVALID_HANDLE) IndicatorRelease(g_h_atr_h1);
   if(g_h_atr_d1 != INVALID_HANDLE) IndicatorRelease(g_h_atr_d1);
   PrintFormat("HermesForward stopped. rejected_by_lot=%d skipped_by_budget=%d skipped_by_quality=%d",
               g_reject_lot, g_skip_budget, g_skip_quality);
}

bool SymInList(const string sym, const string list)
{
   return StrHas(list, SymUp(sym));
}

void OnTick()
{
   if(!FreshAccount()) return;

   EnforceSoftLevels();
   ManageMech1Timeouts();
   ManageMech2Timeouts();

   static datetime last_replay=0;
   if(TimeCurrent()-last_replay>=3600){ReplayHistory();last_replay=TimeCurrent();}
   HFNewsEntryGate(_Symbol); // MYCODING shadow reasons only here; protective exits already executed
   if(!PeakGuard())return;
   if(InpMech1 && SymInList(_Symbol, InpMech1Symbols)) Mech1(_Symbol);
   if(InpMech2 && SymInList(_Symbol, InpMech2Symbols)) Mech2(_Symbol);
}
//+------------------------------------------------------------------+
