//+------------------------------------------------------------------+
//|                                                        SHAKE.mq5 |
//|                         Triple-MA Multi-Timeframe Trend EA       |
//|                                                Version: v1.0      |
//|                                                Contact: ziadoul25 |
//+------------------------------------------------------------------+
#property copyright "ziadoul25"
#property link      ""
#property version   "1.00"
#property strict
#property description "SHAKE v1.0 - Triple Moving Average multi-timeframe trend-following EA."
#property description "Targets BTCUSD and XAUUSD on M1 with configurable risk management."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input parameters                                                  |
//+------------------------------------------------------------------+
input group "General Settings"
input ulong            InpMagicNumber              = 250125;       // Magic number used to identify SHAKE trades
input string           InpTradeSymbols             = "BTCUSD,XAUUSD"; // Comma-separated list of allowed symbols
input bool             InpEnforceM1Chart           = true;         // Only trade when attached to M1 chart
input int              InpSlippagePoints           = 30;           // Maximum price deviation in points
input bool             InpTradeOnNewBarOnly        = true;         // Evaluate entries once per new M1 bar

input group "Moving Average Settings"
input int              InpFastMAPeriod             = 20;           // Fast MA period
input int              InpMediumMAPeriod           = 50;           // Medium MA period
input int              InpSlowMAPeriod             = 200;          // Slow MA period
input ENUM_MA_METHOD   InpMAMethod                 = MODE_EMA;     // Moving average method
input ENUM_APPLIED_PRICE InpAppliedPrice           = PRICE_CLOSE;  // Applied price

input group "Multi-Timeframe Confirmation"
input ENUM_TIMEFRAMES  InpConfirmTF1               = PERIOD_M1;    // Confirmation timeframe 1
input ENUM_TIMEFRAMES  InpConfirmTF2               = PERIOD_M5;    // Confirmation timeframe 2
input ENUM_TIMEFRAMES  InpConfirmTF3               = PERIOD_M15;   // Confirmation timeframe 3

input group "Risk Management"
input double           InpRiskPercent              = 1.0;          // Account risk per trade, percent
input int              InpStopLossPoints           = 50;           // Fixed stop loss in points
input double           InpRiskRewardRatio          = 2.0;          // Take profit risk:reward ratio
input double           InpDailyLossLimitPercent    = 2.0;          // Daily loss limit, percent of UTC start equity
input bool             InpUseEquityForRisk         = true;         // Use equity instead of balance for risk sizing

input group "Execution Filters"
input int              InpMaxSpreadPoints          = 0;            // Maximum spread in points; 0 disables filter
input bool             InpOnePositionPerSymbol     = true;         // Prevent multiple simultaneous positions on same symbol

//+------------------------------------------------------------------+
//| Global constants and variables                                    |
//+------------------------------------------------------------------+
#define TF_COUNT 3
#define MA_FAST  0
#define MA_MED   1
#define MA_SLOW  2

CTrade trade;

ENUM_TIMEFRAMES g_timeframes[TF_COUNT];
int             g_ma_handles[TF_COUNT][TF_COUNT];
datetime        g_last_bar_time = 0;
datetime        g_current_utc_day_start = 0;
double          g_day_start_equity = 0.0;
bool            g_daily_trading_stopped = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   g_timeframes[0] = InpConfirmTF1;
   g_timeframes[1] = InpConfirmTF2;
   g_timeframes[2] = InpConfirmTF3;

   ArrayInitialize(g_ma_handles, INVALID_HANDLE);

   if(!IsAllowedSymbol(_Symbol))
   {
      PrintFormat("SHAKE v1.0: Symbol %s is not in the allowed target list: %s", _Symbol, InpTradeSymbols);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpEnforceM1Chart && _Period != PERIOD_M1)
   {
      Print("SHAKE v1.0: This EA is configured for the M1 primary timeframe. Attach it to an M1 chart or disable InpEnforceM1Chart.");
      return INIT_PARAMETERS_INCORRECT;
   }

   for(int tf = 0; tf < TF_COUNT; tf++)
   {
      g_ma_handles[tf][MA_FAST] = iMA(_Symbol, g_timeframes[tf], InpFastMAPeriod, 0, InpMAMethod, InpAppliedPrice);
      g_ma_handles[tf][MA_MED]  = iMA(_Symbol, g_timeframes[tf], InpMediumMAPeriod, 0, InpMAMethod, InpAppliedPrice);
      g_ma_handles[tf][MA_SLOW] = iMA(_Symbol, g_timeframes[tf], InpSlowMAPeriod, 0, InpMAMethod, InpAppliedPrice);

      if(g_ma_handles[tf][MA_FAST] == INVALID_HANDLE ||
         g_ma_handles[tf][MA_MED]  == INVALID_HANDLE ||
         g_ma_handles[tf][MA_SLOW] == INVALID_HANDLE)
      {
         PrintFormat("SHAKE v1.0: Failed to create MA handles for timeframe %s. Error: %d",
                     EnumToString(g_timeframes[tf]), GetLastError());
         ReleaseIndicatorHandles();
         return INIT_FAILED;
      }
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   ResetDailyCountersIfNeeded(true);

   PrintFormat("SHAKE v1.0 initialized successfully on %s %s. Contact: ziadoul25",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ReleaseIndicatorHandles();
   PrintFormat("SHAKE v1.0 deinitialized. Reason code: %d", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyCountersIfNeeded(false);

   if(g_daily_trading_stopped)
      return;

   if(!IsTradingEnvironmentReady())
      return;

   if(InpTradeOnNewBarOnly && !IsNewBar(PERIOD_M1))
      return;

   if(InpOnePositionPerSymbol && HasOpenPositionForSymbolAndMagic(_Symbol, InpMagicNumber))
      return;

   if(InpMaxSpreadPoints > 0 && GetCurrentSpreadPoints() > InpMaxSpreadPoints)
   {
      PrintFormat("SHAKE v1.0: Spread filter blocked entry. Current spread: %d points; maximum allowed: %d points.",
                  GetCurrentSpreadPoints(), InpMaxSpreadPoints);
      return;
   }

   const bool buy_signal  = IsMultiTimeframeSignal(true);
   const bool sell_signal = IsMultiTimeframeSignal(false);

   if(buy_signal && !sell_signal)
      OpenPosition(ORDER_TYPE_BUY);
   else if(sell_signal && !buy_signal)
      OpenPosition(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| Validate all configurable inputs                                  |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   if(InpFastMAPeriod <= 0 || InpMediumMAPeriod <= 0 || InpSlowMAPeriod <= 0)
   {
      Print("SHAKE v1.0: MA periods must be positive.");
      return false;
   }

   if(!(InpFastMAPeriod < InpMediumMAPeriod && InpMediumMAPeriod < InpSlowMAPeriod))
   {
      Print("SHAKE v1.0: Recommended and required period order is Fast < Medium < Slow.");
      return false;
   }

   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
   {
      Print("SHAKE v1.0: InpRiskPercent must be greater than 0 and no more than 10.");
      return false;
   }

   if(InpStopLossPoints <= 0)
   {
      Print("SHAKE v1.0: InpStopLossPoints must be positive.");
      return false;
   }

   if(InpRiskRewardRatio <= 0.0)
   {
      Print("SHAKE v1.0: InpRiskRewardRatio must be positive.");
      return false;
   }

   if(InpDailyLossLimitPercent <= 0.0 || InpDailyLossLimitPercent > 100.0)
   {
      Print("SHAKE v1.0: InpDailyLossLimitPercent must be greater than 0 and no more than 100.");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Reset daily loss counters at midnight UTC                         |
//+------------------------------------------------------------------+
void ResetDailyCountersIfNeeded(const bool force_reset)
{
   const datetime utc_day_start = GetUtcDayStart(TimeGMT());

   if(force_reset || utc_day_start != g_current_utc_day_start)
   {
      g_current_utc_day_start = utc_day_start;
      g_day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_daily_trading_stopped = false;

      PrintFormat("SHAKE v1.0: Daily counters reset at UTC day start %s. Start equity: %.2f",
                  TimeToString(g_current_utc_day_start, TIME_DATE | TIME_MINUTES), g_day_start_equity);
      return;
   }

   if(g_day_start_equity <= 0.0)
      return;

   const double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const double max_loss_money = g_day_start_equity * InpDailyLossLimitPercent / 100.0;
   const double current_loss   = g_day_start_equity - current_equity;

   if(current_loss >= max_loss_money)
   {
      g_daily_trading_stopped = true;
      PrintFormat("SHAKE v1.0: Daily loss limit reached. Start equity: %.2f, current equity: %.2f, loss: %.2f, limit: %.2f. Trading stopped until next UTC day.",
                  g_day_start_equity, current_equity, current_loss, max_loss_money);
   }
}

//+------------------------------------------------------------------+
//| Return midnight UTC for a given timestamp                         |
//+------------------------------------------------------------------+
datetime GetUtcDayStart(const datetime timestamp)
{
   MqlDateTime dt;
   TimeToStruct(timestamp, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Confirm BUY or SELL trend across all configured timeframes        |
//+------------------------------------------------------------------+
bool IsMultiTimeframeSignal(const bool is_buy)
{
   for(int tf = 0; tf < TF_COUNT; tf++)
   {
      if(!IsTimeframeSignal(tf, is_buy))
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check one timeframe for MA order and price-location confirmation  |
//+------------------------------------------------------------------+
bool IsTimeframeSignal(const int tf_index, const bool is_buy)
{
   double fast_ma = 0.0;
   double med_ma  = 0.0;
   double slow_ma = 0.0;

   if(!GetMovingAverageValue(tf_index, MA_FAST, 1, fast_ma) ||
      !GetMovingAverageValue(tf_index, MA_MED,  1, med_ma)  ||
      !GetMovingAverageValue(tf_index, MA_SLOW, 1, slow_ma))
   {
      return false;
   }

   const double close_price = iClose(_Symbol, g_timeframes[tf_index], 1);
   if(close_price <= 0.0)
      return false;

   if(is_buy)
      return (fast_ma > med_ma && med_ma > slow_ma && close_price > fast_ma);

   return (fast_ma < med_ma && med_ma < slow_ma && close_price < fast_ma);
}

//+------------------------------------------------------------------+
//| Safely read an indicator buffer value                             |
//+------------------------------------------------------------------+
bool GetMovingAverageValue(const int tf_index, const int ma_index, const int shift, double &value)
{
   if(tf_index < 0 || tf_index >= TF_COUNT || ma_index < 0 || ma_index >= TF_COUNT)
      return false;

   const int handle = g_ma_handles[tf_index][ma_index];
   if(handle == INVALID_HANDLE)
      return false;

   if(BarsCalculated(handle) <= shift)
      return false;

   double buffer[1];
   ResetLastError();
   const int copied = CopyBuffer(handle, 0, shift, 1, buffer);
   if(copied != 1)
   {
      PrintFormat("SHAKE v1.0: CopyBuffer failed for TF %s, MA index %d. Error: %d",
                  EnumToString(g_timeframes[tf_index]), ma_index, GetLastError());
      return false;
   }

   value = buffer[0];
   return (value != EMPTY_VALUE && value > 0.0);
}

//+------------------------------------------------------------------+
//| Open a market position with fixed SL and RR-based TP              |
//+------------------------------------------------------------------+
bool OpenPosition(const ENUM_ORDER_TYPE order_type)
{
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const int digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(point <= 0.0)
   {
      Print("SHAKE v1.0: Invalid symbol point value.");
      return false;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      PrintFormat("SHAKE v1.0: SymbolInfoTick failed. Error: %d", GetLastError());
      return false;
   }

   const double entry_price = (order_type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   const double sl_distance = InpStopLossPoints * point;
   const double tp_distance = InpStopLossPoints * InpRiskRewardRatio * point;

   double stop_loss = 0.0;
   double take_profit = 0.0;

   if(order_type == ORDER_TYPE_BUY)
   {
      stop_loss   = NormalizeDouble(entry_price - sl_distance, digits);
      take_profit = NormalizeDouble(entry_price + tp_distance, digits);
   }
   else if(order_type == ORDER_TYPE_SELL)
   {
      stop_loss   = NormalizeDouble(entry_price + sl_distance, digits);
      take_profit = NormalizeDouble(entry_price - tp_distance, digits);
   }
   else
   {
      return false;
   }

   if(!ValidateStops(order_type, entry_price, stop_loss, take_profit))
      return false;

   const double volume = CalculatePositionSize(InpStopLossPoints);
   if(volume <= 0.0)
   {
      Print("SHAKE v1.0: Position size calculation returned zero. Order blocked.");
      return false;
   }

   const string comment = "SHAKE v1.0 | ziadoul25";
   bool result = false;

   if(order_type == ORDER_TYPE_BUY)
      result = trade.Buy(volume, _Symbol, 0.0, stop_loss, take_profit, comment);
   else
      result = trade.Sell(volume, _Symbol, 0.0, stop_loss, take_profit, comment);

   if(!result)
   {
      PrintFormat("SHAKE v1.0: Order failed. Retcode: %d, Retcode description: %s, LastError: %d",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription(), GetLastError());
      return false;
   }

   PrintFormat("SHAKE v1.0: %s order opened. Volume: %.2f, SL: %.*f, TP: %.*f, Magic: %I64u",
               (order_type == ORDER_TYPE_BUY ? "BUY" : "SELL"), volume, digits, stop_loss, digits, take_profit, InpMagicNumber);
   return true;
}

//+------------------------------------------------------------------+
//| Calculate volume so SL risk equals configured account percentage  |
//+------------------------------------------------------------------+
double CalculatePositionSize(const int stop_loss_points)
{
   const double risk_base = InpUseEquityForRisk ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE);
   const double risk_money = risk_base * InpRiskPercent / 100.0;

   const double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(risk_money <= 0.0 || tick_value <= 0.0 || tick_size <= 0.0 || point <= 0.0 || stop_loss_points <= 0)
   {
      PrintFormat("SHAKE v1.0: Invalid sizing inputs. RiskMoney: %.2f, TickValue: %.8f, TickSize: %.8f, Point: %.8f",
                  risk_money, tick_value, tick_size, point);
      return 0.0;
   }

   const double stop_loss_price_distance = stop_loss_points * point;
   const double loss_per_lot = (stop_loss_price_distance / tick_size) * tick_value;

   if(loss_per_lot <= 0.0)
   {
      Print("SHAKE v1.0: Invalid loss per lot calculation.");
      return 0.0;
   }

   double raw_volume = risk_money / loss_per_lot;
   return NormalizeAndValidateVolume(raw_volume);
}

//+------------------------------------------------------------------+
//| Normalize volume to symbol min/max/step constraints               |
//+------------------------------------------------------------------+
double NormalizeAndValidateVolume(const double raw_volume)
{
   const double min_volume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double max_volume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(raw_volume <= 0.0 || min_volume <= 0.0 || max_volume <= 0.0 || volume_step <= 0.0)
   {
      PrintFormat("SHAKE v1.0: Invalid volume constraints. Raw: %.8f, Min: %.8f, Max: %.8f, Step: %.8f",
                  raw_volume, min_volume, max_volume, volume_step);
      return 0.0;
   }

   double volume = MathFloor(raw_volume / volume_step) * volume_step;

   if(volume < min_volume)
   {
      PrintFormat("SHAKE v1.0: Calculated volume %.8f is below symbol minimum %.8f. Order blocked to preserve risk settings.",
                  volume, min_volume);
      return 0.0;
   }

   if(volume > max_volume)
      volume = max_volume;

   const int volume_digits = GetVolumeDigits(volume_step);
   volume = NormalizeDouble(volume, volume_digits);

   if(volume < min_volume || volume > max_volume)
      return 0.0;

   return volume;
}

//+------------------------------------------------------------------+
//| Determine decimal places required by the symbol volume step       |
//+------------------------------------------------------------------+
int GetVolumeDigits(const double volume_step)
{
   int digits = 0;
   double step = volume_step;

   while(digits < 8 && MathAbs(step - MathRound(step)) > 0.00000001)
   {
      step *= 10.0;
      digits++;
   }

   return digits;
}

//+------------------------------------------------------------------+
//| Validate SL/TP against broker stop-level requirements             |
//+------------------------------------------------------------------+
bool ValidateStops(const ENUM_ORDER_TYPE order_type, const double entry_price, const double stop_loss, const double take_profit)
{
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const int stops_level_points = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double min_stop_distance = stops_level_points * point;

   if(point <= 0.0)
      return false;

   if(order_type == ORDER_TYPE_BUY)
   {
      if(stop_loss >= entry_price || take_profit <= entry_price)
      {
         Print("SHAKE v1.0: Invalid BUY stop-loss or take-profit side.");
         return false;
      }

      if(min_stop_distance > 0.0 && ((entry_price - stop_loss) < min_stop_distance || (take_profit - entry_price) < min_stop_distance))
      {
         PrintFormat("SHAKE v1.0: BUY stops are too close. Broker minimum stop distance: %d points.", stops_level_points);
         return false;
      }
   }
   else if(order_type == ORDER_TYPE_SELL)
   {
      if(stop_loss <= entry_price || take_profit >= entry_price)
      {
         Print("SHAKE v1.0: Invalid SELL stop-loss or take-profit side.");
         return false;
      }

      if(min_stop_distance > 0.0 && ((stop_loss - entry_price) < min_stop_distance || (entry_price - take_profit) < min_stop_distance))
      {
         PrintFormat("SHAKE v1.0: SELL stops are too close. Broker minimum stop distance: %d points.", stops_level_points);
         return false;
      }
   }
   else
   {
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check symbol permissions and terminal/account trade state         |
//+------------------------------------------------------------------+
bool IsTradingEnvironmentReady()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return false;

   long trade_mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(trade_mode == SYMBOL_TRADE_MODE_DISABLED || trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Detect a new bar on the primary timeframe                         |
//+------------------------------------------------------------------+
bool IsNewBar(const ENUM_TIMEFRAMES timeframe)
{
   const datetime bar_time = iTime(_Symbol, timeframe, 0);
   if(bar_time <= 0)
      return false;

   if(bar_time != g_last_bar_time)
   {
      g_last_bar_time = bar_time;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Return current spread in points                                   |
//+------------------------------------------------------------------+
int GetCurrentSpreadPoints()
{
   const long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (int)spread;
}

//+------------------------------------------------------------------+
//| Check whether the attached symbol is in the configured list        |
//+------------------------------------------------------------------+
bool IsAllowedSymbol(const string symbol)
{
   string allowed = InpTradeSymbols;
   StringReplace(allowed, " ", "");

   string parts[];
   const int count = StringSplit(allowed, ',', parts);

   for(int i = 0; i < count; i++)
   {
      if(parts[i] == symbol)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Prevent multiple simultaneous positions for symbol and magic       |
//+------------------------------------------------------------------+
bool HasOpenPositionForSymbolAndMagic(const string symbol, const ulong magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      const string position_symbol = PositionGetString(POSITION_SYMBOL);
      const ulong position_magic = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(position_symbol == symbol && position_magic == magic)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Release all indicator handles                                     |
//+------------------------------------------------------------------+
void ReleaseIndicatorHandles()
{
   for(int tf = 0; tf < TF_COUNT; tf++)
   {
      for(int ma = 0; ma < TF_COUNT; ma++)
      {
         if(g_ma_handles[tf][ma] != INVALID_HANDLE)
         {
            IndicatorRelease(g_ma_handles[tf][ma]);
            g_ma_handles[tf][ma] = INVALID_HANDLE;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| End of file                                                       |
//+------------------------------------------------------------------+
