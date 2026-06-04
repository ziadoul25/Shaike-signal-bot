//+------------------------------------------------------------------+
//|                                             CustomScalper247.mq5 |
//|                                  Copyright 2026, Algorithmic Bot |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

// Include Trade Library for safe execution
#include <Trade\Trade.mqh>
CTrade trade;

//--- Input Parameters (Adjustable in MT5 UI)
input group "---- Risk Management ----"
input double   InpRiskPercent    = 1.0;       // Risk Percent Per Trade (%)
input int      InpStopLossPips   = 20;        // Strict Stop Loss (in Pips)
input int      InpTakeProfitPips = 10;        // Scalping Target (in Pips)
input ulong    InpMagicNumber    = 123456;    // Unique ID for this Bot

input group "---- Strategy Settings ----"
input int      InpRsiPeriod      = 14;        // RSI Period
input double   InpRsiOverbought  = 70.0;      // Sell Entry Threshold
input double   InpRsiOversold    = 30.0;      // Buy Entry Threshold
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1; // Quick Scalping Timeframe (1 Minute)

input group "---- Advanced Settings ----"
input bool     InpUseTrailingStop = true;     // Enable Trailing Stop
input int      InpTrailingStopPips = 5;       // Trailing Stop Distance (Pips)
input int      InpMaxPositionsPerSymbol = 1;  // Max Concurrent Positions
input bool     InpCloseOnOppositeSignal = true; // Close on Opposite RSI Signal
input double   InpDailyLossLimitPercent = 3.0; // Daily Loss Limit (%)

//--- Global Variables
int rsiHandle;
datetime lastBarTime;
datetime dailyStartTime = 0;
double dailyStartEquity = 0.0;
bool dailyLimitReached = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Assign Magic Number to differentiate trades from other bots
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   // Initialize the RSI Indicator handle for the selected asset
   rsiHandle = iRSI(_Symbol, InpTimeframe, InpRsiPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to initialize RSI Indicator handle.");
      return(INIT_FAILED);
   }

   lastBarTime = 0;
   dailyStartTime = TimeCurrent();
   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dailyLimitReached = false;
   
   Print("╔════════════════════════════════════════╗");
   Print("║  24/7 Custom Scalper 247 Initialized   ║");
   Print("║  Symbol: ", _Symbol);
   Print("║  Timeframe: ", EnumToString(InpTimeframe));
   Print("║  Magic Number: ", InpMagicNumber);
   Print("╚════════════════════════════════════════╝");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator memory handles upon removal
   IndicatorRelease(rsiHandle);
   PrintFormat("CustomScalper247 deinitialized. Reason: %d", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function (Executes 24/7 on every price movement)     |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check daily loss limit
   CheckDailyLossLimit();
   
   if(dailyLimitReached)
   {
      PrintFormat("CustomScalper247: Daily loss limit reached. Trading stopped.");
      return;
   }

   // Ensure logic only runs once per bar completion to prevent duplicate orders
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
   if(currentBarTime == lastBarTime) return;
   
   lastBarTime = currentBarTime;
   
   // Check if we already have an open position for this specific bot instance
   int openPositions = CountOpenPositions(_Symbol, InpMagicNumber);
   
   if(openPositions >= InpMaxPositionsPerSymbol)
   {
      UpdateTrailingStops();
      return; // Exit if max positions reached
   }

   // Fetch recent RSI Values
   double rsiValues[];
   ArraySetAsSeries(rsiValues, true);
   if(CopyBuffer(rsiHandle, 0, 1, 2, rsiValues) < 2) return;

   double currentRsi = rsiValues[0];
   double previousRsi = rsiValues[1];
   
   // Get current market prices
   MqlTick latestTick;
   if(!SymbolInfoTick(_Symbol, latestTick)) return;

   // Calculate Point values accurately across various broker decimal variations
   double pointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipMultiplier = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   
   double slDistance = InpStopLossPips * pipMultiplier * pointSize;
   double tpDistance = InpTakeProfitPips * pipMultiplier * pointSize;

   // Dynamic Position Sizing based on Account Equity Risk Allocation Rules
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (InpRiskPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tickValue <= 0 || tickSize <= 0) return;
   
   // Calculate optimal Lot Size matching exact parameters requested
   double calculatedLots = (riskAmount) / ((slDistance / tickSize) * tickValue);
   
   // Normalize lot size variations allowed by your specific platform server
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   calculatedLots = MathFloor(calculatedLots / lotStep) * lotStep;
   if(calculatedLots < minLot) calculatedLots = minLot;
   if(calculatedLots > maxLot) calculatedLots = maxLot;

   //--- Check for opposite signal to close existing position
   if(InpCloseOnOppositeSignal && openPositions > 0)
   {
      // Check if we should close an open SELL position
      if(currentRsi > InpRsiOversold && previousRsi <= InpRsiOversold)
      {
         ClosePositionsByType(_Symbol, InpMagicNumber, POSITION_TYPE_SELL);
      }
      // Check if we should close an open BUY position
      if(currentRsi < InpRsiOverbought && previousRsi >= InpRsiOverbought)
      {
         ClosePositionsByType(_Symbol, InpMagicNumber, POSITION_TYPE_BUY);
      }
   }

   //--- Execution Trade Logic (Mean Reversion Mode)
   // BUY Condition: RSI crosses back above Oversold line
   if(currentRsi > InpRsiOversold && previousRsi <= InpRsiOversold && openPositions == 0)
   {
      double askPrice = latestTick.ask;
      double stopLoss = NormalizeDouble(askPrice - slDistance, digits);
      double takeProfit = NormalizeDouble(askPrice + tpDistance, digits);
      
      // Validate stops
      if(ValidateStops(ORDER_TYPE_BUY, askPrice, stopLoss, takeProfit))
      {
         if(trade.Buy(calculatedLots, _Symbol, 0.0, stopLoss, takeProfit, "Scalp Buy"))
         {
            PrintFormat("✓ CustomScalper247 BUY: %s | RSI: %.2f | Lots: %.2f | SL: %.*f | TP: %.*f",
                        _Symbol, currentRsi, calculatedLots, digits, stopLoss, digits, takeProfit);
         }
         else
         {
            PrintFormat("✗ CustomScalper247 BUY FAILED: %s | Error: %d", _Symbol, GetLastError());
         }
      }
   }
   // SELL Condition: RSI crosses back down below Overbought line
   else if(currentRsi < InpRsiOverbought && previousRsi >= InpRsiOverbought && openPositions == 0)
   {
      double bidPrice = latestTick.bid;
      double stopLoss = NormalizeDouble(bidPrice + slDistance, digits);
      double takeProfit = NormalizeDouble(bidPrice - tpDistance, digits);
      
      // Validate stops
      if(ValidateStops(ORDER_TYPE_SELL, bidPrice, stopLoss, takeProfit))
      {
         if(trade.Sell(calculatedLots, _Symbol, 0.0, stopLoss, takeProfit, "Scalp Sell"))
         {
            PrintFormat("✓ CustomScalper247 SELL: %s | RSI: %.2f | Lots: %.2f | SL: %.*f | TP: %.*f",
                        _Symbol, currentRsi, calculatedLots, digits, stopLoss, digits, takeProfit);
         }
         else
         {
            PrintFormat("✗ CustomScalper247 SELL FAILED: %s | Error: %d", _Symbol, GetLastError());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Count open positions for symbol and magic number                 |
//+------------------------------------------------------------------+
int CountOpenPositions(const string symbol, const ulong magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == magic)
      {
         count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Close positions by type (BUY or SELL)                            |
//+------------------------------------------------------------------+
void ClosePositionsByType(const string symbol, const ulong magic, const ENUM_POSITION_TYPE posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && 
         PositionGetInteger(POSITION_MAGIC) == magic &&
         PositionGetInteger(POSITION_TYPE) == posType)
      {
         ulong ticket = PositionGetTicket(i);
         if(trade.PositionClose(ticket))
         {
            PrintFormat("✓ Position closed: %s | Type: %s", symbol, (posType == POSITION_TYPE_BUY ? "BUY" : "SELL"));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Update trailing stops for open positions                         |
//+------------------------------------------------------------------+
void UpdateTrailingStops()
{
   if(!InpUseTrailingStop) return;
   
   double pointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipMultiplier = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   double trailingDistance = InpTrailingStopPips * pipMultiplier * pointSize;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!PositionSelectByTicket(ticket)) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      MqlTick latestTick;
      if(!SymbolInfoTick(_Symbol, latestTick)) continue;

      if(posType == POSITION_TYPE_BUY)
      {
         double newSL = NormalizeDouble(latestTick.bid - trailingDistance, digits);
         if(newSL > currentSL)
         {
            trade.PositionModify(ticket, newSL, currentTP);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double newSL = NormalizeDouble(latestTick.ask + trailingDistance, digits);
         if(newSL < currentSL && currentSL > 0)
         {
            trade.PositionModify(ticket, newSL, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Validate Stop Loss and Take Profit levels                        |
//+------------------------------------------------------------------+
bool ValidateStops(const ENUM_ORDER_TYPE orderType, const double entryPrice, 
                   const double stopLoss, const double takeProfit)
{
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double pointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStopDistance = stopsLevel * pointSize;

   if(orderType == ORDER_TYPE_BUY)
   {
      if(stopLoss >= entryPrice || takeProfit <= entryPrice) return false;
      if(minStopDistance > 0 && ((entryPrice - stopLoss) < minStopDistance)) return false;
   }
   else if(orderType == ORDER_TYPE_SELL)
   {
      if(stopLoss <= entryPrice || takeProfit >= entryPrice) return false;
      if(minStopDistance > 0 && ((stopLoss - entryPrice) < minStopDistance)) return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check Daily Loss Limit                                           |
//+------------------------------------------------------------------+
void CheckDailyLossLimit()
{
   // Reset daily counters at midnight UTC
   datetime currentTime = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   datetime dayStart = StructToTime({dt.year, dt.mon, dt.day, 0, 0, 0});
   
   if(dayStart > dailyStartTime)
   {
      dailyStartTime = dayStart;
      dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      dailyLimitReached = false;
      PrintFormat("CustomScalper247: Daily reset. Start Equity: %.2f", dailyStartEquity);
      return;
   }

   // Check if daily loss limit is reached
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxDailyLoss = dailyStartEquity * (InpDailyLossLimitPercent / 100.0);
   double currentLoss = dailyStartEquity - currentEquity;

   if(currentLoss >= maxDailyLoss)
   {
      dailyLimitReached = true;
      PrintFormat("⚠ CustomScalper247: Daily loss limit reached! Loss: %.2f / Limit: %.2f", 
                  currentLoss, maxDailyLoss);
   }
}

//+------------------------------------------------------------------+
//| End of CustomScalper247.mq5                                       |
//+------------------------------------------------------------------+
