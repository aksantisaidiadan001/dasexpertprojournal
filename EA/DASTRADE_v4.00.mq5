//+------------------------------------------------------------------+
//| INSTALLATION (inchangée)                                         |
//| 1. Compte créé sur https://trading-das.web.app, e-mail vérifié.  |
//| 2. MT5 > Outils > Options > Expert Advisors : "Autoriser         |
//|    WebRequest" + https://identitytoolkit.googleapis.com          |
//|                 + https://firestore.googleapis.com               |
//| 3. Compiler (F7), glisser sur un graphique, saisir e-mail et     |
//|    mot de passe dans l'onglet Entrées, activer Algo Trading.     |
//+------------------------------------------------------------------+
//|  DASTRADE.mq5 v4.00 : v3 + SL/TP des positions, suivi des        |
//|  modifications de SL/TP, données d'ouverture des trades clôturés |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://trading-das.web.app"
#property version   "4.00"
#property strict

input group "--- Firebase Auth ---"
input string InpEmail           = "";   // Votre e-mail de connexion au journal
input string InpPassword        = "";   // Votre mot de passe du journal
input group "--- Synchronisation ---"
input int    InpSyncSeconds     = 15;   // Compte + positions + suivi SL/TP
input int    InpSnapshotSeconds = 60;   // Courbe en direct + trades clôturés
input int    InpHistoryDays     = 30;   // Historique envoyé au premier lancement

const string API_KEY    = "AIzaSyDFfsaI85dsAfAqigH0HyKgcGzNuTDQGG8";
const string PROJECT_ID = "trading-das";

string   g_uid = "", g_idToken = "";
datetime g_tokenExpiry = 0, g_lastSlow = 0, g_lastHistory = 0;
ulong    g_tid[];            // positions suivies (identifiant)
double   g_tsl[], g_ttp[];   // derniers SL / TP vus

//+------------------------------------------------------------------+
string JsonEsc(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   return s;
}

string JsonGet(const string json, const string key)
{
   int p = StringFind(json, "\"" + key + "\"");
   if(p < 0) return "";
   p = StringFind(json, ":", p);
   if(p < 0) return "";
   int a = StringFind(json, "\"", p);
   if(a < 0) return "";
   int b = StringFind(json, "\"", a + 1);
   if(b < 0) return "";
   return StringSubstr(json, a + 1, b - a - 1);
}

int Http(const string method, const string url, const string body, string &response, const bool auth)
{
   string headers = "Content-Type: application/json\r\n";
   if(auth) headers += "Authorization: Bearer " + g_idToken + "\r\n";
   char post[], result[];
   string rh;
   if(StringLen(body) > 0)
   {
      StringToCharArray(body, post, 0, WHOLE_ARRAY, CP_UTF8);
      ArrayResize(post, ArraySize(post) - 1);
   }
   ResetLastError();
   int code = WebRequest(method, url, headers, 8000, post, result, rh);
   response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code == -1)
      Print("WebRequest -1 (erreur ", GetLastError(), ") : autorise les URLs dans Outils > Options > Expert Advisors.");
   return code;
}

string Mask(const string csv)
{
   string m[];
   int n = StringSplit(csv, ',', m);
   string q = "";
   for(int i = 0; i < n; i++)
      q += (i == 0 ? "?" : "&") + "updateMask.fieldPaths=" + m[i];
   return q;
}

long ServerOffset()
{
   long off = (long)(TimeTradeServer() - TimeGMT());
   return ((off + 900) / 1800) * 1800;
}

string D(double v, int dg) { return DoubleToString(v, dg); }
string NumF(string k, double v, int dg) { return "\"" + k + "\":{\"doubleValue\":" + D(v, dg) + "}"; }
string IntF(string k, long v) { return "\"" + k + "\":{\"integerValue\":\"" + IntegerToString(v) + "\"}"; }
string StrF(string k, string v) { return "\"" + k + "\":{\"stringValue\":\"" + JsonEsc(v) + "\"}"; }

//+------------------------------------------------------------------+
bool SignIn()
{
   string resp;
   string body = "{\"email\":\"" + JsonEsc(InpEmail) + "\",\"password\":\"" + JsonEsc(InpPassword) + "\",\"returnSecureToken\":true}";
   int code = Http("POST", "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=" + API_KEY, body, resp, false);
   if(code != 200)
   {
      Print("Echec connexion Firebase (code ", code, ") : ", JsonGet(resp, "message"));
      return false;
   }
   g_uid     = JsonGet(resp, "localId");
   g_idToken = JsonGet(resp, "idToken");
   int ttl   = (int)StringToInteger(JsonGet(resp, "expiresIn"));
   if(ttl <= 0) ttl = 3600;
   g_tokenExpiry = TimeLocal() + ttl - 300;
   return (g_uid != "" && g_idToken != "");
}

bool EnsureAuth()
{
   if(g_idToken != "" && TimeLocal() < g_tokenExpiry) return true;
   return SignIn();
}

string DocBase()
{
   return "https://firestore.googleapis.com/v1/projects/" + PROJECT_ID + "/databases/(default)/documents/users/" + g_uid +
          "/accounts/" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
}

//+------------------------------------------------------------------+
//| Compte + positions ouvertes (v4 : id, sl, tp, ot)                |
//+------------------------------------------------------------------+
void SyncAccount()
{
   long off = ServerOffset();
   string pos = "[";
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      int dg   = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
      string t = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(StringLen(pos) > 1) pos += ",";
      pos += "{\"s\":\"" + s + "\",\"t\":\"" + t + "\",\"v\":" + D(PositionGetDouble(POSITION_VOLUME), 2) +
             ",\"o\":" + D(PositionGetDouble(POSITION_PRICE_OPEN), dg) + ",\"p\":" + D(p, 2) +
             ",\"id\":\"" + IntegerToString(PositionGetInteger(POSITION_IDENTIFIER)) + "\"" +
             ",\"sl\":" + D(PositionGetDouble(POSITION_SL), dg) + ",\"tp\":" + D(PositionGetDouble(POSITION_TP), dg) +
             ",\"ot\":" + IntegerToString((long)PositionGetInteger(POSITION_TIME) - off) + "}";
   }
   pos += "]";

   string body = "{\"fields\":{" +
      StrF("name", AccountInfoString(ACCOUNT_NAME)) + "," +
      NumF("balance", AccountInfoDouble(ACCOUNT_BALANCE), 2) + "," +
      NumF("equity", AccountInfoDouble(ACCOUNT_EQUITY), 2) + "," +
      StrF("positions", pos) + "," +
      IntF("updatedAt", (long)TimeGMT()) + "}}";

   string resp;
   int code = Http("PATCH", DocBase() + Mask("name,balance,equity,positions,updatedAt"), body, resp, true);
   if(code != 200) Print("Erreur sync compte (code ", code, ") : ", resp);
}

//+------------------------------------------------------------------+
//| Suivi des positions : SL/TP initiaux (créés une seule fois),     |
//| puis chaque modification de SL/TP en événement                   |
//+------------------------------------------------------------------+
int FindT(const ulong id)
{
   for(int i = 0; i < ArraySize(g_tid); i++) if(g_tid[i] == id) return i;
   return -1;
}

void TrackPositions()
{
   ulong  nid[]; double nsl[], ntp[];
   long off = ServerOffset();
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      ulong  id = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      double sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
      string s  = PositionGetString(POSITION_SYMBOL);
      int    dg = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
      string base = DocBase() + "/ptrack/" + IntegerToString((long)id), resp;
      double psl = sl, ptp = tp;   // après un redémarrage : on suppose SL/TP inchangés
      int k = FindT(id);
      if(k < 0)
      {
         string t = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
         string body = "{\"fields\":{" + StrF("symbol", s) + "," + StrF("type", t) + "," +
            NumF("volume", PositionGetDouble(POSITION_VOLUME), 2) + "," + NumF("openPrice", PositionGetDouble(POSITION_PRICE_OPEN), dg) + "," +
            IntF("openTime", (long)PositionGetInteger(POSITION_TIME) - off) + "," +
            NumF("sl0", sl, dg) + "," + NumF("tp0", tp, dg) + "," + NumF("slLive", sl, dg) + "," + NumF("tpLive", tp, dg) + "," +
            IntF("updatedAt", (long)TimeGMT()) + "}}";
         // création unique : refusée par Firebase si le document existe déjà (cas normal après redémarrage)
         int c = Http("PATCH", base + "?currentDocument.exists=false", body, resp, true);
         if(c != 200 && c != 400 && c != 409) Print("Erreur ptrack (code ", c, ")");
      }
      else { psl = g_tsl[k]; ptp = g_ttp[k]; }

      if(MathAbs(sl - psl) > 1e-10 || MathAbs(tp - ptp) > 1e-10)
      {
         string ev = "{\"fields\":{" + IntF("t", (long)TimeGMT()) + "," + NumF("sl", sl, dg) + "," + NumF("tp", tp, dg) + "}}";
         Http("POST", base + "/changes", ev, resp, true);
         string up = "{\"fields\":{" + NumF("slLive", sl, dg) + "," + NumF("tpLive", tp, dg) + "," + IntF("updatedAt", (long)TimeGMT()) + "}}";
         Http("PATCH", base + Mask("slLive,tpLive,updatedAt"), up, resp, true);
      }
      int n = ArraySize(nid);
      ArrayResize(nid, n + 1); ArrayResize(nsl, n + 1); ArrayResize(ntp, n + 1);
      nid[n] = id; nsl[n] = sl; ntp[n] = tp;
   }
   int m = ArraySize(nid);
   ArrayResize(g_tid, m); ArrayResize(g_tsl, m); ArrayResize(g_ttp, m);
   for(int j = 0; j < m; j++) { g_tid[j] = nid[j]; g_tsl[j] = nsl[j]; g_ttp[j] = ntp[j]; }
}

//+------------------------------------------------------------------+
void SyncSnapshot()
{
   string body = "{\"fields\":{" + IntF("t", (long)TimeGMT()) + "," +
      NumF("equity", AccountInfoDouble(ACCOUNT_EQUITY), 2) + "," + NumF("balance", AccountInfoDouble(ACCOUNT_BALANCE), 2) + "}}";
   string resp;
   int code = Http("POST", DocBase() + "/snapshots", body, resp, true);
   if(code != 200) Print("Erreur snapshot (code ", code, ")");
}

//+------------------------------------------------------------------+
//| Trades clôturés (v4 : posId, openTime, openPrice, closePrice,    |
//| slO/tpO = SL/TP de l'ordre d'ouverture, 0 = absent à l'ouverture)|
//+------------------------------------------------------------------+
void SyncTrades()
{
   datetime from = (g_lastHistory > 0) ? g_lastHistory - 3600 : TimeCurrent() - (datetime)(InpHistoryDays * 86400);
   if(!HistorySelect(from, TimeCurrent() + 86400)) return;

   ulong tks[];
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      long type  = HistoryDealGetInteger(tk, DEAL_TYPE);
      long entry = HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT) continue;
      int n = ArraySize(tks); ArrayResize(tks, n + 1); tks[n] = tk;
   }

   long off = ServerOffset();
   bool allOk = true;
   for(int j = 0; j < ArraySize(tks); j++)
   {
      ulong tk = tks[j];
      if(!HistoryDealSelect(tk)) continue;
      long   type = HistoryDealGetInteger(tk, DEAL_TYPE);
      datetime dt = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
      string date = TimeToString(dt, TIME_DATE);
      StringReplace(date, ".", "-");
      string sym  = HistoryDealGetString(tk, DEAL_SYMBOL);
      int    dg   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      string dir  = (type == DEAL_TYPE_SELL) ? "BUY" : "SELL";
      double pnl  = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_COMMISSION) +
                    HistoryDealGetDouble(tk, DEAL_SWAP) + HistoryDealGetDouble(tk, DEAL_FEE);
      double lots = HistoryDealGetDouble(tk, DEAL_VOLUME), closePx = HistoryDealGetDouble(tk, DEAL_PRICE);
      long   pid  = HistoryDealGetInteger(tk, DEAL_POSITION_ID);

      double openPx = 0, slO = 0, tpO = 0; long openT = 0;
      if(HistorySelectByPosition((ulong)pid))
      {
         for(int d = 0; d < HistoryDealsTotal(); d++)
         {
            ulong dk = HistoryDealGetTicket(d);
            if(dk == 0 || HistoryDealGetInteger(dk, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
            openT  = (long)HistoryDealGetInteger(dk, DEAL_TIME) - off;
            openPx = HistoryDealGetDouble(dk, DEAL_PRICE);
            ulong ord = (ulong)HistoryDealGetInteger(dk, DEAL_ORDER);
            if(HistoryOrderSelect(ord)) { slO = HistoryOrderGetDouble(ord, ORDER_SL); tpO = HistoryOrderGetDouble(ord, ORDER_TP); }
            break;
         }
      }

      string body = "{\"fields\":{" + StrF("date", date) + "," + IntF("closeTime", (long)dt - off) + "," + StrF("asset", sym) + "," +
         StrF("type", dir) + "," + NumF("lotSize", lots, 2) + "," + NumF("pnl", pnl, 2) + "," +
         StrF("posId", IntegerToString(pid)) + "," + IntF("openTime", openT) + "," + NumF("openPrice", openPx, dg) + "," +
         NumF("closePrice", closePx, dg) + "," + NumF("slO", slO, dg) + "," + NumF("tpO", tpO, dg) + "}}";

      string resp;
      // updateMask : préserve setup, émotion, plan respecté, notes et prepId saisis dans le tableau de bord
      int code = Http("PATCH", DocBase() + "/trades/" + (string)tk +
                      Mask("date,closeTime,asset,type,lotSize,pnl,posId,openTime,openPrice,closePrice,slO,tpO"), body, resp, true);
      if(code != 200) { allOk = false; Print("Erreur trade ", tk, " (code ", code, ")"); }
   }
   if(allOk) g_lastHistory = TimeCurrent();
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpEmail == "" || InpPassword == "")
   {
      Print("Renseignez votre e-mail et votre mot de passe dans l'onglet Entrées de l'EA.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!SignIn()) return INIT_FAILED;
   Print("Connecté à Firebase, uid = ", g_uid);
   EventSetTimer(MathMax(5, InpSyncSeconds));
   OnTimer();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
{
   if(!EnsureAuth()) return;
   SyncAccount();
   TrackPositions();
   if(TimeLocal() - g_lastSlow >= InpSnapshotSeconds)
   {
      g_lastSlow = TimeLocal();
      SyncSnapshot();
      SyncTrades();
   }
}