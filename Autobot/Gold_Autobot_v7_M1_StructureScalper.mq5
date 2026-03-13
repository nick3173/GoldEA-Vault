//+------------------------------------------------------------------+
//|                 Gold_Autobot_v7_M1_StructureScalper.mq5           |
//|  User spec upgrade                                                |
//|  TF: M1 ONLY                                                      |
//|                                                                  |
//|  Entry Rule A (Dow structure):                                    |
//|     Bullish: MSS -> HH -> HL entry                                |
//|     Bearish: MSS -> LL -> LH entry                                |
//|                                                                  |
//|  Entry Rule B (Liquidity sweep):                                  |
//|     Sweep -> Reclaim -> Micro MSS -> Entry                        |
//|                                                                  |
//|  Risk model:                                                      |
//|     SL = structure LL/HH + ATR buffer                             |
//|     Auto lot so max loss = $400                                   |
//|                                                                  |
//|  TP model:                                                        |
//|     TP1 = previous HH/LL (close 75%)                              |
//|     TP2 = session high/low runner                                 |
//|                                                                  |
//|  Notes:                                                           |
//|     No higher timeframe filters                                   |
//|     No major key levels                                           |
//|     Unlimited trades                                              |
//+------------------------------------------------------------------+
#property version   "7.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade trade;
CPositionInfo pos;

//-------------------- Inputs --------------------

input double MaxRiskUSD = 400.0;
input double TP1ClosePercent = 75.0;

input int ATR_Period = 14;
input double ATR_Buffer = 0.20;

input int SweepLookback = 20;

//-------------------- State --------------------

datetime lastBar = 0;
bool tp1done=false;
double tp1price=0;

//-------------------- Utilities --------------------

bool NewBar()
{
 datetime t=iTime(_Symbol,PERIOD_M1,0);
 if(t!=lastBar)
 {
  lastBar=t;
  return true;
 }
 return false;
}

double ATR()
{
 int h=iATR(_Symbol,PERIOD_M1,ATR_Period);
 double b[];
 ArraySetAsSeries(b,true);
 CopyBuffer(h,0,0,1,b);
 return b[0];
}

double PointValue()
{
 double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
 double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 return tv/ts;
}

//-------------------- Structure --------------------

bool BullishMSS()
{
 double h1=iHigh(_Symbol,PERIOD_M1,1);
 double h2=iHigh(_Symbol,PERIOD_M1,2);
 double c0=iClose(_Symbol,PERIOD_M1,0);

 return (c0>h1 && h1<h2);
}

bool BearishMSS()
{
 double l1=iLow(_Symbol,PERIOD_M1,1);
 double l2=iLow(_Symbol,PERIOD_M1,2);
 double c0=iClose(_Symbol,PERIOD_M1,0);

 return (c0<l1 && l1>l2);
}

//-------------------- Liquidity sweep --------------------

bool SweepHigh()
{
 double highest=-DBL_MAX;

 for(int i=1;i<=SweepLookback;i++)
  highest=MathMax(highest,iHigh(_Symbol,PERIOD_M1,i));

 double h0=iHigh(_Symbol,PERIOD_M1,0);
 double c0=iClose(_Symbol,PERIOD_M1,0);

 if(h0>highest && c0<highest)
  return true;

 return false;
}

bool SweepLow()
{
 double lowest=DBL_MAX;

 for(int i=1;i<=SweepLookback;i++)
  lowest=MathMin(lowest,iLow(_Symbol,PERIOD_M1,i));

 double l0=iLow(_Symbol,PERIOD_M1,0);
 double c0=iClose(_Symbol,PERIOD_M1,0);

 if(l0<lowest && c0>lowest)
  return true;

 return false;
}

//-------------------- Session levels --------------------

double SessionHigh()
{
 double high=-DBL_MAX;
 for(int i=0;i<200;i++)
  high=MathMax(high,iHigh(_Symbol,PERIOD_M1,i));
 return high;
}

double SessionLow()
{
 double low=DBL_MAX;
 for(int i=0;i<200;i++)
  low=MathMin(low,iLow(_Symbol,PERIOD_M1,i));
 return low;
}

//-------------------- Lot calculation --------------------

double CalcLot(double entry,double sl)
{
 double dist=MathAbs(entry-sl)/_Point;
 double lossPerLot=dist*PointValue();
 double lot=MaxRiskUSD/lossPerLot;

 double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 lot=MathFloor(lot/step)*step;

 return lot;
}

//-------------------- TP1 management --------------------

void ManageTP1()
{
 if(!tp1done) return;

 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  if(!pos.SelectByIndex(i)) continue;
  if(pos.Symbol()!=_Symbol) continue;

  long type=pos.PositionType();

  double price=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);

  bool hit=(type==POSITION_TYPE_BUY)?price>=tp1price:price<=tp1price;

  if(hit)
  {
   double vol=pos.Volume();
   double closevol=vol*(TP1ClosePercent/100.0);
   trade.PositionClosePartial(pos.Ticket(),closevol);
   tp1done=false;
  }
 }
}

//-------------------- Entries --------------------

void TryTrade()
{
 if(PositionsTotal()>0) return;

 double atr=ATR();
 double buf=atr*ATR_Buffer;

 double entry,sl,tp1,tp2;

 //----- Bullish structure rule

 if(BullishMSS())
 {
  entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
  sl=iLow(_Symbol,PERIOD_M1,1)-buf;
  tp1=iHigh(_Symbol,PERIOD_M1,2);
  tp2=SessionHigh();

  double lot=CalcLot(entry,sl);

  if(trade.Buy(lot,_Symbol,entry,sl,tp2))
  {
   tp1price=tp1;
   tp1done=true;
  }
 }

 //----- Bearish structure rule

 if(BearishMSS())
 {
  entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
  sl=iHigh(_Symbol,PERIOD_M1,1)+buf;
  tp1=iLow(_Symbol,PERIOD_M1,2);
  tp2=SessionLow();

  double lot=CalcLot(entry,sl);

  if(trade.Sell(lot,_Symbol,entry,sl,tp2))
  {
   tp1price=tp1;
   tp1done=true;
  }
 }

 //----- Sweep rule

 if(SweepLow() && BullishMSS())
 {
  entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
  sl=iLow(_Symbol,PERIOD_M1,1)-buf;
  tp1=iHigh(_Symbol,PERIOD_M1,2);
  tp2=SessionHigh();

  double lot=CalcLot(entry,sl);
  trade.Buy(lot,_Symbol,entry,sl,tp2);
 }

 if(SweepHigh() && BearishMSS())
 {
  entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
  sl=iHigh(_Symbol,PERIOD_M1,1)+buf;
  tp1=iLow(_Symbol,PERIOD_M1,2);
  tp2=SessionLow();

  double lot=CalcLot(entry,sl);
  trade.Sell(lot,_Symbol,entry,sl,tp2);
 }

}

//-------------------- Main --------------------

int OnInit()
{
 return INIT_SUCCEEDED;
}

void OnTick()
{
 ManageTP1();

 if(!NewBar()) return;

 TryTrade();
}
//+------------------------------------------------------------------+
