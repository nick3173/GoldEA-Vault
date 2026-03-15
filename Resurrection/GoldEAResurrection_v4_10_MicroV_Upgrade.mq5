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
#property version "4.10"

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
input double  InpTP1ClosePercent   = 75.0;

input int     InpSlippagePoints    = 30;



// Execution / safety filters
input int     InpTradeCooldownSeconds   = 60;   // minimum seconds between new entries (normal cooldown)
input int     InpMaxSpreadPoints        = 80;   // max allowed spread in POINTS (Gold often 20-60; tune per broker)

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

// TP1 tracking
ulong  g_tickets[];
double g_tp1prices[];
bool   g_tp1active[];

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

//-------------------- TP1 tracking --------------------
int FindTicketIdx(ulong tk){ for(int i=0;i<ArraySize(g_tickets);i++) if(g_tickets[i]==tk) return i; return -1; }
void TrackTicket(ulong tk, double tp1)
{
   if(tk==0) return;
   if(FindTicketIdx(tk)>=0) return;
   int n=ArraySize(g_tickets);
   ArrayResize(g_tickets,n+1); ArrayResize(g_tp1prices,n+1); ArrayResize(g_tp1active,n+1);
   g_tickets[n]=tk; g_tp1prices[n]=tp1; g_tp1active[n]=true;
}
void UntrackAt(int idx)
{
   int n=ArraySize(g_tickets);
   for(int i=idx;i<n-1;i++){ g_tickets[i]=g_tickets[i+1]; g_tp1prices[i]=g_tp1prices[i+1]; g_tp1active[i]=g_tp1active[i+1]; }
   ArrayResize(g_tickets,n-1); ArrayResize(g_tp1prices,n-1); ArrayResize(g_tp1active,n-1);
}

void TrackNewestTicket(int dir,double tp1)
{
   ulong newest=0; datetime nt=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;
      if(dir==1 && pos.PositionType()!=POSITION_TYPE_BUY) continue;
      if(dir==-1 && pos.PositionType()!=POSITION_TYPE_SELL) continue;
      datetime t=(datetime)pos.Time();
      if(t>=nt){ nt=t; newest=pos.Ticket(); }
   }
   TrackTicket(newest,tp1);
}

void ManageTP1()
{
   for(int i=ArraySize(g_tickets)-1;i>=0;i--) if(!PositionSelectByTicket(g_tickets[i])) UntrackAt(i);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;

      int idx=FindTicketIdx(pos.Ticket());
      if(idx<0 || !g_tp1active[idx]) continue;

      long type=pos.PositionType();
      double cur=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      bool hit=(type==POSITION_TYPE_BUY)?(cur>=g_tp1prices[idx]):(cur<=g_tp1prices[idx]);
      if(!hit) continue;

      double vol=pos.Volume();
      double closeVol=vol*(InpTP1ClosePercent/100.0);

      double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
      if(step<=0) step=0.01;
      closeVol=MathFloor(closeVol/step)*step;
      closeVol=NormalizeDouble(closeVol,2);

      if(closeVol>=minLot && closeVol<vol) trade.PositionClosePartial(pos.Ticket(),closeVol,InpSlippagePoints);
      g_tp1active[idx]=false;
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
bool OpenBuy(double sl,double tp2,double tp1,string &err)
{
   if(HasOppositePositions(1)) { err="buy blocked: opposite positions"; return false; }
   if(CountPositions(1) >= InpMaxStackPerDir){ err="buy blocked: stack limit"; return false; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   double price=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   bool ok=trade.Buy(InpFixedLot,_Symbol,price,sl,tp2,"GoldEAResurrection v4 BUY");
   if(ok){ TrackNewestTicket(1,tp1); g_lastTradeTime=TimeCurrent(); }
   else err="buy failed: "+IntegerToString((int)GetLastError());
   return ok;
}
bool OpenSell(double sl,double tp2,double tp1,string &err)
{
   if(HasOppositePositions(-1)) { err="sell blocked: opposite positions"; return false; }
   if(CountPositions(-1) >= InpMaxStackPerDir){ err="sell blocked: stack limit"; return false; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   double price=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   bool ok=trade.Sell(InpFixedLot,_Symbol,price,sl,tp2,"GoldEAResurrection v4 SELL");
   if(ok){ TrackNewestTicket(-1,tp1); g_lastTradeTime=TimeCurrent(); }
   else err="sell failed: "+IntegerToString((int)GetLastError());
   return ok;
}

// HUD
void HUD(const string &a,const string &b,const string &c){ if(InpShowHUD) Comment(a+"\n"+b+"\n"+c); }

void TryTrade()
{

// --- Safety gates (pause / spread / cooldown) ---
// Keep managing existing positions, but block NEW entries when unsafe.
if(IsPaused() && !CanResumeNow())
{
   string p="PAUSED: "+g_pauseReason+" | resume after "+TimeToString(g_pauseUntil,TIME_SECONDS)+" and "+IntegerToString(InpRecoveryBars)+" normal bars";
   HUD("GoldEAResurrection v4.10 | "+_Symbol, "Trading paused for capital protection", p);
   if(InpVerboseLogs) Print(p);
   return;
}

if(!SpreadOK())
{
   string p="Blocked: spread too wide ("+DoubleToString(SpreadPoints(),1)+" pts > "+IntegerToString(InpMaxSpreadPoints)+")";
   HUD("GoldEAResurrection v4.10 | "+_Symbol, "Spread filter active", p);
   if(InpVerboseLogs) Print(p);
   return;
}

if(g_lastTradeTime>0 && (TimeCurrent()-g_lastTradeTime) < InpTradeCooldownSeconds)
{
   int left = (int)(InpTradeCooldownSeconds - (TimeCurrent()-g_lastTradeTime));
   string p="Blocked: cooldown active ("+IntegerToString(left)+"s remaining)";
   HUD("GoldEAResurrection v4.10 | "+_Symbol, "Cooldown filter active", p);
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

   double buf=ATR(0)*InpSLBufferATRMult;

   // Compute stops/targets (structure based)
   double slB=protLL - buf;
   double tp1B=targHH;
   double tp2B=SessionHigh();

   double slS=protHH + buf;
   double tp1S=targLL;
   double tp2S=SessionLow();

   string err="";

   if(sigBuy)
   {
      act="BUY signal: "+whyB;
      // Sanity: TP1 above entry, SL below entry
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(tp1B<=entry) act+=" | blocked: TP1<=entry";
      else if(slB>=entry) act+=" | blocked: SL>=entry";
      else OpenBuy(slB,tp2B,tp1B,err);
      if(err!="") act+=" | "+err;
   }
   else if(sigSell)
   {
      act="SELL signal: "+whyS;
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(tp1S>=entry) act+=" | blocked: TP1>=entry";
      else if(slS<=entry) act+=" | blocked: SL<=entry";
      else OpenSell(slS,tp2S,tp1S,err);
      if(err!="") act+=" | "+err;
   }
   else
   {
      act="No trade: "+(whyB!=""?whyB:whyS);
   }

   string l1="GoldEAResurrection v4.10 | "+_Symbol+" | BUY:"+IntegerToString(CountPositions(1))+" SELL:"+IntegerToString(CountPositions(-1));
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
   if(InpShowHUD) Comment("GoldEAResurrection v4 loaded. Attach to XAUUSD M1. Patterns A/B enabled.");
   return INIT_SUCCEEDED;
}

void OnTick()
{

// Always manage existing positions (even during pause)
ManageTrailing();
ManageTP1();

bool nb=IsNewBar(g_lastBarTime);
if(nb)
{
   // Update abnormal/pause detector using the last closed bar
   UpdatePauseStateOnNewBar();

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
