//+------------------------------------------------------------------+
//|                    GoldEAResurrection.mq5                          |
//|  M1 Structure Scalper (micro structure + sweep rule)               |
//|                                                                    |
//|  Core Entries:                                                     |
//|   Rule A: Micro MSS -> HH/LL -> HL/LH -> Entry                     |
//|   Rule B: Liquidity sweep -> reclaim -> micro MSS -> Entry         |
//|                                                                    |
//|  Exits:                                                           |
//|   - TP1: partial close (default 75%) at prior HH/LL                |
//|   - TP2: session High/Low (runner)                                 |
//|   - Trailing: once +100 pips, move SL to 50% trailing hard stop    |
//|   - Manual close signal while trailing ON:                          |
//|        * BUY: a CLOSED M1 candle closes below previous candle LOW  |
//|        * SELL: a CLOSED M1 candle closes above previous candle HIGH|
//|     (Wicks alone do NOT close; trailing remains.)                  |
//|                                                                    |
//|  SL at entry: protected swing LL/HH + small buffer (ATR-based)     |
//|  Lot: fixed (default 0.10)                                         |
//|  Stacking: up to 3 entries per direction, no hedging               |
//+------------------------------------------------------------------+
#property version   "9.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;

//-------------------- Inputs --------------------
input ulong  InpMagic              = 26032026;
input double InpFixedLot           = 0.10;

input int    InpATRPeriod          = 14;
input double InpSLBufferATRMult    = 0.15;   // "small buffer" for protected LL/HH
input double InpTrailBufferATRMult = 0.00;   // optional extra buffer on trailing SL (0 = none)

input int    InpFractalDepth       = 2;
input int    InpSwingLookbackBars  = 800;

input int    InpMaxStackPerDir     = 3;

input double InpTP1ClosePercent    = 75.0;
input int    InpSessionBars        = 300;    // ~5 hours

// Trailing rules
input int    InpTrailStartPips     = 100;    // start trailing after +100 pips
input double InpTrailLockPercent   = 50.0;   // lock 50% of current profit distance

// Liquidity sweep rule B
input bool   InpUseLiquiditySweep  = true;
input int    InpSweepLookbackBars  = 20;
input int    InpSweepValidBars     = 3;
input double InpSweepMinWickATR    = 0.05;

// Enable rules
input bool   InpUseRuleA           = true;
input bool   InpUseRuleB           = true;

//-------------------- State --------------------
datetime g_lastBarTime = 0;

// Rule A state (micro structure sequence)
datetime g_bullMSSTime = 0;
datetime g_bearMSSTime = 0;

double   g_lastBullHL  = 0.0;
datetime g_lastBullHLTime = 0;

double   g_lastBearLH  = 0.0;
datetime g_lastBearLHTime = 0;

// Track TP1 per position ticket
ulong    g_tickets[];
double   g_tp1prices[];
bool     g_tp1active[];

//-------------------- Helpers --------------------
double PipValuePoint()
{
   // If broker uses 5/3 digits, 1 pip = 10 points. Else 1 pip = 1 point.
   if(_Digits==3 || _Digits==5) return 10.0*_Point;
   return _Point;
}

bool IsNewBar(datetime &lastTime)
{
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t == 0) return false;
   if(t != lastTime){ lastTime = t; return true; }
   return false;
}

double ATRValue(int shift)
{
   static int hATR=-1;
   if(hATR==-1) hATR = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   if(hATR==-1) return 0.0;
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(hATR, 0, shift, 1, b) != 1) return 0.0;
   return b[0];
}

int FractalHandle()
{
   static int hF=-1;
   if(hF==-1) hF = iFractals(_Symbol, PERIOD_M1);
   return hF;
}

// Get last confirmed fractal high/low
bool LastFractal(bool highs, int &idx, double &price, datetime &bt)
{
   idx=-1; price=0; bt=0;
   int h = FractalHandle();
   if(h==-1) return false;

   int buf = highs ? 0 : 1;
   double data[]; ArraySetAsSeries(data,true);
   int copied = CopyBuffer(h, buf, 0, InpSwingLookbackBars, data);
   if(copied <= 0) return false;

   for(int i=InpFractalDepth+2; i<copied; i++)
   {
      if(data[i] != 0.0)
      {
         idx=i; price=data[i]; bt=iTime(_Symbol, PERIOD_M1, i);
         return (bt!=0);
      }
   }
   return false;
}

// Get last TWO confirmed fractals
bool LastTwoFractals(bool highs, int &idx1, double &p1, datetime &t1, int &idx2, double &p2, datetime &t2)
{
   idx1=idx2=-1; p1=p2=0; t1=t2=0;
   int h = FractalHandle();
   if(h==-1) return false;

   int buf = highs ? 0 : 1;
   double data[]; ArraySetAsSeries(data,true);
   int copied = CopyBuffer(h, buf, 0, InpSwingLookbackBars, data);
   if(copied <= 0) return false;

   int found=0;
   for(int i=InpFractalDepth+2; i<copied; i++)
   {
      if(data[i] != 0.0)
      {
         if(found==0)
         {
            idx1=i; p1=data[i]; t1=iTime(_Symbol, PERIOD_M1, i); found=1;
         }
         else
         {
            idx2=i; p2=data[i]; t2=iTime(_Symbol, PERIOD_M1, i); found=2;
            break;
         }
      }
   }
   return (found==2 && t1!=0 && t2!=0);
}

// Micro MSS: break last swing high/low
int MicroMSS()
{
   int ih; double sh; datetime th;
   int il; double sl; datetime tl;
   if(!LastFractal(true, ih, sh, th)) return 0;
   if(!LastFractal(false, il, sl, tl)) return 0;

   double c0=iClose(_Symbol, PERIOD_M1, 0);
   double c1=iClose(_Symbol, PERIOD_M1, 1);

   if(c1 <= sh && c0 > sh) return 1;
   if(c1 >= sl && c0 < sl) return -1;
   return 0;
}

// Session high/low over last N M1 bars
double SessionHigh()
{
   double hi=-DBL_MAX;
   int n=MathMax(50, InpSessionBars);
   for(int i=0;i<n;i++) hi=MathMax(hi, iHigh(_Symbol, PERIOD_M1, i));
   return hi;
}
double SessionLow()
{
   double lo=DBL_MAX;
   int n=MathMax(50, InpSessionBars);
   for(int i=0;i<n;i++) lo=MathMin(lo, iLow(_Symbol, PERIOD_M1, i));
   return lo;
}

// Count open positions for this EA by direction
int CountPositions(int dir /*1 buy, -1 sell*/)
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;

      long type=pos.PositionType();
      if(dir==1 && type==POSITION_TYPE_BUY) count++;
      if(dir==-1 && type==POSITION_TYPE_SELL) count++;
   }
   return count;
}

bool HasOppositePositions(int dir)
{
   return (CountPositions(-dir) > 0);
}

// Track TP1 mapping
int FindTicketIdx(ulong ticket)
{
   int n=ArraySize(g_tickets);
   for(int i=0;i<n;i++) if(g_tickets[i]==ticket) return i;
   return -1;
}
void TrackTicket(ulong ticket, double tp1)
{
   if(ticket==0) return;
   int idx=FindTicketIdx(ticket);
   if(idx>=0) return;

   int n=ArraySize(g_tickets);
   ArrayResize(g_tickets,n+1);
   ArrayResize(g_tp1prices,n+1);
   ArrayResize(g_tp1active,n+1);

   g_tickets[n]=ticket;
   g_tp1prices[n]=tp1;
   g_tp1active[n]=true;
}
void UntrackTicketAt(int idx)
{
   int n=ArraySize(g_tickets);
   if(idx<0 || idx>=n) return;
   for(int i=idx;i<n-1;i++)
   {
      g_tickets[i]=g_tickets[i+1];
      g_tp1prices[i]=g_tp1prices[i+1];
      g_tp1active[i]=g_tp1active[i+1];
   }
   ArrayResize(g_tickets,n-1);
   ArrayResize(g_tp1prices,n-1);
   ArrayResize(g_tp1active,n-1);
}

//-------------------- Exit management --------------------
void ManageTP1()
{
   // Remove stale tickets (closed positions)
   for(int i=ArraySize(g_tickets)-1;i>=0;i--)
   {
      ulong tk=g_tickets[i];
      if(!PositionSelectByTicket(tk))
      {
         UntrackTicketAt(i);
         continue;
      }
   }

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;

      ulong ticket=pos.Ticket();
      int idx=FindTicketIdx(ticket);
      if(idx<0) continue;
      if(!g_tp1active[idx]) continue;

      long type=pos.PositionType();
      double price=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      bool hit=(type==POSITION_TYPE_BUY)?(price>=g_tp1prices[idx]):(price<=g_tp1prices[idx]);
      if(!hit) continue;

      double vol=pos.Volume();
      double closeVol=vol*(InpTP1ClosePercent/100.0);

      double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
      if(step<=0) step=0.01;

      closeVol = MathFloor(closeVol/step)*step;
      closeVol = NormalizeDouble(closeVol, 2);

      if(closeVol>=minLot && closeVol < vol)
         trade.PositionClosePartial(ticket, closeVol, 30);

      g_tp1active[idx]=false;
   }
}

// Trailing: once profit >= 100 pips, SL becomes 50% trailing hard stop
void ManageTrailingStops()
{
   double pip = PipValuePoint();
   double atr0 = ATRValue(0);
   double trailBuf = (atr0>0 ? InpTrailBufferATRMult*atr0 : 0.0);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;

      long type=pos.PositionType();
      double entry=pos.PriceOpen();
      double sl=pos.StopLoss();
      double tp=pos.TakeProfit();

      double cur = (type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double dist = (type==POSITION_TYPE_BUY)?(cur-entry):(entry-cur); // profit distance in price
      if(dist <= 0) continue;

      double distPips = dist / pip;
      if(distPips < InpTrailStartPips) continue;

      double lock = InpTrailLockPercent/100.0;
      if(lock <= 0) lock = 0.5;

      double newSL = sl;
      if(type==POSITION_TYPE_BUY)
      {
         double candidate = entry + dist*lock - trailBuf;
         if(sl==0.0 || candidate > sl) newSL = candidate;
         // don't set SL above current bid
         if(newSL >= cur) newSL = cur - 2*_Point;
      }
      else
      {
         double candidate = entry - dist*lock + trailBuf;
         if(sl==0.0 || candidate < sl) newSL = candidate;
         if(newSL <= cur) newSL = cur + 2*_Point;
      }

      if(newSL != sl && newSL > 0)
         trade.PositionModify(pos.Ticket(), newSL, tp);
   }
}

// Close signal ONLY when trailing is active:
// BUY: candle[1] closes below candle[2] low (engulf-like)
// SELL: candle[1] closes above candle[2] high
void ManageCloseOnEngulfWhileTrailing()
{
   // Use closed candles: shift 1 and shift 2
   double c1=iClose(_Symbol, PERIOD_M1, 1);
   double o1=iOpen(_Symbol,  PERIOD_M1, 1);
   double l2=iLow(_Symbol,   PERIOD_M1, 2);
   double h2=iHigh(_Symbol,  PERIOD_M1, 2);

   bool bearEngulf = (c1 < l2) && (c1 < o1); // close below prev low AND bearish body
   bool bullEngulf = (c1 > h2) && (c1 > o1); // close above prev high AND bullish body

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;

      long type=pos.PositionType();
      double entry=pos.PriceOpen();
      double sl=pos.StopLoss();

      bool trailingActive=false;
      if(type==POSITION_TYPE_BUY) trailingActive = (sl > entry);
      if(type==POSITION_TYPE_SELL) trailingActive = (sl < entry && sl>0);

      if(!trailingActive) continue;

      if(type==POSITION_TYPE_BUY && bearEngulf)
         trade.PositionClose(pos.Ticket(), 30);

      if(type==POSITION_TYPE_SELL && bullEngulf)
         trade.PositionClose(pos.Ticket(), 30);
   }
}

// Runner exit on opposite MSS (only if trailing is NOT active?)
void ManageRunnerExit()
{
   int mss = MicroMSS();
   if(mss==0) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;

      long type=pos.PositionType();
      double entry=pos.PriceOpen();
      double sl=pos.StopLoss();

      bool trailingActive=false;
      if(type==POSITION_TYPE_BUY) trailingActive = (sl > entry);
      if(type==POSITION_TYPE_SELL) trailingActive = (sl < entry && sl>0);

      // While trailing is ON, do not close on MSS (only close on engulf rule)
      if(trailingActive) continue;

      if(type==POSITION_TYPE_BUY && mss==-1)
         trade.PositionClose(pos.Ticket(), 30);
      if(type==POSITION_TYPE_SELL && mss==1)
         trade.PositionClose(pos.Ticket(), 30);
   }
}

//-------------------- Entry Rule A --------------------
bool RuleA_Buy(double &entry, double &sl, double &tp1, double &tp2)
{
   int mss = MicroMSS();
   if(mss==1) g_bullMSSTime = iTime(_Symbol, PERIOD_M1, 0);
   if(g_bullMSSTime==0) return false;

   // Latest confirmed fractal low AFTER MSS time => HL
   int il1,il2; double pl1,pl2; datetime tl1,tl2;
   if(!LastTwoFractals(false, il1, pl1, tl1, il2, pl2, tl2)) return false;

   if(tl1 > g_bullMSSTime && tl1 != g_lastBullHLTime)
   {
      g_lastBullHL = pl1;
      g_lastBullHLTime = tl1;
   }
   if(g_lastBullHLTime==0) return false;

   // Confirmation: close breaks above previous bar high (shift 1)
   double c0=iClose(_Symbol, PERIOD_M1, 0);
   double ph=iHigh(_Symbol, PERIOD_M1, 1);
   if(c0 <= ph) return false;

   // TP1 = most recent swing high
   int ih1,ih2; double ph1,ph2; datetime th1,th2;
   if(!LastTwoFractals(true, ih1, ph1, th1, ih2, ph2, th2)) return false;

   double atr=ATRValue(0);
   double buf=(atr>0? atr*InpSLBufferATRMult : 0.0);

   entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   sl    = g_lastBullHL - buf;
   tp1   = ph1;
   tp2   = SessionHigh();

   if(tp1 <= entry) return false;
   if(entry <= sl) return false;
   return true;
}

bool RuleA_Sell(double &entry, double &sl, double &tp1, double &tp2)
{
   int mss = MicroMSS();
   if(mss==-1) g_bearMSSTime = iTime(_Symbol, PERIOD_M1, 0);
   if(g_bearMSSTime==0) return false;

   // Latest confirmed fractal high AFTER MSS time => LH
   int ih1,ih2; double ph1,ph2; datetime th1,th2;
   if(!LastTwoFractals(true, ih1, ph1, th1, ih2, ph2, th2)) return false;

   if(th1 > g_bearMSSTime && th1 != g_lastBearLHTime)
   {
      g_lastBearLH = ph1;
      g_lastBearLHTime = th1;
   }
   if(g_lastBearLHTime==0) return false;

   // Confirmation: close breaks below previous bar low (shift 1)
   double c0=iClose(_Symbol, PERIOD_M1, 0);
   double pl=iLow(_Symbol, PERIOD_M1, 1);
   if(c0 >= pl) return false;

   // TP1 = most recent swing low
   int il1,il2; double pl1,pl2; datetime tl1,tl2;
   if(!LastTwoFractals(false, il1, pl1, tl1, il2, pl2, tl2)) return false;

   double atr=ATRValue(0);
   double buf=(atr>0? atr*InpSLBufferATRMult : 0.0);

   entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   sl    = g_lastBearLH + buf;
   tp1   = pl1;
   tp2   = SessionLow();

   if(tp1 >= entry) return false;
   if(entry >= sl) return false;
   return true;
}

//-------------------- Entry Rule B (Sweep -> Reclaim -> Micro MSS) --------------------
bool RuleB_Buy(double &entry, double &sl, double &tp1, double &tp2)
{
   if(!InpUseLiquiditySweep) return false;

   bool swept=false;
   double sweptLevel=0;

   for(int s=0; s<InpSweepValidBars; s++)
   {
      int N=MathMax(5, InpSweepLookbackBars);
      double priorLow=DBL_MAX;
      for(int i=s+1;i<=s+N;i++) priorLow = MathMin(priorLow, iLow(_Symbol, PERIOD_M1, i));

      double ls=iLow(_Symbol, PERIOD_M1, s);
      double cs=iClose(_Symbol, PERIOD_M1, s);
      double os=iOpen(_Symbol, PERIOD_M1, s);

      if(ls < priorLow && cs > priorLow)
      {
         double atr=ATRValue(s);
         double minW=(atr>0? InpSweepMinWickATR*atr : 0);
         double wick = MathMin(os,cs) - ls;
         if(minW<=0 || wick >= minW)
         {
            swept=true;
            sweptLevel=priorLow;
            break;
         }
      }
   }
   if(!swept) return false;

   // Reclaim
   double c0=iClose(_Symbol, PERIOD_M1, 0);
   if(c0 <= sweptLevel) return false;

   // Micro MSS
   if(MicroMSS() != 1) return false;

   // SL at protected swing low + small buffer; TP1 at swing high
   int il; double swLow; datetime tl;
   int ih; double swHigh; datetime th;
   if(!LastFractal(false, il, swLow, tl)) return false;
   if(!LastFractal(true,  ih, swHigh, th)) return false;

   double atr=ATRValue(0);
   double buf=(atr>0? atr*InpSLBufferATRMult : 0.0);

   entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   sl    = swLow - buf;
   tp1   = swHigh;
   tp2   = SessionHigh();

   if(tp1 <= entry) return false;
   if(entry <= sl) return false;
   return true;
}

bool RuleB_Sell(double &entry, double &sl, double &tp1, double &tp2)
{
   if(!InpUseLiquiditySweep) return false;

   bool swept=false;
   double sweptLevel=0;

   for(int s=0; s<InpSweepValidBars; s++)
   {
      int N=MathMax(5, InpSweepLookbackBars);
      double priorHigh=-DBL_MAX;
      for(int i=s+1;i<=s+N;i++) priorHigh = MathMax(priorHigh, iHigh(_Symbol, PERIOD_M1, i));

      double hs=iHigh(_Symbol, PERIOD_M1, s);
      double cs=iClose(_Symbol, PERIOD_M1, s);
      double os=iOpen(_Symbol, PERIOD_M1, s);

      if(hs > priorHigh && cs < priorHigh)
      {
         double atr=ATRValue(s);
         double minW=(atr>0? InpSweepMinWickATR*atr : 0);
         double wick = hs - MathMax(os,cs);
         if(minW<=0 || wick >= minW)
         {
            swept=true;
            sweptLevel=priorHigh;
            break;
         }
      }
   }
   if(!swept) return false;

   // Reclaim
   double c0=iClose(_Symbol, PERIOD_M1, 0);
   if(c0 >= sweptLevel) return false;

   // Micro MSS
   if(MicroMSS() != -1) return false;

   int ih; double swHigh; datetime th;
   int il; double swLow;  datetime tl;
   if(!LastFractal(true, ih, swHigh, th)) return false;
   if(!LastFractal(false, il, swLow,  tl)) return false;

   double atr=ATRValue(0);
   double buf=(atr>0? atr*InpSLBufferATRMult : 0.0);

   entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   sl    = swHigh + buf;
   tp1   = swLow;
   tp2   = SessionLow();

   if(tp1 >= entry) return false;
   if(entry >= sl) return false;
   return true;
}

//-------------------- Trade open (stacking) --------------------
void TrackNewestTicket(int dir, double tp1)
{
   ulong newest=0;
   datetime newestTime=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;

      long type=pos.PositionType();
      if(dir==1 && type!=POSITION_TYPE_BUY) continue;
      if(dir==-1 && type!=POSITION_TYPE_SELL) continue;

      datetime ot=(datetime)pos.Time();
      if(ot >= newestTime){ newestTime=ot; newest=pos.Ticket(); }
   }

   TrackTicket(newest, tp1);
}

bool OpenBuy(double entry, double sl, double tp2, double tp1)
{
   if(HasOppositePositions(1)) return false;
   if(CountPositions(1) >= InpMaxStackPerDir) return false;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);

   bool ok = trade.Buy(InpFixedLot, _Symbol, entry, sl, tp2, "GoldEAResurrection BUY");
   if(ok) TrackNewestTicket(1, tp1);
   return ok;
}

bool OpenSell(double entry, double sl, double tp2, double tp1)
{
   if(HasOppositePositions(-1)) return false;
   if(CountPositions(-1) >= InpMaxStackPerDir) return false;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);

   bool ok = trade.Sell(InpFixedLot, _Symbol, entry, sl, tp2, "GoldEAResurrection SELL");
   if(ok) TrackNewestTicket(-1, tp1);
   return ok;
}

//-------------------- Main trading loop --------------------
void TryTrade()
{
   double entry, sl, tp1, tp2;

   // BUY (Rule A first, then Rule B)
   bool buySignal=false;
   if(InpUseRuleA && RuleA_Buy(entry, sl, tp1, tp2)) buySignal=true;
   else if(InpUseRuleB && RuleB_Buy(entry, sl, tp1, tp2)) buySignal=true;

   if(buySignal) OpenBuy(entry, sl, tp2, tp1);

   // SELL
   bool sellSignal=false;
   if(InpUseRuleA && RuleA_Sell(entry, sl, tp1, tp2)) sellSignal=true;
   else if(InpUseRuleB && RuleB_Sell(entry, sl, tp1, tp2)) sellSignal=true;

   if(sellSignal) OpenSell(entry, sl, tp2, tp1);
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   // Always manage trailing on ticks
   ManageTrailingStops();

   // TP1 and runner exit
   ManageTP1();
   ManageRunnerExit();

   // Only evaluate engulf-close on bar close
   bool nb = IsNewBar(g_lastBarTime);
   if(nb) ManageCloseOnEngulfWhileTrailing();

   if(!nb) return;
   TryTrade();
}
//+------------------------------------------------------------------+
