//+------------------------------------------------------------------+
//| GoldEAResurrection_v4_11_MicroV_ProfitRunner.mq5                 |
//| MicroV Expansion Entry + Profit Runner Logic                     |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

// ---- Inputs
input double LotSize = 0.30;
input double TP1_Money = 40.0;
input double LockProfit = 5.0;
input int ATR_Period = 14;
input double ATR_Buffer = 1.5;

// ---- Globals
double entryPrice = 0;
bool runnerMode = false;
bool tp1Reached = false;

//+------------------------------------------------------------------+
double GetATR()
{
   return iATR(_Symbol, PERIOD_M1, ATR_Period, 0);
}

//+------------------------------------------------------------------+
bool BullishMicroV()
{
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double c2 = iClose(_Symbol, PERIOD_M1, 2);
   double c3 = iClose(_Symbol, PERIOD_M1, 3);

   if(c2 < c3 && c1 > c2)
      return true;

   return false;
}

//+------------------------------------------------------------------+
bool BearishMicroV()
{
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double c2 = iClose(_Symbol, PERIOD_M1, 2);
   double c3 = iClose(_Symbol, PERIOD_M1, 3);

   if(c2 > c3 && c1 < c2)
      return true;

   return false;
}

//+------------------------------------------------------------------+
void ManageRunner()
{
   if(!PositionSelect(_Symbol)) return;

   double profit = PositionGetDouble(POSITION_PROFIT);

   if(!tp1Reached && profit >= TP1_Money)
   {
      tp1Reached = true;
      runnerMode = true;

      double newSL;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         newSL = entryPrice + LockProfit / SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
      else
         newSL = entryPrice - LockProfit / SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);

      trade.PositionModify(_Symbol,newSL,0);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageRunner();

   if(PositionSelect(_Symbol))
      return;

   double atr = GetATR();

   if(BullishMicroV())
   {
      double sl = iLow(_Symbol,PERIOD_M1,1) - (atr * ATR_Buffer);

      trade.Buy(LotSize,_Symbol,0,sl,0,"MicroV Buy");

      entryPrice = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      tp1Reached = false;
      runnerMode = false;
   }

   if(BearishMicroV())
   {
      double sl = iHigh(_Symbol,PERIOD_M1,1) + (atr * ATR_Buffer);

      trade.Sell(LotSize,_Symbol,0,sl,0,"MicroV Sell");

      entryPrice = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      tp1Reached = false;
      runnerMode = false;
   }
}
