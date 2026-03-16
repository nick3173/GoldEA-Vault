//+------------------------------------------------------------------+
//|              GoldEAResurrection_v4_MicroV.mq5                      |
//|  True M1 Scalper - Micro V Reversal Model (no fractals)            |
//|                                                                    |
//|  BUY patterns (mirror for SELL):                                   |
//|   A) Bearish candle -> Bullish engulf -> confirmation candle closes|
//|      above engulf high -> ENTER on next bar open                   |
//|   B) Bullish engulf -> retrace <= 50% of engulf range + rejection  |
//|      wick -> ENTER on next bar open                                |
//|                                                                    |
//|  Risk / Exits:                                                     |
//|   SL = previous LL (structure) + ATR buffer                        |
//|   TP1 = previous HH/LL (close 75%)                                 |
//|   TP2 = session high/low (runner)                                  |
//|   Trailing: +100 pips => lock 50% (hard trailing stop)             |
//|   While trailing ON: don't close on opposite signal;               |
//|   Close only on candle-close engulf against position               |
//|                                                                    |
//|  Stacking: up to 3 trades per direction                            |
//+------------------------------------------------------------------+
#property strict
#property version "4.15"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade trade;
CPositionInfo pos;

//-------------------- Inputs --------------------
input ulong   InpMagic             = 26032026;
input double  InpFixedLot          = 0.10;
input int     InpMaxStackPerDir    = 3;

input int     InpATRPeriod         = 14;
input double  InpSLBufferATRMult   = 0.15;

input int     InpStructLookback    = 40;   // for prev HH/LL
input int     InpSessionBars       = 300;  // for TP2

// Pattern tuning
input double  InpRetraceMax        = 0.50; // <=50% retrace
input double  InpRejectionWickBody = 1.20; // wick >= body*X
input bool    InpRequireBearishPushForEngulf = true; // step 1 bearish candle before bullish engulf

// Trailing / exit
input int     InpTrailStartPips    = 100;
input double  InpTrailLockPercent  = 50.0;
input double  InpTP1ClosePercent   = 50.0;  // TP1 partial close percent (recommended 50%)

// Profit rules (money-based)
input double  InpTP1Money          = 40.0;  // when floating profit hits this, execute TP1 actions
input double  InpRiskFreeLockMoney = 5.0;   // after TP1, move SL to lock at least this profit on remaining runner
input double  InpRunnerDrawdownMoney = 15.0; // close runner if profit retraces this amount from peak
input double  InpRunnerPeakMinMoney  = 40.0; // peak must reach at least this before drawdown exit can trigger


input int     InpSlippagePoints    = 30;



// Execution / safety filters
input int     InpTradeCooldownSeconds   = 60;   // minimum seconds between new entries (normal cooldown)
input int     InpMaxSpreadPoints        = 80;   // max allowed spread in POINTS (Gold often 20-60; tune per broker)

// Expansion / leg harvesting (scale-in during one expansion leg)
input bool    InpEnableLegHarvesting    = true;
input int     InpMaxEntriesPerLeg       = 5;
input int     InpLegMaxBars             = 60;   // end leg if it lasts too long without reset
input int     InpLegPullbackLookback    = 4;    // bars to define pullback window
input int     InpLegPullbackMaxBars     = 6;    // pullback must resolve within this many bars
input double  InpLegMaxRetrace          = 0.50; // pullback retrace vs impulse range
input double  InpDispBodyMult           = 1.6;  // displacement body >= avgBody*N triggers expansion state
input double  InpDispStrongCloseFrac    = 0.25; // close within top/bottom 25% of range
input int     InpDispAvgBodyBars        = 10;   // bars used to compute avg body
input int     InpReentryHLBufferPoints  = 10;   // extra discipline: price must remain beyond last HL/LH by this buffer (points)
   // max allowed spread in POINTS (Gold often 20-60; tune per broker)

// Abnormal (news-like) spike / emergency pause
input double  InpAbnormalRangeATRMult   = 4.0;  // bar range >= ATR(avg)*X OR spread spike triggers pause
input double  InpAbnormalSpreadMult     = 2.5;  // spread >= avgSpread*X triggers pause
input int     InpPauseMinutesOnAbnormal = 30;   // pause trading after abnormal spike detected
input int     InpPauseMinutesAfterSL    = 60;   // pause trading after a stop-loss event (capital protection)

// Recovery conditions (resume when market normal again)
input double  InpRecoveryATRMult        = 1.6;  // ATR(short) must be <= ATR(avg)*X to count as "normal"
input int     InpRecoveryBars           = 5;    // number of consecutive normal bars required to resume
input int     InpATRAvgBars             = 20;   // bars used for ATR average baseline
input int     InpSpreadAvgBars          = 30;   // bars used for spread average baseline


// Market environment (Gold-specific) - avoid Asian compression
input int    InpCompressionShortATR = 10;
input int    InpCompressionLongATR  = 50;
input double InpCompressionRatio    = 0.6;  // shortATR < longATR*ratio => compressed

// Expansion strength (allows extra harvesting entries when leg is very strong)
input double InpStrongBodyMult      = 2.2;  // stronger displacement body threshold vs avg body
input double InpStrongATRMult       = 1.5;  // ATR(Short) >= ATR(Avg)*mult => strong environment
input int    InpStrongExtraEntries  = 2;    // extra entries allowed in strong legs (5+2=7)
input int    InpMaxEntriesStrongCap = 7;    // hard cap for strong legs

// MSS protection (close profitable positions on structure shift)
input double InpMSSBodyMult         = 1.5;  // opposite displacement body multiplier
input int    InpMSSBufferPoints     = 5;    // buffer beyond HL/LH to confirm MSS
// Debug
input bool    InpShowHUD           = true;
input bool    InpVerboseLogs       = true;

//-------------------- State --------------------
datetime g_lastBarTime=0;



// Trade pacing / safety state
datetime g_lastTradeTime=0;

// Emergency pause state (news-like volatility / abnormal impulse)
datetime g_pauseUntil=0;
int      g_recoveryCount=0;
string   g_pauseReason="";

// Profit tracking (tickets / TP1 / runner peak)
ulong  g_tickets[];

// -------------------- ATR helper for arbitrary periods (MQL5-safe) --------------------
double ATR_Period(int period, int shift=1)
{
   // Cache 2 handles (short/long) which are the only ones needed for this EA.
   static int h_short=-1, h_long=-1;
   int &h = (period==InpCompressionShortATR ? h_short : h_long);

   // If someone calls a period that's not short or long, fall back to the main ATR().
   if(period!=InpCompressionShortATR && period!=InpCompressionLongATR)
      return ATR(shift);

   if(h==-1) h=iATR(_Symbol,PERIOD_M1,period);
   if(h==-1) return 0.0;
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(h,0,shift,1,b)!=1) return 0.0;
   return b[0];
}

//-------------------- Helpers --------------------
double PipToPrice(){ if(_Digits==3||_Digits==5) return 10.0*_Point; return _Point; }



// Spread helpers (POINTS)
double SpreadPoints()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   return (ask-bid)/_Point;
}

double AvgSpreadPoints(int bars)
{
   // Approximate using historical tick spreads is not available in standard OHLC,
   // so we estimate from recorded SYMBOL_SPREAD at runtime by sampling once per bar.
   // We'll store a simple rolling average using static buffer.
   static double buf[];
   static datetime lastSample=0;

   datetime t=iTime(_Symbol,PERIOD_M1,0);
   if(t!=0 && t!=lastSample) // new bar sample
   {
      lastSample=t;
      double s=SpreadPoints();
      int n=ArraySize(buf);
      ArrayResize(buf,n+1);
      buf[n]=s;
      // keep last 'bars'
      if(ArraySize(buf)>bars)
      {
         int drop=ArraySize(buf)-bars;
         for(int i=0;i<ArraySize(buf)-drop;i++) buf[i]=buf[i+drop];
         ArrayResize(buf,bars);
      }
   }

   int n=ArraySize(buf);
   if(n<=0) return SpreadPoints();
   double sum=0;
   for(int i=0;i<n;i++) sum+=buf[i];
   return sum/n;
}

bool SpreadOK()
{
   double s=SpreadPoints();
   return (s<=InpMaxSpreadPoints);
}

// ATR baseline
double ATRAvg(int bars, int startShift=1)
{
   static int h=-1;
   if(h==-1) h=iATR(_Symbol,PERIOD_M1,InpATRPeriod);
   if(h==-1) return 0.0;

   int need=bars;
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(h,0,startShift,need,b)!=need) return 0.0;

   double sum=0;
   for(int i=0;i<need;i++) sum+=b[i];
   return sum/need;
}

bool IsPaused()
{
   if(g_pauseUntil==0) return false;
   return (TimeCurrent() < g_pauseUntil);
}

void StartPause(int minutes, const string &reason)
{
   g_pauseUntil = TimeCurrent() + minutes*60;
   g_recoveryCount = 0;
   g_pauseReason = reason;
   if(InpVerboseLogs) Print("PAUSE STARTED: ",reason," | until ",TimeToString(g_pauseUntil,TIME_DATE|TIME_SECONDS));
}

// Detect a "news-like" environment using only price/spread (no news feed required)
void UpdatePauseStateOnNewBar()
{
   // If already paused, check recovery conditions
   if(IsPaused())
   {
      // We still count recovery bars even before pause ends, but only resume after pause time + recovery bars.
      double atrShort=ATR(1); // last closed bar ATR
      double atrBase = ATRAvg(InpATRAvgBars,1);
      if(atrBase<=0) atrBase=atrShort;

      double s=SpreadPoints();
      double sAvg=AvgSpreadPoints(InpSpreadAvgBars);

      bool normal = (atrShort <= atrBase*InpRecoveryATRMult) && (s <= MathMax((double)InpMaxSpreadPoints, sAvg*1.2));
      if(normal) g_recoveryCount++;
      else g_recoveryCount=0;

      return;
   }

   // Not paused: detect abnormality
   // 1) Huge bar range vs ATR baseline
   double r = iHigh(_Symbol,PERIOD_M1,1) - iLow(_Symbol,PERIOD_M1,1); // last closed bar range
   double atrBase = ATRAvg(InpATRAvgBars,1);
   if(atrBase<=0) atrBase = ATR(1);

   bool rangeSpike = (atrBase>0 && r >= atrBase*InpAbnormalRangeATRMult);

   // 2) Spread spike vs average
   double s=SpreadPoints();
   double sAvg=AvgSpreadPoints(InpSpreadAvgBars);
   if(sAvg<=0) sAvg=s;
   bool spreadSpike = (s >= sAvg*InpAbnormalSpreadMult);

   if(rangeSpike || spreadSpike)
   {
      string reason="News-like spike detected: ";
      if(rangeSpike)  reason += "RANGE>=ATR*"+DoubleToString(InpAbnormalRangeATRMult,1)+" ";
      if(spreadSpike) reason += "SPREAD>=AVG*"+DoubleToString(InpAbnormalSpreadMult,1)+" ";
      StartPause(InpPauseMinutesOnAbnormal, reason);
   }
}

// Call this on every tick to resume when safe
bool CanResumeNow()
{
   if(!IsPaused()) return true;
   // Require BOTH: pause timer elapsed AND recovery bars achieved
   if(TimeCurrent() >= g_pauseUntil && g_recoveryCount >= InpRecoveryBars)
   {
      if(InpVerboseLogs) Print("PAUSE ENDED: market normalized. RecoveryBars=",g_recoveryCount," Reason was: ",g_pauseReason);
      g_pauseUntil=0;
      g_pauseReason="";
      g_recoveryCount=0;
      return true;
   }
   return false;
}


// -------------------- Leg harvesting state --------------------
int      g_legDir=0;              // 1=buy leg, -1=sell leg, 0=none
int      g_legEntries=0;          // entries taken in current leg
int      g_legBars=0;             // bars since leg started
int      g_legPullbackBars=0;     // bars in pullback phase
bool     g_legActive=false;
double   g_legProtected=0.0;      // protected level for invalidation (uses actual SL to be safe)
double   g_legImpulseHigh=0.0;
double   g_legImpulseLow=0.0;
datetime g_legStartTime=0;
bool     g_legRiskFreeAchieved=false; // becomes true once any position in current leg hits TP1 and SL is moved to +$ lock
bool     g_legStrong=false;         // strong leg allows extra entries
double   g_legLastHL=0.0;           // engineered HL used for latest BUY entry SL base
double   g_legLastLH=0.0;           // engineered LH used for latest SELL entry SL base

double AvgBody(int bars, int startShift)
{
   double sum=0; int n=0;
   for(int i=startShift;i<startShift+bars;i++)
   {
      double b=Body(i);
      if(b<=0) continue;
      sum+=b; n++;
   }
   if(n<=0) return 0.0;
   return sum/n;
}


// -------------------- Market environment helpers --------------------
bool IsMarketCompressed()
{
   double s=ATR_Period(InpCompressionShortATR,1);
   double l=ATR_Period(InpCompressionLongATR,1);
   if(l<=0) return false;
   return (s < l*InpCompressionRatio);
}

// -------------------- Swing (pivot) detection for hybrid HL/LH --------------------
double DetectSwingHL(int lookback)
{
   // Find a recent pivot low (confirmed by neighbors). Shift starts at 3 to avoid current forming bars.
   int maxShift = MathMin(lookback, 40);
   for(int s=3; s<3+maxShift; s++)
   {
      double L=iLow(_Symbol,PERIOD_M1,s);
      if(L < iLow(_Symbol,PERIOD_M1,s-1) && L < iLow(_Symbol,PERIOD_M1,s+1))
         return L;
   }
   return 0.0;
}
double DetectSwingLH(int lookback)
{
   int maxShift = MathMin(lookback, 40);
   for(int s=3; s<3+maxShift; s++)
   {
      double H=iHigh(_Symbol,PERIOD_M1,s);
      if(H > iHigh(_Symbol,PERIOD_M1,s-1) && H > iHigh(_Symbol,PERIOD_M1,s+1))
         return H;
   }
   return 0.0;
}

// -------------------- Strength / MSS helpers --------------------
bool IsStrongDisplacement(int dir, int shift)
{
   // dir: 1 bull, -1 bear
   double b=Body(shift);
   double avg=AvgBody(InpDispAvgBodyBars, shift+1);
   if(avg<=0) return false;
   if(b < avg*InpStrongBodyMult) return false;

   // Also require ATR expansion (use only price-derived volatility)
   double atrS = ATR_Period(InpCompressionShortATR,1);
   double atrA = ATRAvg(InpATRAvgBars,1);
   if(atrA>0 && atrS < atrA*InpStrongATRMult) return false;

   // directional close strength
   double hi=iHigh(_Symbol,PERIOD_M1,shift), lo=iLow(_Symbol,PERIOD_M1,shift);
   double c=iClose(_Symbol,PERIOD_M1,shift);
   double rng=hi-lo; if(rng<=0) return false;

   if(dir==1) return (IsBull(shift) && (hi-c) <= rng*InpDispStrongCloseFrac);
   else       return (IsBear(shift) && (c-lo) <= rng*InpDispStrongCloseFrac);
}

int GetMaxEntriesPerLegDynamic()
{
   int base=InpMaxEntriesPerLeg;
   if(g_legStrong) base += InpStrongExtraEntries;
   if(base > InpMaxEntriesStrongCap) base = InpMaxEntriesStrongCap;
   return base;
}

void CloseProfitablePositionsDir(int dir)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      if(dir==1 && type!=POSITION_TYPE_BUY) continue;
      if(dir==-1 && type!=POSITION_TYPE_SELL) continue;

      double p=PositionGetDouble(POSITION_PROFIT);
      if(p>0) trade.PositionClose(ticket);
   }
}

bool DetectMSSAgainstLeg()
{
   // MSS = break beyond engineered HL/LH + opposite displacement-like candle
   if(!g_legActive) return false;

   double b=Body(1);
   double avg=AvgBody(InpDispAvgBodyBars, 2);
   bool dispOpp = (avg>0 && b >= avg*InpMSSBodyMult);

   if(g_legDir==1)
   {
      if(g_legLastHL<=0) return false;
      if(iClose(_Symbol,PERIOD_M1,1) < (g_legLastHL - InpMSSBufferPoints*_Point) && IsBear(1) && dispOpp)
         return true;
   }
   else if(g_legDir==-1)
   {
      if(g_legLastLH<=0) return false;
      if(iClose(_Symbol,PERIOD_M1,1) > (g_legLastLH + InpMSSBufferPoints*_Point) && IsBull(1) && dispOpp)
         return true;
   }
   return false;
}
bool IsDisplacementBull(int shift)
{
   double b=Body(shift);
   double avg=AvgBody(InpDispAvgBodyBars, shift+1);
   if(avg<=0) return false;
   if(b < avg*InpDispBodyMult) return false;

   double hi=iHigh(_Symbol,PERIOD_M1,shift), lo=iLow(_Symbol,PERIOD_M1,shift);
   double c=iClose(_Symbol,PERIOD_M1,shift);
   double rng=hi-lo; if(rng<=0) return false;
   // strong close near high
   return (IsBull(shift) && (hi-c) <= rng*InpDispStrongCloseFrac);
}
bool IsDisplacementBear(int shift)
{
   double b=Body(shift);
   double avg=AvgBody(InpDispAvgBodyBars, shift+1);
   if(avg<=0) return false;
   if(b < avg*InpDispBodyMult) return false;

   double hi=iHigh(_Symbol,PERIOD_M1,shift), lo=iLow(_Symbol,PERIOD_M1,shift);
   double c=iClose(_Symbol,PERIOD_M1,shift);
   double rng=hi-lo; if(rng<=0) return false;
   // strong close near low
   return (IsBear(shift) && (c-lo) <= rng*InpDispStrongCloseFrac);
}

void EndLeg(const string &reason)
{
   if(InpVerboseLogs && g_legActive) Print("LEG ENDED: ",reason," | dir=",g_legDir," entries=",g_legEntries);
   g_legActive=false;
   g_legDir=0;
   g_legEntries=0;
   g_legBars=0;
   g_legPullbackBars=0;
   g_legProtected=0;
   g_legImpulseHigh=0;
   g_legImpulseLow=0;
   g_legStartTime=0;

   g_legStrong=false;
   g_legLastHL=0.0;
   g_legLastLH=0.0;
}

void StartLeg(int dir, double impulseHi, double impulseLo, double protectedLevel)
{
   g_legActive=true;
   g_legDir=dir;
   g_legEntries=0;           // will increment on actual entries (ActivateLeg)
   g_legBars=0;
   g_legPullbackBars=0;
   g_legImpulseHigh=impulseHi;
   g_legImpulseLow=impulseLo;
   g_legProtected=protectedLevel;
   g_legStartTime=TimeCurrent();
   g_legRiskFreeAchieved=false;
   g_legStrong=false;
   g_legLastHL=0.0;
   g_legLastLH=0.0;
   if(InpVerboseLogs) Print("LEG STARTED: dir=",dir," impulse[",DoubleToString(impulseLo,_Digits),",",DoubleToString(impulseHi,_Digits),
                            "] protected=",DoubleToString(protectedLevel,_Digits));
}

// Called when an entry is placed successfully
void ActivateLeg(int dir, double structProtected, double actualSL)
{
   if(!InpEnableLegHarvesting) return;

   // If switching direction, reset leg
   if(!g_legActive || g_legDir!=dir)
   {
      // try to use last closed bar as impulse snapshot
      double ih=iHigh(_Symbol,PERIOD_M1,1);
      double il=iLow(_Symbol,PERIOD_M1,1);
      StartLeg(dir, ih, il, actualSL);
   }

   g_legEntries++;
   // tighten protected to actual SL for safety
   g_legProtected = actualSL;
   if(InpVerboseLogs) Print("LEG ENTRY COUNT: ",g_legEntries," / ",GetMaxEntriesPerLegDynamic()," | strong=", (g_legStrong?"yes":"no"));
}

void UpdateLegStateOnNewBar()
{
   if(!InpEnableLegHarvesting) return;

   // Detect new displacement to start/reset leg state (even if no entry yet)
   bool bullDisp=IsDisplacementBull(1);
   bool bearDisp=IsDisplacementBear(1);

   if(bullDisp && (!g_legActive || g_legDir!=1))
   {
      // Protected level based on structure low; will be replaced by actual SL after first entry
      double prot=LowestN(InpStructLookback, 3);
      StartLeg(1, iHigh(_Symbol,PERIOD_M1,1), iLow(_Symbol,PERIOD_M1,1), prot);
   }
   else if(bearDisp && (!g_legActive || g_legDir!=-1))
   {
      double prot=HighestN(InpStructLookback, 3);
      StartLeg(-1, iHigh(_Symbol,PERIOD_M1,1), iLow(_Symbol,PERIOD_M1,1), prot);
   }

   if(!g_legActive) return;

   g_legBars++;
   // End leg on timeout
   if(g_legBars > InpLegMaxBars) { EndLeg("timeout"); return; }

   // Invalidation: price breaches protected level (abnormal impulse)
   if(g_legDir==1)
   {
      if(iLow(_Symbol,PERIOD_M1,1) <= g_legProtected - 2*_Point) { EndLeg("protected low breached"); return; }
      if(IsDisplacementBear(1)) { EndLeg("opposite displacement"); return; }
   }
   else if(g_legDir==-1)
   {
      if(iHigh(_Symbol,PERIOD_M1,1) >= g_legProtected + 2*_Point) { EndLeg("protected high breached"); return; }
      if(IsDisplacementBull(1)) { EndLeg("opposite displacement"); return; }
   }

   // MSS protection: if structure shifts against the current leg, close ALL profitable positions to avoid donating profits back.
   if(DetectMSSAgainstLeg())
   {
      if(InpVerboseLogs) Print("MSS detected against leg. Closing profitable positions. dir=",g_legDir);
      CloseProfitablePositionsDir(g_legDir);
      EndLeg("MSS against leg");
      return;
   }

   // If leg wasn't classified strong at start, allow upgrade to strong if a strong displacement prints during the leg.
   if(!g_legStrong && IsStrongDisplacement(g_legDir,1))
   {
      g_legStrong=true;
      if(InpVerboseLogs) Print("LEG upgraded to STRONG. MaxEntries=",GetMaxEntriesPerLegDynamic());
   }
}

bool LegReentryBuy(string &why, double &level)
{
   if(!g_legActive || g_legDir!=1) { why="leg not active (buy)"; return false; }
   if(g_legEntries >= GetMaxEntriesPerLegDynamic()) { why="leg entry cap reached"; return false; }
   if(g_legEntries>0 && !g_legRiskFreeAchieved) { why="await risk-free (TP1 hit) before re-entry"; return false; }

   // define pullback window: last N closed bars excluding the trigger bar (we use shift 1 as trigger)
   int N=InpLegPullbackLookback;
   if(N<2) N=2;

   double pullHi=-DBL_MAX, pullLo=DBL_MAX;
   int bears=0;
   for(int s=2; s<2+N; s++)
   {
      pullHi=MathMax(pullHi, iHigh(_Symbol,PERIOD_M1,s));
      pullLo=MathMin(pullLo, iLow(_Symbol,PERIOD_M1,s));
      if(IsBear(s)) bears++;
   }
   if(bears<=0) { why="no pullback (no bearish candles)"; return false; }

   // retrace check vs impulse range
   double impR = g_legImpulseHigh - g_legImpulseLow;
   if(impR<=0) { why="invalid impulse range"; return false; }
   double retr = (g_legImpulseHigh - pullLo) / impR; // how deep pulled back from impulse high
   if(retr > InpLegMaxRetrace) { why="pullback too deep"; return false; }

   
   // Hybrid SL base for re-entry: early entries use fast HL (pullLo), later entries use swing HL
   int nextEntry = g_legEntries + 1; // 1=first entry, 2.. are scale-ins
   double hl = pullLo;
   if(nextEntry >= 4)
   {
      double sw = DetectSwingHL(20);
      if(sw>0) hl = sw;
   }
   level = hl;

   // Protected level must hold
   if(pullLo <= g_legProtected) { why="pullback touched/breached protected"; return false; }


   // Extra discipline: only scale-in if price remains above the last HL (pullback low) by a buffer
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(bid <= level + InpReentryHLBufferPoints*_Point) { why="price not above last HL buffer"; return false; }
   // Trigger: last closed candle (shift1) bullish and closes above pullback high
   if(!IsBull(1)) { why="trigger candle not bullish"; return false; }
   if(iClose(_Symbol,PERIOD_M1,1) <= pullHi) { why="no break of pullback high"; return false; }

   why="LEG REENTRY BUY: OK (HL="+DoubleToString(level,_Digits)+")";
   return true;
}

bool LegReentrySell(string &why, double &level)
{
   if(!g_legActive || g_legDir!=-1) { why="leg not active (sell)"; return false; }
   if(g_legEntries >= GetMaxEntriesPerLegDynamic()) { why="leg entry cap reached"; return false; }

   int N=InpLegPullbackLookback;
   if(g_legEntries>0 && !g_legRiskFreeAchieved) { why="await risk-free (TP1 hit) before re-entry"; return false; }
   if(N<2) N=2;

   double pullHi=-DBL_MAX, pullLo=DBL_MAX;
   int bulls=0;
   for(int s=2; s<2+N; s++)
   {
      pullHi=MathMax(pullHi, iHigh(_Symbol,PERIOD_M1,s));
      pullLo=MathMin(pullLo, iLow(_Symbol,PERIOD_M1,s));
      if(IsBull(s)) bulls++;
   }
   if(bulls<=0) { why="no pullback (no bullish candles)"; return false; }

   double impR = g_legImpulseHigh - g_legImpulseLow;
   if(impR<=0) { why="invalid impulse range"; return false; }
   double retr = (pullHi - g_legImpulseLow) / impR; // how deep pulled back from impulse low
   if(retr > InpLegMaxRetrace) { why="pullback too deep"; return false; }

   if(pullHi >= g_legProtected) { why="pullback touched/breached protected"; return false; }


   // Extra discipline: only scale-in if price remains below the last LH (pullback high) by a buffer
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   if(ask >= level - InpReentryHLBufferPoints*_Point) { why="price not below last LH buffer"; return false; }
   if(!IsBear(1)) { why="trigger candle not bearish"; return false; }
   if(iClose(_Symbol,PERIOD_M1,1) >= pullLo) { why="no break of pullback low"; return false; }

   why="LEG REENTRY SELL: OK (LH="+DoubleToString(level,_Digits)+")";
   return true;
}
bool IsNewBar(datetime &lastTime)
{
   datetime t=iTime(_Symbol,PERIOD_M1,0);
   if(t==0) return false;
   if(t!=lastTime){ lastTime=t; return true; }
   return false;
}

double ATR(int shift=0)
{
   static int h=-1;
   if(h==-1) h=iATR(_Symbol,PERIOD_M1,InpATRPeriod);
   if(h==-1) return 0.0;
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(h,0,shift,1,b)!=1) return 0.0;
   return b[0];
}

double HighestN(int N, int fromShift=1)
{
   double hi=-DBL_MAX;
   for(int i=fromShift;i<fromShift+N;i++) hi=MathMax(hi,iHigh(_Symbol,PERIOD_M1,i));
   return hi;
}
double LowestN(int N, int fromShift=1)
{
   double lo=DBL_MAX;
   for(int i=fromShift;i<fromShift+N;i++) lo=MathMin(lo,iLow(_Symbol,PERIOD_M1,i));
   return lo;
}

double SessionHigh(){ int n=MathMax(50,InpSessionBars); return HighestN(n,0); }
double SessionLow() { int n=MathMax(50,InpSessionBars); return LowestN(n,0);  }

int CountPositions(int dir) // 1 buy, -1 sell
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;
      if(dir== 1 && pos.PositionType()==POSITION_TYPE_BUY)  c++;
      if(dir==-1 && pos.PositionType()==POSITION_TYPE_SELL) c++;
   }
   return c;
}
bool HasOppositePositions(int dir){ return CountPositions(-dir)>0; }

// Candle utils
bool IsBull(int shift){ return iClose(_Symbol,PERIOD_M1,shift) > iOpen(_Symbol,PERIOD_M1,shift); }
bool IsBear(int shift){ return iClose(_Symbol,PERIOD_M1,shift) < iOpen(_Symbol,PERIOD_M1,shift); }

double Body(int shift){ return MathAbs(iClose(_Symbol,PERIOD_M1,shift)-iOpen(_Symbol,PERIOD_M1,shift)); }
double UpperWick(int shift)
{
   double h=iHigh(_Symbol,PERIOD_M1,shift);
   double o=iOpen(_Symbol,PERIOD_M1,shift);
   double c=iClose(_Symbol,PERIOD_M1,shift);
   return h - MathMax(o,c);
}
double LowerWick(int shift)
{
   double l=iLow(_Symbol,PERIOD_M1,shift);
   double o=iOpen(_Symbol,PERIOD_M1,shift);
   double c=iClose(_Symbol,PERIOD_M1,shift);
   return MathMin(o,c) - l;
}

// Engulf definitions (body engulf)
bool BullishEngulf(int engulfShift, int prevShift)
{
   if(!IsBull(engulfShift) || !IsBear(prevShift)) return false;
   double eO=iOpen(_Symbol,PERIOD_M1,engulfShift);
   double eC=iClose(_Symbol,PERIOD_M1,engulfShift);
   double pO=iOpen(_Symbol,PERIOD_M1,prevShift);
   double pC=iClose(_Symbol,PERIOD_M1,prevShift);
   // body engulf: open below prev close AND close above prev open
   return (eO<=pC && eC>=pO);
}
bool BearishEngulf(int engulfShift, int prevShift)
{
   if(!IsBear(engulfShift) || !IsBull(prevShift)) return false;
   double eO=iOpen(_Symbol,PERIOD_M1,engulfShift);
   double eC=iClose(_Symbol,PERIOD_M1,engulfShift);
   double pO=iOpen(_Symbol,PERIOD_M1,prevShift);
   double pC=iClose(_Symbol,PERIOD_M1,prevShift);
   return (eO>=pC && eC<=pO);
}

// Confirmation candle closes beyond engulf wick
bool ConfirmAboveEngulfHigh(int confirmShift, int engulfShift)
{
   double c=iClose(_Symbol,PERIOD_M1,confirmShift);
   double h=iHigh(_Symbol,PERIOD_M1,engulfShift);
   return (c>h);
}
bool ConfirmBelowEngulfLow(int confirmShift, int engulfShift)
{
   double c=iClose(_Symbol,PERIOD_M1,confirmShift);
   double l=iLow(_Symbol,PERIOD_M1,engulfShift);
   return (c<l);
}

// Pattern A: Bearish -> Bullish Engulf -> Confirm close above engulf high
bool PatternA_Buy(string &why, double &protectedLL, double &targetHH)
{
   // We evaluate using CLOSED candles only:
   // [3] bearish push, [2] bullish engulf, [1] confirmation
   int push=3, engulf=2, confirm=1;

   if(InpRequireBearishPushForEngulf && !IsBear(push))
   {
      why="A BUY: no bearish push candle";
      return false;
   }
   if(!BullishEngulf(engulf,push))
   {
      why="A BUY: no bullish engulf";
      return false;
   }
   if(!ConfirmAboveEngulfHigh(confirm,engulf))
   {
      why="A BUY: confirm not above engulf high";
      return false;
   }

   // Structure
   protectedLL = LowestN(InpStructLookback, 3);   // previous structure LL (exclude last 3 candles)
   targetHH    = HighestN(InpStructLookback, 3);  // previous HH
   why="A BUY: OK";
   return true;
}

// Pattern B: Bullish engulf then retrace <=50% + rejection wick
bool PatternB_Buy(string &why, double &protectedLL, double &targetHH)
{
   // [2] bullish engulf of [3], [1] retrace / rejection
   int push=3, engulf=2, pull=1;

   if(InpRequireBearishPushForEngulf && !IsBear(push))
   {
      why="B BUY: no bearish push candle";
      return false;
   }
   if(!BullishEngulf(engulf,push))
   {
      why="B BUY: no bullish engulf";
      return false;
   }

   double eH=iHigh(_Symbol,PERIOD_M1,engulf);
   double eL=iLow(_Symbol,PERIOD_M1,engulf);
   double mid = eL + (eH-eL)*InpRetraceMax; // 50% level

   // retrace <= 50%: low touches at/above mid (doesn't go deeper than allowed)
   double pL=iLow(_Symbol,PERIOD_M1,pull);
   if(pL < mid)
   {
      why="B BUY: retrace deeper than 50%";
      return false;
   }

   // rejection wick: long lower wick relative to body, close bullish or strong close
   double b=Body(pull);
   double lw=LowerWick(pull);
   if(b<=0) b=_Point;
   if(lw < b*InpRejectionWickBody)
   {
      why="B BUY: no rejection wick";
      return false;
   }
   if(iClose(_Symbol,PERIOD_M1,pull) <= iOpen(_Symbol,PERIOD_M1,pull))
   {
      why="B BUY: pullback candle not bullish close";
      return false;
   }

   protectedLL = LowestN(InpStructLookback, 3);
   targetHH    = HighestN(InpStructLookback, 3);
   why="B BUY: OK";
   return true;
}

// SELL mirrors
bool PatternA_Sell(string &why, double &protectedHH, double &targetLL)
{
   int push=3, engulf=2, confirm=1;
   if(InpRequireBearishPushForEngulf && !IsBull(push))
   {
      why="A SELL: no bullish push candle";
      return false;
   }
   if(!BearishEngulf(engulf,push))
   {
      why="A SELL: no bearish engulf";
      return false;
   }
   if(!ConfirmBelowEngulfLow(confirm,engulf))
   {
      why="A SELL: confirm not below engulf low";
      return false;
   }

   protectedHH = HighestN(InpStructLookback, 3);
   targetLL    = LowestN(InpStructLookback, 3);
   why="A SELL: OK";
   return true;
}

bool PatternB_Sell(string &why, double &protectedHH, double &targetLL)
{
   int push=3, engulf=2, pull=1;
   if(InpRequireBearishPushForEngulf && !IsBull(push))
   {
      why="B SELL: no bullish push candle";
      return false;
   }
   if(!BearishEngulf(engulf,push))
   {
      why="B SELL: no bearish engulf";
      return false;
   }

   double eH=iHigh(_Symbol,PERIOD_M1,engulf);
   double eL=iLow(_Symbol,PERIOD_M1,engulf);
   double mid = eH - (eH-eL)*InpRetraceMax; // 50% from top

   double pH=iHigh(_Symbol,PERIOD_M1,pull);
   if(pH > mid)
   {
      why="B SELL: retrace deeper than 50%";
      return false;
   }

   double b=Body(pull);
   double uw=UpperWick(pull);
   if(b<=0) b=_Point;
   if(uw < b*InpRejectionWickBody)
   {
      why="B SELL: no rejection wick";
      return false;
   }
   if(iClose(_Symbol,PERIOD_M1,pull) >= iOpen(_Symbol,PERIOD_M1,pull))
   {
      why="B SELL: pullback candle not bearish close";
      return false;
   }

   protectedHH = HighestN(InpStructLookback, 3);
   targetLL    = LowestN(InpStructLookback, 3);
   why="B SELL: OK";
   return true;
}

//-------------------- Profit / Runner tracking --------------------
bool   g_tp1done[];
double g_peakProfit[];

// ticket helpers
int FindTicketIdx(ulong tk){ for(int i=0;i<ArraySize(g_tickets);i++) if(g_tickets[i]==tk) return i; return -1; }

void TrackOrUpdateTicket(ulong tk, double profitNow)
{
   if(tk==0) return;
   int idx=FindTicketIdx(tk);
   if(idx<0)
   {
      int n=ArraySize(g_tickets);
      ArrayResize(g_tickets,n+1); ArrayResize(g_tp1done,n+1); ArrayResize(g_peakProfit,n+1);
      g_tickets[n]=tk; g_tp1done[n]=false; g_peakProfit[n]=profitNow;
   }
   else
   {
      if(profitNow > g_peakProfit[idx]) g_peakProfit[idx]=profitNow;
   }
}

void UntrackAt(int idx)
{
   int n=ArraySize(g_tickets);
   for(int i=idx;i<n-1;i++){ g_tickets[i]=g_tickets[i+1]; g_tp1done[i]=g_tp1done[i+1]; g_peakProfit[i]=g_peakProfit[i+1]; }
   ArrayResize(g_tickets,n-1); ArrayResize(g_tp1done,n-1); ArrayResize(g_peakProfit,n-1);
}

double MoneyToPriceDelta(double money, double volume)
{
   // Convert money profit target into price delta using tick value/size.
   // priceDelta = money * tick_size / (volume * tick_value)
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0 || ts<=0 || volume<=0) return 0.0;
   return money * ts / (volume * tv);
}

bool MoveSLToLockMoney(const CPositionInfo &p, double lockMoney)
{
   if(lockMoney<=0) return false;

   long type=p.PositionType();
   double entry=p.PriceOpen();
   double vol=p.Volume();
   double delta=MoneyToPriceDelta(lockMoney, vol);
   if(delta<=0) return false;

   double newSL = p.StopLoss();
   if(type==POSITION_TYPE_BUY)
      newSL = entry + delta;
   else
      newSL = entry - delta;

   // Respect current price and broker stop levels
   double curBid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double curAsk=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = MathMax(0.0, stops*_Point);

   if(type==POSITION_TYPE_BUY)
   {
      if(newSL >= curBid - minDist) newSL = curBid - minDist - 2*_Point;
      // only improve SL
      if(p.StopLoss()>0 && newSL <= p.StopLoss()) return false;
   }
   else
   {
      if(newSL <= curAsk + minDist) newSL = curAsk + minDist + 2*_Point;
      if(p.StopLoss()>0 && newSL >= p.StopLoss()) return false;
   }

   if(newSL<=0) return false;
   return trade.PositionModify(p.Ticket(), newSL, p.TakeProfit());
}

void ManageProfitRules()
{
   // Clean tracked tickets that are no longer open
   for(int i=ArraySize(g_tickets)-1;i>=0;i--)
      if(!PositionSelectByTicket(g_tickets[i])) UntrackAt(i);

   // Iterate open positions
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;

      ulong tk=pos.Ticket();
      double profit=pos.Profit(); // includes swap/commission in MT5 position profit display

      TrackOrUpdateTicket(tk, profit);
      int idx=FindTicketIdx(tk);
      if(idx<0) continue;

      // --- TP1 actions ---
      if(!g_tp1done[idx] && profit >= InpTP1Money)
      {
         double vol=pos.Volume();
         double closeVol=vol*(InpTP1ClosePercent/100.0);

         double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         if(step<=0) step=0.01;

         closeVol=MathFloor(closeVol/step)*step;
         closeVol=NormalizeDouble(closeVol,2);

         // Partial close first (bank)
         if(closeVol>=minLot && closeVol<vol)
            trade.PositionClosePartial(tk, closeVol, InpSlippagePoints);

         // Refresh position info after partial
         if(PositionSelectByTicket(tk)) pos.SelectByTicket(tk);

         // Move SL to lock +$5 (risk-free behavior) on remaining
         MoveSLToLockMoney(pos, InpRiskFreeLockMoney);
         // Mark leg as risk-free achieved so harvesting can add entries safely
         if(g_legActive)
         {
            int ptype=(int)PositionGetInteger(POSITION_TYPE);
            int dir = (ptype==POSITION_TYPE_BUY)?1:-1;
            if(dir==g_legDir) g_legRiskFreeAchieved=true;
         }

         // Activate runner mode
         g_tp1done[idx]=true;
         // Reset peak to current profit so drawdown exit uses post-TP1 peak growth
         g_peakProfit[idx]=pos.Profit();
         if(InpVerboseLogs) Print("TP1 HIT: ticket ",tk," | partial ",DoubleToString(InpTP1ClosePercent,1),"% | SL-> +$",DoubleToString(InpRiskFreeLockMoney,2));
      }

      // --- Runner drawdown exit ---
      if(g_tp1done[idx])
      {
         // update peak using latest profit
         double pnow=pos.Profit();
         if(pnow > g_peakProfit[idx]) g_peakProfit[idx]=pnow;

         if(g_peakProfit[idx] >= InpRunnerPeakMinMoney)
         {
            double dd = g_peakProfit[idx] - pnow;
            if(dd >= InpRunnerDrawdownMoney)
            {
               if(InpVerboseLogs) Print("RUNNER EXIT: ticket ",tk," | peak=",DoubleToString(g_peakProfit[idx],2),
                                       " now=",DoubleToString(pnow,2)," dd=",DoubleToString(dd,2));
               trade.PositionClose(tk, InpSlippagePoints);
            }
         }
      }
   }
}

// Trailing: lock 50% after +100 pips
bool TrailingActive(const CPositionInfo &p)
{
   double entry=p.PriceOpen(), sl=p.StopLoss();
   if(p.PositionType()==POSITION_TYPE_BUY)  return (sl>entry);
   if(p.PositionType()==POSITION_TYPE_SELL) return (sl<entry && sl>0);
   return false;
}

void ManageTrailing()
{
   double pip=PipToPrice();
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;

      long type=pos.PositionType();
      double entry=pos.PriceOpen(), sl=pos.StopLoss(), tp=pos.TakeProfit();
      double cur=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double dist=(type==POSITION_TYPE_BUY)?(cur-entry):(entry-cur);
      if(dist<=0) continue;
      if(dist/pip < InpTrailStartPips) continue;

      double lock=MathMax(0.01,InpTrailLockPercent/100.0);
      double newSL=sl;

      if(type==POSITION_TYPE_BUY)
      {
         double cand=entry + dist*lock;
         if(sl==0.0 || cand>sl) newSL=cand;
         if(newSL>=cur) newSL=cur-2*_Point;
      }
      else
      {
         double cand=entry - dist*lock;
         if(sl==0.0 || cand<sl) newSL=cand;
         if(newSL<=cur) newSL=cur+2*_Point;
      }

      if(newSL!=sl && newSL>0) trade.PositionModify(pos.Ticket(),newSL,tp);
   }
}

// Close only on candle-close engulf against position while trailing active
void ManageEngulfClose()
{
   double c1=iClose(_Symbol,PERIOD_M1,1), o1=iOpen(_Symbol,PERIOD_M1,1);
   double h2=iHigh(_Symbol,PERIOD_M1,2), l2=iLow(_Symbol,PERIOD_M1,2);
   bool bear=(c1<l2 && c1<o1);
   bool bull=(c1>h2 && c1>o1);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;
      if(!TrailingActive(pos)) continue;

      if(pos.PositionType()==POSITION_TYPE_BUY && bear) trade.PositionClose(pos.Ticket(),InpSlippagePoints);
      if(pos.PositionType()==POSITION_TYPE_SELL && bull) trade.PositionClose(pos.Ticket(),InpSlippagePoints);
   }
}

//-------------------- Entries --------------------
bool OpenBuy(double sl,double tp2,double structProtected,string &err)
{
   if(HasOppositePositions(1)) { err="buy blocked: opposite positions"; return false; }
   if(CountPositions(1) >= InpMaxStackPerDir){ err="buy blocked: stack limit"; return false; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   double price=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   bool ok=trade.Buy(InpFixedLot,_Symbol,price,sl,tp2,"GoldEAResurrection v4 BUY");
   if(ok){ g_lastTradeTime=TimeCurrent(); ActivateLeg(1, structProtected, sl); }
   else err="buy failed: "+IntegerToString((int)GetLastError());
   return ok;
}
bool OpenSell(double sl,double tp2,double structProtected,string &err)
{
   if(HasOppositePositions(-1)) { err="sell blocked: opposite positions"; return false; }
   if(CountPositions(-1) >= InpMaxStackPerDir){ err="sell blocked: stack limit"; return false; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   double price=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   bool ok=trade.Sell(InpFixedLot,_Symbol,price,sl,tp2,"GoldEAResurrection v4 SELL");
   if(ok){ g_lastTradeTime=TimeCurrent(); ActivateLeg(-1, structProtected, sl); }
   else err="sell failed: "+IntegerToString((int)GetLastError());
   return ok;
}

// HUD (pass by value to avoid reference binding issues with expressions/literals in MQL5)
void HUD(string a,string b,string c){ if(InpShowHUD) Comment(a+"\n"+b+"\n"+c); }

void TryTrade()
{

// --- Safety gates (pause / spread / cooldown) ---
// Keep managing existing positions, but block NEW entries when unsafe.
if(IsPaused() && !CanResumeNow())
{
   string p="PAUSED: "+g_pauseReason+" | resume after "+TimeToString(g_pauseUntil,TIME_SECONDS)+" and "+IntegerToString(InpRecoveryBars)+" normal bars";
   HUD("GoldEAResurrection v4.12 | "+_Symbol, "Trading paused for capital protection", p);
   if(InpVerboseLogs) Print(p);
   return;
}

if(!SpreadOK())
{
   string p="Blocked: spread too wide ("+DoubleToString(SpreadPoints(),1)+" pts > "+IntegerToString(InpMaxSpreadPoints)+")";
   HUD("GoldEAResurrection v4.12 | "+_Symbol, "Spread filter active", p);
   if(InpVerboseLogs) Print(p);
   return;
}

if(g_lastTradeTime>0 && (TimeCurrent()-g_lastTradeTime) < InpTradeCooldownSeconds)
{
   int left = (int)(InpTradeCooldownSeconds - (TimeCurrent()-g_lastTradeTime));
   string p="Blocked: cooldown active ("+IntegerToString(left)+"s remaining)";
   HUD("GoldEAResurrection v4.12 | "+_Symbol, "Cooldown filter active", p);
   if(InpVerboseLogs) Print(p);
   return;
}
   string whyB="", whyS="", act="No trade";
   double protLL=0, targHH=0;
   double protHH=0, targLL=0;

   bool sigBuy=false, sigSell=false;

   // Prefer A then B (faster continuation confirmation), both are "immediate entry after engulf family"
   if(PatternA_Buy(whyB,protLL,targHH)) sigBuy=true;
   else if(PatternB_Buy(whyB,protLL,targHH)) sigBuy=true;

   if(PatternA_Sell(whyS,protHH,targLL)) sigSell=true;
   else if(PatternB_Sell(whyS,protHH,targLL)) sigSell=true;

   // Leg harvesting: allow additional entries during an active expansion leg
   if(InpEnableLegHarvesting && !sigBuy && !sigSell)
   {
      string lw=""; double lvl=0.0;
      if(LegReentryBuy(lw,lvl))
      { 
         sigBuy=true; whyB=lw; 
         // Re-entry SL base = engineered HL (hybrid). Store for MSS protection.
         protLL=lvl; g_legLastHL=lvl;
         targHH=HighestN(InpStructLookback, 3); 
      }
      else if(LegReentrySell(lw,lvl))
      { 
         sigSell=true; whyS=lw; 
         protHH=lvl; g_legLastLH=lvl;
         targLL=LowestN(InpStructLookback, 3); 
      }
   }

double buf=ATR(0)*InpSLBufferATRMult;

   // Compute stops/targets (structure based)
   double slB=protLL - buf;
   double tp2B=SessionHigh();

   // TP1 is the structural target returned by the pattern logic (previous HH/LL)
   double tp1B=targHH;

   double slS=protHH + buf;
   double tp2S=SessionLow();

   double tp1S=targLL;

   string err="";

   if(sigBuy)
   {
      act="BUY signal: "+whyB;
      // Sanity: TP1 above entry, SL below entry
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(tp1B<=entry) act+=" | blocked: TP1<=entry";
      else if(slB>=entry) act+=" | blocked: SL>=entry";
      else OpenBuy(slB,tp2B,protLL,err);
      if(err!="") act+=" | "+err;
   }
   else if(sigSell)
   {
      act="SELL signal: "+whyS;
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(tp1S>=entry) act+=" | blocked: TP1>=entry";
      else if(slS<=entry) act+=" | blocked: SL<=entry";
      else OpenSell(slS,tp2S,protHH,err);
      if(err!="") act+=" | "+err;
   }
   else
   {
      act="No trade: "+(whyB!=""?whyB:whyS);
   }

   string l1="GoldEAResurrection v4.12 | "+_Symbol+" | BUY:"+IntegerToString(CountPositions(1))+" SELL:"+IntegerToString(CountPositions(-1));
   string l2="Patterns: A=Engulf+Confirm, B=Engulf+50%+Rejection | StackMax="+IntegerToString(InpMaxStackPerDir)+" | Lot="+DoubleToString(InpFixedLot,2);
   string l3=act;

   HUD(l1,l2,l3);
   if(InpVerboseLogs) Print(l3);
}


// Pause trading after a stop-loss event (freak accident / capital protection)
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal=trans.deal;
   if(deal==0) return;

   if(!HistoryDealSelect(deal)) return;
   string sym=HistoryDealGetString(deal,DEAL_SYMBOL);
   if(sym!=_Symbol) return;

   long magic=HistoryDealGetInteger(deal,DEAL_MAGIC);
   if((ulong)magic!=InpMagic) return;

   long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_OUT) return;

   long reason=HistoryDealGetInteger(deal,DEAL_REASON);
   if(reason==DEAL_REASON_SL)
   {
      StartPause(InpPauseMinutesAfterSL, "Stop-loss event detected (possible news spike / abnormal impulse).");
   }
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   if(InpShowHUD) Comment("GoldEAResurrection v4.13 loaded. XAUUSD M1. MicroV + Safety + ProfitRunner + LegHarvesting + RiskFreeGate.");
   return INIT_SUCCEEDED;
}

void OnTick()
{

// Always manage existing positions (even during pause)
ManageTrailing();
ManageProfitRules();

bool nb=IsNewBar(g_lastBarTime);
if(nb)
{
   // Update abnormal/pause detector using the last closed bar
   UpdatePauseStateOnNewBar();
   UpdateLegStateOnNewBar();

   // Manage exit logic that depends on closed candles
   ManageEngulfClose();
}

// Only evaluate entries on new bar
if(!nb) return;

// If paused, do not open new trades
if(IsPaused() && !CanResumeNow()) return;

TryTrade();
}
//+------------------------------------------------------------------+


