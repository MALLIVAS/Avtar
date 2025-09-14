#property strict
#include <Trade/Trade.mqh>

enum SignalType { SIG_NONE=0, SIG_TREND_BUY, SIG_TREND_SELL, SIG_REV_BUY, SIG_REV_SELL };

// Inputs
input string   SymbolToTrade        = "NAS100.r";     // e.g. "US100", "USTECH", etc.
input ENUM_TIMEFRAMES SignalTF      = PERIOD_M15;

// Core indicators
input int      FastEMA              = 9;
input int      SlowEMA              = 21;
input int      TrendEMA             = 200;          // Trend filter EMA (M15)
input int      RSIPeriod            = 14;
input double   RSI_Trend_Buy_Above  = 55.0;
input double   RSI_Trend_Sell_Below = 45.0;

// MACD params (standard)
input int      MACD_Fast            = 12;
input int      MACD_Slow            = 26;
input int      MACD_Signal          = 9;

// Volume filter
input int      VolAvgPeriod         = 21;

// Money management
input double   Lots                 = 0.10;
input int      SL_Points            = 100;
input int      TP_Points            = 200;
input int      SlippagePoints       = 30;
input double   MaxSpreadPoints      = 0.0;         // 0 = no filter

// Trailing stop: point-to-point (bar-to-bar)
input bool     UsePointToPointTrail = true;
input int      TrailBufferPoints    = 5;
input bool     UseBreakEven         = true;
input int      BreakEvenTriggerPts  = 100;
input int      BreakEvenBufferPts   = 5;

// Trend filter (additional)
input bool     UseTrendFilter200EMA = true;

// Reversal setup specifics
input int      ReversalRSILookback  = 20;
input double   Rev_RSI_Buy_From     = 30.0;
input double   Rev_RSI_Buy_To       = 45.0;
input double   Rev_RSI_Sell_From    = 72.0;
input double   Rev_RSI_Sell_To      = 55.0;

// MACD behavior for reversal
input bool     StrictMACDReversal   = true;

// Support/Resistance for reversal
input int      SR_LookbackBars      = 500;
input int      ZoneTolerancePoints  = 50;
input double   WickFactor           = 1.5;
input int      MinBodyPoints        = 5;

// Time filter (IST 18:00 to 07:00)
input bool     UseISTTimeFilter     = true;
input double   ServerToUTC_OffsetH  = 0.0;         // broker server offset to UTC (e.g., 2.0 or 3.0)
input int      StartHourIST         = 18;
input int      EndHourIST           = 7;

// Trade control
input bool     OnePositionOnly      = true;
input bool     OneTradePerBar       = true;
input long     MagicNumber          = 987654321;

// Extra logic
input bool     CloseOppositeOnEntry = true;
input bool     UseEMA_SameSide      = true;

CTrade trade;

// Globals
string   g_symbol = "";
datetime lastSignalBarTime = 0;
int fastHandle=-1, slowHandle=-1, trendHandle=-1, rsiHandle=-1, macdHandle=-1;
double PointVal=0.0; int DigitsCount=0;

double Pt() { return PointVal; }
bool GetTick(MqlTick &t){ return SymbolInfoTick(g_symbol, t); }

bool NewSignalBar()
{
   datetime t[1];
   if(CopyTime(g_symbol, SignalTF, 0, 1, t)!=1) return false;
   if(t[0]!=lastSignalBarTime)
   {
      lastSignalBarTime = t[0];
      return true;
   }
   return false;
}

bool TimeFilterPass()
{
   if(!UseISTTimeFilter) return true;
   datetime server_now = TimeCurrent();
   datetime utc_now = (datetime)((long)server_now - (long)(ServerToUTC_OffsetH*3600.0));
   datetime ist_now = (datetime)((long)utc_now + (long)(5.5*3600.0));
   MqlDateTime dt; TimeToStruct(ist_now, dt);
   int hour = dt.hour;
   if(StartHourIST <= EndHourIST)
      return (hour >= StartHourIST && hour < EndHourIST);
   else
      return (hour >= StartHourIST || hour < EndHourIST);
}

bool SpreadOK()
{
   if(MaxSpreadPoints<=0) return true;
   MqlTick t; if(!GetTick(t)) return false;
   double spreadPts = (t.ask - t.bid)/Pt();
   return (spreadPts <= MaxSpreadPoints);
}

bool LoadHandles()
{
   if(fastHandle==-1)  fastHandle  = iMA(g_symbol, SignalTF, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(slowHandle==-1)  slowHandle  = iMA(g_symbol, SignalTF, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(UseTrendFilter200EMA && trendHandle==-1) trendHandle = iMA(g_symbol, SignalTF, TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(rsiHandle==-1)   rsiHandle   = iRSI(g_symbol, SignalTF, RSIPeriod, PRICE_CLOSE);
   if(macdHandle==-1)  macdHandle  = iMACD(g_symbol, SignalTF, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   if(fastHandle==INVALID_HANDLE || slowHandle==INVALID_HANDLE || rsiHandle==INVALID_HANDLE || macdHandle==INVALID_HANDLE) return false;
   if(UseTrendFilter200EMA && trendHandle==INVALID_HANDLE) return false;
   return true;
}

bool CopyDoubles(int handle, int buffer, int count, double &out[])
{
   ArraySetAsSeries(out, true);
   return (CopyBuffer(handle, buffer, 0, count, out)==count);
}

bool GetOHLCV(int count, MqlRates &rates[])
{
   ArraySetAsSeries(rates, true);
   int got = CopyRates(g_symbol, SignalTF, 0, count, rates);
   return (got==count);
}

double AvgVolume(const long &vol[], int from_index, int period)
{
   if(from_index+period > ArraySize(vol)) return 0.0;
   double sum = 0;
   for(int i=from_index; i<from_index+period; ++i) sum += (double)vol[i];
   return sum/period;
}

bool CrossUp(double a1, double a2, double b1, double b2)   { return (a2<=b2 && a1>b1); }
bool CrossDown(double a1, double a2, double b1, double b2) { return (a2>=b2 && a1<b1); }

// S/R using local swing points
bool FindNearestSupport(double &support_price, const MqlRates &rates[], int bars, int tolerancePts)
{
   double best=0.0, minDist=DBL_MAX;
   for(int i=1; i<bars-1; ++i)
   {
      if(rates[i].low < rates[i-1].low && rates[i].low < rates[i+1].low)
      {
         double distPts = MathAbs((rates[0].close - rates[i].low)/Pt());
         if(distPts < minDist){ minDist = distPts; best = rates[i].low; }
      }
   }
   if(best>0.0 && MathAbs((rates[0].low - best)/Pt()) <= tolerancePts){ support_price = best; return true; }
   return false;
}
bool FindNearestResistance(double &res_price, const MqlRates &rates[], int bars, int tolerancePts)
{
   double best=0.0, minDist=DBL_MAX;
   for(int i=1; i<bars-1; ++i)
   {
      if(rates[i].high > rates[i-1].high && rates[i].high > rates[i+1].high)
      {
         double distPts = MathAbs((rates[0].close - rates[i].high)/Pt());
         if(distPts < minDist){ minDist = distPts; best = rates[i].high; }
      }
   }
   if(best>0.0 && MathAbs((rates[0].high - best)/Pt()) <= tolerancePts){ res_price = best; return true; }
   return false;
}

// Candle shape checks (bar 1)
bool BullishPinBar(const MqlRates &r)
{
   double body  = MathAbs(r.close - r.open)/Pt();
   double lower = (MathMin(r.open, r.close) - r.low)/Pt();
   double upper = (r.high - MathMax(r.open, r.close))/Pt();
   if(body < MinBodyPoints) return false;
   if(lower >= WickFactor*body && upper <= body) return true;
   return false;
}
bool BearishPinBar(const MqlRates &r)
{
   double body  = MathAbs(r.close - r.open)/Pt();
   double lower = (MathMin(r.open, r.close) - r.low)/Pt();
   double upper = (r.high - MathMax(r.open, r.close))/Pt();
   if(body < MinBodyPoints) return false;
   if(upper >= WickFactor*body && lower <= body) return true;
   return false;
}

// Build signals (use closed bar 1)
SignalType ComputeSignal()
{
   // Prices for S/R and candle checks
   int needBars = MathMax(SR_LookbackBars, 50);
   MqlRates rates[]; if(!GetOHLCV(needBars, rates)) return SIG_NONE;

   // EMA buffers
   double f[3], s[3], t200[3]={0,0,0};
   if(!CopyDoubles(fastHandle, 0, 3, f)) return SIG_NONE;
   if(!CopyDoubles(slowHandle, 0, 3, s)) return SIG_NONE;
   if(UseTrendFilter200EMA && !CopyDoubles(trendHandle, 0, 3, t200)) return SIG_NONE;

   // RSI: need more bars for reversal path
   int rsiNeed = MathMax(3, ReversalRSILookback+2);
   double rsiArr[]; ArraySetAsSeries(rsiArr, true);
   if(CopyBuffer(rsiHandle, 0, 0, rsiNeed, rsiArr) != rsiNeed) return SIG_NONE;
   double rsi0 = rsiArr[0], rsi1 = rsiArr[1], rsi2 = rsiArr[2];

   // MACD
   double macd_main[3], macd_sig[3];
   if(!CopyDoubles(macdHandle, 0, 3, macd_main)) return SIG_NONE;
   if(!CopyDoubles(macdHandle, 1, 3, macd_sig))  return SIG_NONE;
   double hist0 = macd_main[0]-macd_sig[0];
   double hist1 = macd_main[1]-macd_sig[1];
   double hist2 = macd_main[2]-macd_sig[2];

   // Volume filter on bar 1 vs avg(2..VolAvgPeriod+1)
   long vols[]; ArraySetAsSeries(vols, true);
   if(CopyTickVolume(g_symbol, SignalTF, 0, VolAvgPeriod+2, vols) < VolAvgPeriod+2) return SIG_NONE;
   double avgVol=0; for(int i=2;i<2+VolAvgPeriod;i++) avgVol += (double)vols[i];
   avgVol/=VolAvgPeriod;
   bool volOK = ((double)vols[1] > avgVol);

   // Trend side check
   bool sameSideOK_B = true, sameSideOK_S = true;
   if(UseTrendFilter200EMA && UseEMA_SameSide)
   {
      sameSideOK_B = (f[1] > t200[1] && s[1] > t200[1]);
      sameSideOK_S = (f[1] < t200[1] && s[1] < t200[1]);
   }

   // Cross checks (2->1)
   bool buyCross  = CrossUp(f[1], f[2], s[1], s[2]);
   bool sellCross = CrossDown(f[1], f[2], s[1], s[2]);

   bool rsiBuyOK  = (rsi1 >= RSI_Trend_Buy_Above);
   bool rsiSellOK = (rsi1 <= RSI_Trend_Sell_Below);

   bool macdBullOK = ( (hist1 > 0.0) || (macd_main[1] > macd_sig[1]) );
   bool macdBearOK = ( (hist1 < 0.0) || (macd_main[1] < macd_sig[1]) );

   if(volOK)
   {
      if(buyCross && rsiBuyOK && macdBullOK && sameSideOK_B) return SIG_TREND_BUY;
      if(sellCross && rsiSellOK && macdBearOK && sameSideOK_S) return SIG_TREND_SELL;
   }

   // Reversal conditions
   double support=0.0, resist=0.0;
   bool nearSupport = FindNearestSupport(support, rates, MathMin(SR_LookbackBars, ArraySize(rates)-1), ZoneTolerancePoints);
   bool nearResist  = FindNearestResistance(resist, rates, MathMin(SR_LookbackBars, ArraySize(rates)-1), ZoneTolerancePoints);

   double minRSI=9999.0, maxRSI=-9999.0;
   int look = MathMin(ReversalRSILookback, ArraySize(rsiArr)-1);
   for(int i=1;i<=look;i++){ if(rsiArr[i]<minRSI) minRSI=rsiArr[i]; if(rsiArr[i]>maxRSI) maxRSI=rsiArr[i]; }
   bool revRSIbuy  = (minRSI < Rev_RSI_Buy_From  && rsi1 >= Rev_RSI_Buy_To  && rsi0 > rsi1);
   bool revRSIsell = (maxRSI > Rev_RSI_Sell_From && rsi1 <= Rev_RSI_Sell_To && rsi0 < rsi1);

   bool macdRevBuyOK  = StrictMACDReversal ? (hist2 < hist1 && hist1 < hist0 && hist0 < 0.0) : (hist1 < 0.0 && hist0 > hist1);
   bool macdRevSellOK = StrictMACDReversal ? (hist2 > hist1 && hist1 > hist0 && hist0 > 0.0) : (hist1 > 0.0 && hist0 < hist1);

   MqlRates c1 = rates[1];
   bool bullPin = BullishPinBar(c1);
   bool bearPin = BearishPinBar(c1);

   if(nearSupport && bullPin && revRSIbuy && macdRevBuyOK) return SIG_REV_BUY;
   if(nearResist  && bearPin && revRSIsell && macdRevSellOK) return SIG_REV_SELL;

   return SIG_NONE;
}

// Position helpers
int PositionTypeForSymbol(const string sym)
{
   if(!PositionSelect(sym)) return -1;
   long type = PositionGetInteger(POSITION_TYPE);
   return (type==POSITION_TYPE_BUY) ? 0 : 1;
}

bool CloseOppositeIfNeeded(SignalType sig)
{
   if(!CloseOppositeOnEntry) return true;
   if(!PositionSelect(g_symbol)) return true;
   long type = PositionGetInteger(POSITION_TYPE);
   if( (sig==SIG_TREND_BUY || sig==SIG_REV_BUY) && type==POSITION_TYPE_SELL)
      return trade.PositionClose(g_symbol);
   if( (sig==SIG_TREND_SELL || sig==SIG_REV_SELL) && type==POSITION_TYPE_BUY)
      return trade.PositionClose(g_symbol);
   return true;
}

bool OpenTrade(SignalType sig)
{
   MqlTick t; if(!GetTick(t)) return false;
   double sl=0.0, tp=0.0;

   if(sig==SIG_TREND_BUY)
   {
      sl = t.bid - SL_Points*Pt();
      tp = t.bid + TP_Points*Pt();
      return trade.Buy(Lots, g_symbol, 0.0, sl, tp, "Trend Buy");
   }
   if(sig==SIG_TREND_SELL)
   {
      sl = t.ask + SL_Points*Pt();
      tp = t.ask - TP_Points*Pt();
      return trade.Sell(Lots, g_symbol, 0.0, sl, tp, "Trend Sell");
   }

   // Reversal uses bar 1 candle for SL
   MqlRates rates[]; if(!GetOHLCV(3, rates)) return false;

   if(sig==SIG_REV_BUY)
   {
      double entry = t.ask;
      double candleSL = rates[1].low - TrailBufferPoints*Pt();
      double minSL    = entry - SL_Points*Pt();
      double chooseSL = MathMin(candleSL, minSL);
      if((entry - chooseSL)/Pt() < SL_Points) chooseSL = entry - SL_Points*Pt();
      sl = chooseSL; tp = entry + TP_Points*Pt();
      return trade.Buy(Lots, g_symbol, 0.0, sl, tp, "Reversal Buy");
   }
   if(sig==SIG_REV_SELL)
   {
      double entry = t.bid;
      double candleSL = rates[1].high + TrailBufferPoints*Pt();
      double minSL    = entry + SL_Points*Pt();
      double chooseSL = MathMax(candleSL, minSL);
      if((chooseSL - entry)/Pt() < SL_Points) chooseSL = entry + SL_Points*Pt();
      sl = chooseSL; tp = entry - TP_Points*Pt();
      return trade.Sell(Lots, g_symbol, 0.0, sl, tp, "Reversal Sell");
   }
   return false;
}

void ManageTrailing()
{
   if(!UsePointToPointTrail && !UseBreakEven) return;
   if(!PositionSelect(g_symbol)) return;

   long   type = PositionGetInteger(POSITION_TYPE);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);

   MqlTick t; if(!GetTick(t)) return;

   // Break-even
   if(UseBreakEven)
   {
      if(type==POSITION_TYPE_BUY)
      {
         double profitPts = (t.bid - open)/Pt();
         double beSL = open + BreakEvenBufferPts*Pt();
         if(profitPts >= BreakEvenTriggerPts && (sl < open || sl==0.0))
            trade.PositionModify(g_symbol, beSL, tp);
      }
      else
      {
         double profitPts = (open - t.ask)/Pt();
         double beSL = open - BreakEvenBufferPts*Pt();
         if(profitPts >= BreakEvenTriggerPts && (sl > open || sl==0.0))
            trade.PositionModify(g_symbol, beSL, tp);
      }
   }

   if(!UsePointToPointTrail) return;

   // Bar-to-bar trailing with buffer
   MqlRates r[]; if(!GetOHLCV(3, r)) return;
   if(type==POSITION_TYPE_BUY)
   {
      double newSL = r[1].low - TrailBufferPoints*Pt();
      if(newSL > sl && newSL < t.bid) trade.PositionModify(g_symbol, newSL, tp);
   }
   else
   {
      double newSL = r[1].high + TrailBufferPoints*Pt();
      if((sl==0.0 || newSL < sl) && newSL > t.ask) trade.PositionModify(g_symbol, newSL, tp);
   }
}

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   g_symbol = (SymbolToTrade=="" ? _Symbol : SymbolToTrade);
   if(!SymbolSelect(g_symbol, true)) { Print("Cannot select symbol: ", g_symbol); return INIT_FAILED; }

   DigitsCount = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   PointVal    = SymbolInfoDouble(g_symbol, SYMBOL_POINT);

   if(!LoadHandles()) { Print("Indicator handle creation failed"); return INIT_FAILED; }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastHandle!=INVALID_HANDLE)  { IndicatorRelease(fastHandle);  fastHandle=INVALID_HANDLE; }
   if(slowHandle!=INVALID_HANDLE)  { IndicatorRelease(slowHandle);  slowHandle=INVALID_HANDLE; }
   if(trendHandle!=INVALID_HANDLE) { IndicatorRelease(trendHandle); trendHandle=INVALID_HANDLE; }
   if(rsiHandle!=INVALID_HANDLE)   { IndicatorRelease(rsiHandle);   rsiHandle=INVALID_HANDLE; }
   if(macdHandle!=INVALID_HANDLE)  { IndicatorRelease(macdHandle);  macdHandle=INVALID_HANDLE; }
}

void OnTick()
{
   if(!TimeFilterPass()) { ManageTrailing(); return; }
   if(!SpreadOK())       { ManageTrailing(); return; }

   if(OneTradePerBar && !NewSignalBar()) { ManageTrailing(); return; }

   if(OnePositionOnly && PositionSelect(g_symbol)) { ManageTrailing(); return; }

   SignalType sig = ComputeSignal();
   if(sig==SIG_NONE) { ManageTrailing(); return; }

   if(!CloseOppositeIfNeeded(sig)) { ManageTrailing(); return; }

   bool ok = OpenTrade(sig);
   if(!ok) Print("Order failed: ", GetLastError());

   ManageTrailing();
}