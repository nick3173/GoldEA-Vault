//+------------------------------------------------------------------+
//|                                                Gold Autobot.mq5    |
//|  Intraday structure EA: Daily bias -> M15 MSS -> M1 execution     |
//|  Key levels: Weekly H/L, Monday Open, PDH/PDL, Daily Open         |
//|  TP1: 75% at nearest key level; runner exits on opposite M15 MSS  |
//|  Trailing: M15 HL/LH; Emergency risk cap: $400 (auto-reduce opt)  |
//+------------------------------------------------------------------+
#property copyright "User-driven spec"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade         trade;
CPositionInfo  pos;

//------------------------- Inputs ----------------------------------//
input ulong   InpMagic               = 26032026;
input double  InpFixedLot            = 0.10;   // Fixed lot (if AutoLotReduce=false)
input bool    InpAutoLotReduce       = true;   // Reduce lot to fit max risk if needed
input double  InpMaxRiskUSD          = 400.0;  // Emergency max loss per trade (account currency)
input double  InpTP1ClosePercent     = 75.0;   // Close % at TP1
input int     InpSlippagePoints      = 30;

// Noise filter (portable, ATR-based)
input bool    InpUseNoiseFilter      = true;
input double  InpATRAliveThreshold   = 0.90;   // ATR15 >= threshold * SMA(ATR15,20)
input double  InpDispBodyATR         = 0.60;   // Body >= DispBodyATR * ATR15
input double  InpDispBodyToRange     = 0.55;   // Body/Range >= this
input int     InpFlipLookbackM15     = 16;     // Count MSS flips within last K M15 candles
input int     InpMaxFlipsAllowed     = 1;      // Allow at most 1 flip; block if flips >= 2
input double  InpRangeMinATRMult     = 2.20;   // Range20 >= mult * ATR15

// Key level proximity
input double  InpLevelProxATR        = 0.20;   // Price must be within this * ATR15 from a key level

// Swing detection via Fractals
input int     InpFractalDepth        = 2;      // iFractals default is 2; keep for consistency
input ENUM_TIMEFRAMES InpBiasTF      = PERIOD_D1;
input ENUM_TIMEFRAMES InpMssTF       = PERIOD_M15;
input ENUM_TIMEFRAMES InpExecTF      = PERIOD_M1;
input ENUM_TIMEFRAMES InpTrailTF     = PERIOD_M15;

// Runner controls
input bool    InpExitOnOppositeMSS   = true;
input bool    InpProfitGivebackCap   = true;
input double  InpGivebackUSD         = 400.0;  // Max giveback from peak floating PnL (account currency)

//------------------------- Internal State --------------------------//
enum BiasDir {BIAS_NONE=0, BIAS_BUY=1, BIAS_SELL=-1};

datetime g_lastMssTime = 0;
BiasDir  g_lastMssDir  = BIAS_NONE;

bool     g_tp1Done     = false;
double   g_tp1Price    = 0.0;

double   g_peakProfit  = 0.0;

//------------------------- Utilities --------------------------------//
double SymbolTickValue()
{
   double v=0;
   SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE, v);
   return v;
}
double SymbolTickSize()
{
   double s=0;
   SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE, s);
   return s;
}
double PointValuePerLot()
{
   // value per point per 1 lot (account currency)
   double tick_val = SymbolTickValue();
   double tick_sz  = SymbolTickSize();
   if(tick_sz<=0) return 0;
   return tick_val * (_Point / tick_sz);
}
double ClampLot(double lot)
{
   double minLot, maxLot, step;
   SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN, minLot);
   SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX, maxLot);
   SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP, step);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   // normalize to step
   lot = MathFloor(lot/step)*step;
   return lot;
}

bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastBarTime)
{
   datetime t = iTime(_Symbol, tf, 0);
   if(t!=0 && t!=lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}

double ATR(ENUM_TIMEFRAMES tf, int period, int shift)
{
   int handle = iATR(_Symbol, tf, period);
   if(handle==INVALID_HANDLE) return 0;
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(handle,0,shift,1,buf)!=1) { IndicatorRelease(handle); return 0; }
   IndicatorRelease(handle);
   return buf[0];
}

double SMA_ATR(ENUM_TIMEFRAMES tf, int atrPeriod, int smaPeriod, int shiftStart)
{
   // average of ATR values over smaPeriod bars starting at shiftStart
   double sum=0;
   for(int i=0;i<smaPeriod;i++)
      sum += ATR(tf, atrPeriod, shiftStart+i);
   return (smaPeriod>0)? sum/smaPeriod : 0;
}

//-------------- Fractal-based Swing Retrieval ----------------------//
bool GetLastTwoFractalHighs(ENUM_TIMEFRAMES tf, double &lastH, int &lastShift, double &prevH, int &prevShift)
{
   int h = iFractals(_Symbol, tf);
   if(h==INVALID_HANDLE) return false;
   double up[];
   ArraySetAsSeries(up,true);
   int bars = MathMin(500, iBars(_Symbol, tf));
   if(CopyBuffer(h,0,0,bars,up)<=0){ IndicatorRelease(h); return false; }
   IndicatorRelease(h);

   lastH=0; prevH=0; lastShift=-1; prevShift=-1;
   for(int i=2;i<bars;i++) // start at 2 to ensure confirmed
   {
      if(up[i]!=0.0)
      {
         if(lastShift==-1){ lastH=up[i]; lastShift=i; }
         else { prevH=up[i]; prevShift=i; break; }
      }
   }
   return (lastShift!=-1 && prevShift!=-1);
}

bool GetLastTwoFractalLows(ENUM_TIMEFRAMES tf, double &lastL, int &lastShift, double &prevL, int &prevShift)
{
   int h = iFractals(_Symbol, tf);
   if(h==INVALID_HANDLE) return false;
   double dn[];
   ArraySetAsSeries(dn,true);
   int bars = MathMin(500, iBars(_Symbol, tf));
   if(CopyBuffer(h,1,0,bars,dn)<=0){ IndicatorRelease(h); return false; }
   IndicatorRelease(h);

   lastL=0; prevL=0; lastShift=-1; prevShift=-1;
   for(int i=2;i<bars;i++)
   {
      if(dn[i]!=0.0)
      {
         if(lastShift==-1){ lastL=dn[i]; lastShift=i; }
         else { prevL=dn[i]; prevShift=i; break; }
      }
   }
   return (lastShift!=-1 && prevShift!=-1);
}

BiasDir GetDowBiasDaily()
{
   // Dow-ish: Bullish if last fractal high > previous fractal high AND last fractal low > previous fractal low
   double lh, ph, ll, pl; int sh1, sh2, sl1, sl2;
   bool okH = GetLastTwoFractalHighs(InpBiasTF, lh, sh1, ph, sh2);
   bool okL = GetLastTwoFractalLows (InpBiasTF, ll, sl1, pl, sl2);
   if(!okH || !okL) return BIAS_NONE;
   if(lh>ph && ll>pl) return BIAS_BUY;
   if(ll<pl && lh<ph) return BIAS_SELL;
   return BIAS_NONE;
}

//-------------- MSS detection on M15 (close break) ------------------//
bool DetectMSS(BiasDir &dirOut, datetime &timeOut)
{
   // Use last confirmed fractal high/low as structure points.
   double lastH, prevH, lastL, prevL; int sh1, sh2, sl1, sl2;
   if(!GetLastTwoFractalHighs(InpMssTF, lastH, sh1, prevH, sh2)) return false;
   if(!GetLastTwoFractalLows (InpMssTF, lastL, sl1, prevL, sl2)) return false;

   // Check most recently closed candle (shift 1) close breaks above last fractal high or below last fractal low.
   double c1 = iClose(_Symbol, InpMssTF, 1);
   datetime t1 = iTime(_Symbol, InpMssTF, 1);
   if(c1==0 || t1==0) return false;

   if(c1 > lastH)
   {
      dirOut = BIAS_BUY;
      timeOut = t1;
      return true;
   }
   if(c1 < lastL)
   {
      dirOut = BIAS_SELL;
      timeOut = t1;
      return true;
   }
   return false;
}

//-------------- Noise Filter (portable) -----------------------------//
bool NoiseOK()
{
   if(!InpUseNoiseFilter) return true;

   double atr15 = ATR(PERIOD_M15,14,1);
   if(atr15<=0) return false;
   double atrAvg = SMA_ATR(PERIOD_M15,14,20,1);
   if(atrAvg<=0) return false;

   // 1) ATR alive
   if(atr15 < InpATRAliveThreshold * atrAvg) return false;

   // 2) Displacement (use last closed M15 candle)
   double o = iOpen(_Symbol, PERIOD_M15, 1);
   double c = iClose(_Symbol, PERIOD_M15, 1);
   double h = iHigh(_Symbol, PERIOD_M15, 1);
   double l = iLow (_Symbol, PERIOD_M15, 1);
   double body = MathAbs(c-o);
   double range = MathMax(h-l, _Point);

   if(body < InpDispBodyATR * atr15) return false;
   if((body/range) < InpDispBodyToRange) return false;

   // 3) Flip-flop: count MSS flips in last K candles by scanning closes across last fractal levels.
   // Simple approximation: count changes in direction of MSS detections on each bar.
   int flips=0;
   BiasDir lastDir=BIAS_NONE;
   for(int i=1;i<=InpFlipLookbackM15;i++)
   {
      // Determine if candle i is an MSS candle by checking break of most recent fractal level before it.
      // Approx: compare close to recent fractal high/low found in window ahead.
      // For robustness & speed: detect impulsive direction by candle body vs ATR and close vs previous close.
      double oi=iOpen(_Symbol,PERIOD_M15,i);
      double ci=iClose(_Symbol,PERIOD_M15,i);
      double hi=iHigh(_Symbol,PERIOD_M15,i);
      double li=iLow(_Symbol,PERIOD_M15,i);
      double bi=MathAbs(ci-oi);
      double ri=MathMax(hi-li,_Point);
      if(bi < 0.4*atr15 || (bi/ri) < 0.45) continue; // only count meaningful shifts

      BiasDir d = (ci>oi)? BIAS_BUY : BIAS_SELL;
      if(lastDir==BIAS_NONE) lastDir=d;
      else if(d!=lastDir) { flips++; lastDir=d; }
   }
   if(flips > InpMaxFlipsAllowed) return false;

   // 4) Range expansion: last 20 M15 bars
   double hh=-DBL_MAX, ll=DBL_MAX;
   for(int i=1;i<=20;i++)
   {
      hh = MathMax(hh, iHigh(_Symbol, PERIOD_M15, i));
      ll = MathMin(ll, iLow (_Symbol, PERIOD_M15, i));
   }
   if((hh-ll) < InpRangeMinATRMult * atr15) return false;

   return true;
}

//-------------- Key Levels -----------------------------------------//
struct KeyLevel { double low; double high; int type; }; // if low==high => line
enum KeyType {K_WHI=1,K_WLO=2,K_MON=3,K_PDH=4,K_PDL=5,K_DOPEN=6};

// Helper: push a KeyLevel into dynamic array
void KeyLevelPush(KeyLevel &arr[], const KeyLevel &item)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n+1);
   arr[n] = item;
}


int GetMondayDailyShift()
{
   // Find the D1 bar index for Monday of the current week (server time).
   // We search back up to 10 daily bars.
   for(int i=0;i<10;i++)
   {
      datetime t = iTime(_Symbol, PERIOD_D1, i);
      if(t==0) continue;
      MqlDateTime dt; TimeToStruct(t, dt);
      if(dt.day_of_week==1) return i; // Monday
   }
   return -1;
}

int BuildKeyLevels(KeyLevel &levels[])
{
   ArrayResize(levels,0);

   // Weekly high/low of last completed week (shift 1)
   KeyLevel k;
   k.type=K_WHI; k.low=iHigh(_Symbol, PERIOD_W1, 1); k.high=k.low; KeyLevelPush(levels,k);
   k.type=K_WLO; k.low=iLow (_Symbol, PERIOD_W1, 1); k.high=k.low; KeyLevelPush(levels,k);

   // Monday Open
   int monShift = GetMondayDailyShift();
   if(monShift>=0)
   {
      k.type=K_MON; k.low=iOpen(_Symbol, PERIOD_D1, monShift); k.high=k.low; KeyLevelPush(levels,k);
   }

   // PDH / PDL (yesterday, shift 1)
   k.type=K_PDH; k.low=iHigh(_Symbol, PERIOD_D1, 1); k.high=k.low; KeyLevelPush(levels,k);
   k.type=K_PDL; k.low=iLow (_Symbol, PERIOD_D1, 1); k.high=k.low; KeyLevelPush(levels,k);

   // Daily open (today, shift 0)
   k.type=K_DOPEN; k.low=iOpen(_Symbol, PERIOD_D1, 0); k.high=k.low; KeyLevelPush(levels,k);

   return ArraySize(levels);
}

double NearestKeyLevelPrice(double price, BiasDir dir, KeyLevel &levels[])
{
   // For TP: nearest key level in profit direction.
   double best = 0.0;
   double bestDist = DBL_MAX;
   for(int i=0;i<ArraySize(levels);i++)
   {
      double lvl = levels[i].low;
      if(dir==BIAS_BUY && lvl>price)
      {
         double d = lvl - price;
         if(d < bestDist){ bestDist=d; best=lvl; }
      }
      if(dir==BIAS_SELL && lvl<price)
      {
         double d = price - lvl;
         if(d < bestDist){ bestDist=d; best=lvl; }
      }
   }
   return best;
}

bool NearReactionLevel(double price, BiasDir dir, KeyLevel &levels[])
{
   // Require price within proximity of a relevant level on the reaction side:
   // BUY: nearest support level at/below price; SELL: nearest resistance at/above price.
   double atr15 = ATR(PERIOD_M15,14,1);
   if(atr15<=0) return false;
   double prox = InpLevelProxATR * atr15;

   double bestDist = DBL_MAX;
   for(int i=0;i<ArraySize(levels);i++)
   {
      double lvl = levels[i].low;
      if(dir==BIAS_BUY && lvl<=price)
      {
         double d = price - lvl;
         if(d < bestDist) bestDist=d;
      }
      if(dir==BIAS_SELL && lvl>=price)
      {
         double d = lvl - price;
         if(d < bestDist) bestDist=d;
      }
   }
   return (bestDist != DBL_MAX && bestDist <= prox);
}

//-------------- M1 Pullback + Break Confirmation --------------------//
bool GetLastFractalHigh(ENUM_TIMEFRAMES tf, int fromShift, double &val, int &shiftOut)
{
   int h = iFractals(_Symbol, tf);
   if(h==INVALID_HANDLE) return false;
   double up[];
   ArraySetAsSeries(up,true);
   int bars = MathMin(500, iBars(_Symbol, tf));
   if(CopyBuffer(h,0,0,bars,up)<=0){ IndicatorRelease(h); return false; }
   IndicatorRelease(h);
   for(int i=fromShift;i<bars;i++)
      if(up[i]!=0.0){ val=up[i]; shiftOut=i; return true; }
   return false;
}

bool GetLastFractalLow(ENUM_TIMEFRAMES tf, int fromShift, double &val, int &shiftOut)
{
   int h = iFractals(_Symbol, tf);
   if(h==INVALID_HANDLE) return false;
   double dn[];
   ArraySetAsSeries(dn,true);
   int bars = MathMin(500, iBars(_Symbol, tf));
   if(CopyBuffer(h,1,0,bars,dn)<=0){ IndicatorRelease(h); return false; }
   IndicatorRelease(h);
   for(int i=fromShift;i<bars;i++)
      if(dn[i]!=0.0){ val=dn[i]; shiftOut=i; return true; }
   return false;
}

bool EntrySignal(BiasDir bias, datetime mssTime, double &entryPrice, double &slPrice)
{
   // We trade M15 swing structures but execute on M1:
   // - require a pullback swing (fractal) after MSS time
   // - enter on break of opposite fractal in direction.
   // Use last closed M1 candle for confirmation.
   datetime t1 = iTime(_Symbol, PERIOD_M1, 1);
   if(t1==0 || mssTime==0) return false;

   // Ensure we're within 60 minutes of MSS for intraday scalping
   if((t1 - mssTime) > 60*60) return false;

   // Find the first M1 fractal after mssTime (pullback point)
   int bars = iBars(_Symbol, PERIOD_M1);
   int startShift = -1;
   for(int i=1;i<MathMin(bars,500);i++)
   {
      datetime ti = iTime(_Symbol, PERIOD_M1, i);
      if(ti<=mssTime) { startShift=i; break; } // shifts increase into past
   }
   if(startShift<0) startShift=100;

   double pullVal; int pullShift;
   double breakVal; int breakShift;

   if(bias==BIAS_BUY)
   {
      // Pullback = fractal low (HL zone on micro)
      if(!GetLastFractalLow(PERIOD_M1, 1, pullVal, pullShift)) return false;
      // We need that pullback fractal low to be AFTER MSS time (i.e., more recent than mssTime)
      if(iTime(_Symbol, PERIOD_M1, pullShift) < mssTime) return false;

      // Break = fractal high after pullback (micro LH broken)
      if(!GetLastFractalHigh(PERIOD_M1, 1, breakVal, breakShift)) return false;
      if(iTime(_Symbol, PERIOD_M1, breakShift) < iTime(_Symbol, PERIOD_M1, pullShift)) return false;

      double close1 = iClose(_Symbol, PERIOD_M1, 1);
      if(close1 <= breakVal) return false;

      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // SL under pullback low with small buffer
      double buf = 5*_Point;
      slPrice = pullVal - buf;
      return true;
   }
   if(bias==BIAS_SELL)
   {
      // Pullback = fractal high
      if(!GetLastFractalHigh(PERIOD_M1, 1, pullVal, pullShift)) return false;
      if(iTime(_Symbol, PERIOD_M1, pullShift) < mssTime) return false;

      // Break = fractal low after pullback
      if(!GetLastFractalLow(PERIOD_M1, 1, breakVal, breakShift)) return false;
      if(iTime(_Symbol, PERIOD_M1, breakShift) < iTime(_Symbol, PERIOD_M1, pullShift)) return false;

      double close1 = iClose(_Symbol, PERIOD_M1, 1);
      if(close1 >= breakVal) return false;

      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double buf = 5*_Point;
      slPrice = pullVal + buf;
      return true;
   }
   return false;
}

double RiskForSL(double entry, double sl, double lot)
{
   double pointVal = PointValuePerLot();
   if(pointVal<=0) return DBL_MAX;
   double points = MathAbs(entry - sl)/_Point;
   return points * pointVal * lot;
}

double LotForMaxRisk(double entry, double sl, double maxRisk)
{
   double pointVal = PointValuePerLot();
   if(pointVal<=0) return 0;
   double points = MathAbs(entry - sl)/_Point;
   if(points<=0) return 0;
   double lot = maxRisk / (points * pointVal);
   return ClampLot(lot);
}

//-------------- Trade Management -----------------------------------//
void ResetTradeState()
{
   g_tp1Done=false;
   g_tp1Price=0.0;
   g_peakProfit=0.0;
}

bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(pos.SelectByIndex(i))
      {
         if(pos.Magic()==(long)InpMagic && pos.Symbol()==_Symbol)
            return true;
      }
   }
   return false;
}

bool SelectOurPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(pos.SelectByIndex(i))
      {
         if(pos.Magic()==(long)InpMagic && pos.Symbol()==_Symbol)
            return true;
      }
   }
   return false;
}

void ManagePosition()
{
   if(!SelectOurPosition()) return;

   long type = pos.PositionType();
   double entry = pos.PriceOpen();
   double sl = pos.StopLoss();
   double tp = pos.TakeProfit();
   double vol = pos.Volume();
   double profit = pos.Profit();

   // Track peak profit
   if(profit > g_peakProfit) g_peakProfit = profit;

   // Giveback cap (close position if drawdown from peak exceeds threshold)
   if(InpProfitGivebackCap && g_peakProfit > 0.0 && (g_peakProfit - profit) >= InpGivebackUSD)
   {
      trade.PositionClose(_Symbol, InpSlippagePoints);
      ResetTradeState();
      return;
   }

   // TP1 handling (75% close at nearest key level set at entry time)
   if(!g_tp1Done && g_tp1Price>0.0)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      bool hit = false;
      if(type==POSITION_TYPE_BUY && bid >= g_tp1Price) hit=true;
      if(type==POSITION_TYPE_SELL && ask <= g_tp1Price) hit=true;

      if(hit)
      {
         double closeVol = vol * (InpTP1ClosePercent/100.0);
         closeVol = ClampLot(closeVol);
         if(closeVol > 0.0 && closeVol < vol)
            trade.PositionClosePartial(_Symbol, closeVol, InpSlippagePoints);
         g_tp1Done=true;
      }
   }

   // Exit on opposite M15 MSS
   if(InpExitOnOppositeMSS)
   {
      BiasDir dir; datetime t;
      if(DetectMSS(dir,t))
      {
         // If new MSS opposite to current position direction and is newer than lastMSS time
         if(t > g_lastMssTime)
         {
            if(type==POSITION_TYPE_BUY && dir==BIAS_SELL)
            {
               trade.PositionClose(_Symbol, InpSlippagePoints);
               ResetTradeState();
               return;
            }
            if(type==POSITION_TYPE_SELL && dir==BIAS_BUY)
            {
               trade.PositionClose(_Symbol, InpSlippagePoints);
               ResetTradeState();
               return;
            }
         }
      }
   }

   // Trail SL to new M15 HL/LH (fractals)
   double newSL=sl;
   if(type==POSITION_TYPE_BUY)
   {
      // Move SL to latest confirmed M15 fractal low (HL)
      double fl; int sh;
      if(GetLastFractalLow(InpTrailTF, 2, fl, sh))
      {
         // Only trail upwards
         double buf = 5*_Point;
         double candidate = fl - buf;
         if(candidate > newSL && candidate < SymbolInfoDouble(_Symbol, SYMBOL_BID))
            newSL = candidate;
      }
   }
   else if(type==POSITION_TYPE_SELL)
   {
      double fh; int sh;
      if(GetLastFractalHigh(InpTrailTF, 2, fh, sh))
      {
         double buf = 5*_Point;
         double candidate = fh + buf;
         if((newSL==0.0 || candidate < newSL) && candidate > SymbolInfoDouble(_Symbol, SYMBOL_ASK))
            newSL = candidate;
      }
   }

   if(newSL != sl && newSL>0.0)
   {
      trade.PositionModify(_Symbol, newSL, tp);
   }
}

//------------------------- OnInit/OnTick -----------------------------//
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   ResetTradeState();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){}

void OnTick()
{
   // Manage existing position first
   if(HasOpenPosition())
   {
      ManagePosition();
      return;
   }
   else
   {
      // Ensure state reset when flat
      ResetTradeState();
   }

   // Gate 0: Noise filter
   if(!NoiseOK()) return;

   // Daily bias
   BiasDir dailyBias = GetDowBiasDaily();
   if(dailyBias==BIAS_NONE) return;

   // Key levels
   KeyLevel levels[];
   BuildKeyLevels(levels);

   double midPrice = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
   // Require price near a reaction key level on correct side
   if(!NearReactionLevel(midPrice, dailyBias, levels)) return;

   // M15 MSS in direction of daily bias
   BiasDir mssDir; datetime mssTime;
   if(!DetectMSS(mssDir, mssTime)) return;
   if(mssDir != dailyBias) return;

   // Entry on M1 confirmation
   double entry, sl;
   if(!EntrySignal(dailyBias, mssTime, entry, sl)) return;

   // Risk cap: compute lot
   double lot = InpFixedLot;
   double risk = RiskForSL(entry, sl, lot);
   if(risk > InpMaxRiskUSD)
   {
      if(!InpAutoLotReduce) return;
      lot = LotForMaxRisk(entry, sl, InpMaxRiskUSD);
      if(lot <= 0.0) return;
      risk = RiskForSL(entry, sl, lot);
      if(risk > InpMaxRiskUSD) return;
   }
   lot = ClampLot(lot);
   if(lot<=0) return;

   // Set TP1 to nearest key level in profit direction (H1 is naturally nearest, but levels include multiple)
   double tp1 = NearestKeyLevelPrice(entry, dailyBias, levels);
   if(tp1<=0) return;

   // Place order
   bool ok=false;
   if(dailyBias==BIAS_BUY)
      ok = trade.Buy(lot, _Symbol, 0.0, sl, 0.0, "Gold Autobot BUY");
   else if(dailyBias==BIAS_SELL)
      ok = trade.Sell(lot, _Symbol, 0.0, sl, 0.0, "Gold Autobot SELL");

   if(ok)
   {
      g_lastMssTime = mssTime;
      g_lastMssDir  = dailyBias;
      g_tp1Price    = tp1;
      g_tp1Done     = false;
      g_peakProfit  = 0.0;
   }
}
//+------------------------------------------------------------------+
