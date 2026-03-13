//+------------------------------------------------------------------+
//|     Gold_Autobot_v8_MicroStructure_3Stack.mq5                      |
//|  M1 scalper with TRUE micro structure engine (fractals)            |
//|  - Structure: MSS (break last swing) -> HH/LL -> HL/LH entry       |
//|  - Rule B: Liquidity sweep -> reclaim -> micro MSS -> entry        |
//|  - Exits: TP1 partial (75%) at prior HH/LL, TP2 at session H/L     |
//|  - SL: structure LL/HH + ATR buffer                               |
//|  - Fixed lot default 0.10                                          |
//|  - Allows up to 3 stacked trades in SAME direction (no hedge)      |
//+------------------------------------------------------------------+
#property version   "8.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;

//-------------------- Inputs --------------------
input ulong  InpMagic              = 26032026;
input double InpFixedLot           = 0.10;

input int    InpATRPeriod          = 14;
input double InpATRBufferMult      = 0.20;   // SL buffer = ATR * this

input int    InpFractalDepth       = 2;      // iFractals default depth
input int    InpSwingLookbackBars  = 800;

input int    InpMaxStackPerDir     = 3;      // max trades in one direction

input double InpTP1ClosePercent    = 75.0;   // partial close at TP1
input int    InpSessionBars        = 300;    // session high/low window in M1 bars (approx 5h)

// Liquidity sweep rule B
input bool   InpUseLiquiditySweep  = true;
input int    InpSweepLookbackBars  = 20;
input int    InpSweepValidBars     = 3;      // sweep must be within last N bars
input double InpSweepMinWickATR    = 0.05;   // wick size >= ATR * this

// Entry confirmations
input bool   InpUseMSSRuleA        = true;
input bool   InpUseSweepRuleB      = true;

//-------------------- State --------------------
datetime g_lastBarTime = 0;

// micro-structure state per direction
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

// Get last confirmed fractal high/low with its bar index and bar time
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

// Get last TWO confirmed fractals (most recent = idx1)
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

   if(c1 <= sh && c0 > sh) return 1;   // bullish MSS
   if(c1 >= sl && c0 < sl) return -1;  // bearish MSS
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

// Liquidity sweep detection on current bar
bool SweepHighNow(double &priorHigh)
{
   priorHigh = -DBL_MAX;
   int N=MathMax(5, InpSweepLookbackBars);
   for(int i=1;i<=N;i++) priorHigh = MathMax(priorHigh, iHigh(_Symbol, PERIOD_M1, i));

   double h0=iHigh(_Symbol, PERIOD_M1, 0);
   double c0=iClose(_Symbol, PERIOD_M1, 0);
   double o0=iOpen(_Symbol, PERIOD_M1, 0);

   if(h0 <= priorHigh) return false;

   double atr=ATRValue(0);
   double minW = (atr>0 ? InpSweepMinWickATR*atr : 0);
   double wick = h0 - MathMax(o0,c0);
   if(minW>0 && wick < minW) return false;

   return (c0 < priorHigh);
}

bool SweepLowNow(double &priorLow)
{
   priorLow = DBL_MAX;
   int N=MathMax(5, InpSweepLookbackBars);
   for(int i=1;i<=N;i++) priorLow = MathMin(priorLow, iLow(_Symbol, PERIOD_M1, i));

   double l0=iLow(_Symbol, PERIOD_M1, 0);
   double c0=iClose(_Symbol, PERIOD_M1, 0);
   double o0=iOpen(_Symbol, PERIOD_M1, 0);

   if(l0 >= priorLow) return false;

   double atr=ATRValue(0);
   double minW = (atr>0 ? InpSweepMinWickATR*atr : 0);
   double wick = MathMin(o0,c0) - l0;
   if(minW>0 && wick < minW) return false;

   return (c0 > priorLow);
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

// Register any positions not yet tracked (best-effort)
void SyncTicketTracking()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;

      ulong ticket=pos.Ticket();
      if(FindTicketIdx(ticket)>=0) continue;

      // If we don't know tp1 for an older position, we won't partial it.
      // We only track tp1 at entry. So skip.
   }
}

// TP1 partial close per ticket
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

      // normalize
      closeVol = MathFloor(closeVol/step)*step;
      closeVol = NormalizeDouble(closeVol, 2);

      if(closeVol>=minLot && closeVol < vol)
         trade.PositionClosePartial(ticket, closeVol, 30);

      g_tp1active[idx]=false;
   }
}

// Runner exit on opposite MSS
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
      if(type==POSITION_TYPE_BUY && mss==-1)
         trade.PositionClose(pos.Ticket(), 30);
      if(type==POSITION_TYPE_SELL && mss==1)
         trade.PositionClose(pos.Ticket(), 30);
   }
}

// Build rule A: MSS -> wait HL/LH -> entry confirmation
bool RuleA_Buy(double &entry, double &sl, double &tp1, double &tp2)
{
   // Need bullish MSS occurred recently (this bar)
   int mss = MicroMSS();
   if(mss==1) g_bullMSSTime = iTime(_Symbol, PERIOD_M1, 0);
   if(g_bullMSSTime==0) return false;

   // Find latest confirmed fractal low AFTER MSS time => HL
   int il1,il2; double pl1,pl2; datetime tl1,tl2;
   if(!LastTwoFractals(false, il1, pl1, tl1, il2, pl2, tl2)) return false;

   if(tl1 > g_bullMSSTime && tl1 != g_lastBullHLTime)
   {
      g_lastBullHL = pl1;
      g_lastBullHLTime = tl1;
   }
   if(g_lastBullHLTime==0) return false;

   // Entry confirmation: close breaks above previous bar high
   double c0=iClose(_Symbol, PERIOD_M1, 0);
   double ph=iHigh(_Symbol, PERIOD_M1, 1);
   if(c0 <= ph) return false;

   // TP1 = prior swing high (the last fractal high that was broken or latest swing high)
   int ih1,ih2; double ph1,ph2; datetime th1,th2;
   if(!LastTwoFractals(true, ih1, ph1, th1, ih2, ph2, th2)) return false;

   double atr=ATRValue(0);
   double buf=(atr>0? atr*InpATRBufferMult : 0);

   entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   sl    = g_lastBullHL - buf;     // SL at HL/LL
   tp1   = ph1;                    // TP1 at HH
   tp2   = SessionHigh();          // runner TP2

   // Basic sanity: reward positive
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

   // Entry confirmation: close breaks below previous bar low
   double c0=iClose(_Symbol, PERIOD_M1, 0);
   double pl=iLow(_Symbol, PERIOD_M1, 1);
   if(c0 >= pl) return false;

   // TP1 at prior swing low
   int il1,il2; double pl1,pl2; datetime tl1,tl2;
   if(!LastTwoFractals(false, il1, pl1, tl1, il2, pl2, tl2)) return false;

   double atr=ATRValue(0);
   double buf=(atr>0? atr*InpATRBufferMult : 0);

   entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   sl    = g_lastBearLH + buf;
   tp1   = pl1;
   tp2   = SessionLow();

   if(tp1 >= entry) return false;
   if(entry >= sl) return false;
   return true;
}

// Build rule B: Sweep -> reclaim -> micro MSS -> entry
bool RuleB_Buy(double &entry, double &sl, double &tp1, double &tp2)
{
   if(!InpUseLiquiditySweep) return false;

   // Detect a sweep low within last valid bars
   bool swept=false;
   double sweptLevel=0;
   datetime sweptTime=0;

   for(int s=0; s<InpSweepValidBars; s++)
   {
      // simulate sweep check at shift s by comparing low[s] with min prior lows
      int N=MathMax(5, InpSweepLookbackBars);
      double priorLow=DBL_MAX;
      for(int i=s+1;i<=s+N;i++) priorLow = MathMin(priorLow, iLow(_Symbol, PERIOD_M1, i));

      double ls=iLow(_Symbol, PERIOD_M1, s);
      double cs=iClose(_Symbol, PERIOD_M1, s);
      double os=iOpen(_Symbol, PERIOD_M1, s);

      if(ls < priorLow && cs > priorLow)
      {
         // wick filter
         double atr=ATRValue(s);
         double minW=(atr>0? InpSweepMinWickATR*atr : 0);
         double wick = MathMin(os,cs) - ls;
         if(minW<=0 || wick >= minW)
         {
            swept=true;
            sweptLevel=priorLow;
            sweptTime=iTime(_Symbol, PERIOD_M1, s);
            break;
         }
      }
   }
   if(!swept) return false;

   // Reclaim: current close above sweptLevel
   double c0=iClose(_Symbol, PERIOD_M1, 0);
   if(c0 <= sweptLevel) return false;

   // Micro MSS bullish now
   if(MicroMSS() != 1) return false;

   // Use most recent swing low as SL, TP1 at recent swing high
   int il; double slw; datetime tl;
   int ih; double sh; datetime th;
   if(!LastFractal(false, il, slw, tl)) return false;
   if(!LastFractal(true,  ih, sh,  th)) return false;

   double atr=ATRValue(0);
   double buf=(atr>0? atr*InpATRBufferMult : 0);

   entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   sl    = slw - buf;
   tp1   = sh;
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
   datetime sweptTime=0;

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
            sweptTime=iTime(_Symbol, PERIOD_M1, s);
            break;
         }
      }
   }
   if(!swept) return false;

   // Reclaim: current close below sweptLevel
   double c0=iClose(_Symbol, PERIOD_M1, 0);
   if(c0 >= sweptLevel) return false;

   // Micro MSS bearish now
   if(MicroMSS() != -1) return false;

   int ih; double sh; datetime th;
   int il; double slw; datetime tl;
   if(!LastFractal(true, ih, sh, th)) return false;
   if(!LastFractal(false, il, slw, tl)) return false;

   double atr=ATRValue(0);
   double buf=(atr>0? atr*InpATRBufferMult : 0);

   entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   sl    = sh + buf;
   tp1   = slw;
   tp2   = SessionLow();

   if(tp1 >= entry) return false;
   if(entry >= sl) return false;
   return true;
}

// Open trade with stacking limit
bool OpenBuy(double entry, double sl, double tp2, double tp1)
{
   if(HasOppositePositions(1)) return false;
   if(CountPositions(1) >= InpMaxStackPerDir) return false;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);

   bool ok = trade.Buy(InpFixedLot, _Symbol, entry, sl, tp2, "GA_v8_BUY");
   if(!ok) return false;

   // Find the newest position ticket for this EA buy and track TP1
   ulong newest=0;
   datetime newestTime=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;
      if(pos.PositionType()!=POSITION_TYPE_BUY) continue;
      datetime ot=(datetime)pos.Time();
      if(ot >= newestTime){ newestTime=ot; newest=pos.Ticket(); }
   }
   TrackTicket(newest, tp1);
   return true;
}

bool OpenSell(double entry, double sl, double tp2, double tp1)
{
   if(HasOppositePositions(-1)) return false;
   if(CountPositions(-1) >= InpMaxStackPerDir) return false;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);

   bool ok = trade.Sell(InpFixedLot, _Symbol, entry, sl, tp2, "GA_v8_SELL");
   if(!ok) return false;

   ulong newest=0;
   datetime newestTime=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if((ulong)pos.Magic()!=InpMagic) continue;
      if(pos.PositionType()!=POSITION_TYPE_SELL) continue;
      datetime ot=(datetime)pos.Time();
      if(ot >= newestTime){ newestTime=ot; newest=pos.Ticket(); }
   }
   TrackTicket(newest, tp1);
   return true;
}

//-------------------- Main trading loop --------------------
void TryTrade()
{
   // Exits managed elsewhere

   // Build & place trades (SELL priority optional; here we evaluate both)
   double entry, sl, tp1, tp2;

   // BUY
   bool buySignal=false;
   if(InpUseMSSRuleA && RuleA_Buy(entry, sl, tp1, tp2)) buySignal=true;
   else if(InpUseSweepRuleB && RuleB_Buy(entry, sl, tp1, tp2)) buySignal=true;

   if(buySignal)
      OpenBuy(entry, sl, tp2, tp1);

   // SELL
   bool sellSignal=false;
   if(InpUseMSSRuleA && RuleA_Sell(entry, sl, tp1, tp2)) sellSignal=true;
   else if(InpUseSweepRuleB && RuleB_Sell(entry, sl, tp1, tp2)) sellSignal=true;

   if(sellSignal)
      OpenSell(entry, sl, tp2, tp1);
}

int OnInit()
{
   return INIT_SUCCEEDED;
}

void OnTick()
{
   ManageTP1();
   ManageRunnerExit();

   if(!IsNewBar(g_lastBarTime)) return;

   TryTrade();
}
//+------------------------------------------------------------------+
