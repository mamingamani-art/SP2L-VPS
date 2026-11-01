#property copyright "Based on PythonTraderBot SP2L Advanced Optimized"
#property version   "1.00"
#property description "Advanced Optimized SP2L M5 port for MetaTrader 5 Strategy Tester"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M5;
input double InpLot = 0.01;
input double InpSpikeMultiplier = 1.5;
input int InpPriceGapPoints = 100;
input int InpMaxSLDistancePoints = 1000;
input double InpTakeProfitR = 1.0;
input bool InpUseEMAFilter = true;
input int InpEMAPeriod = 60;
input bool InpUseTrendFilter = true;
input int InpMaxOppositeMoves = 1;
input bool InpUseADXRising = true;
input int InpADXPeriod = 14;
input bool InpUseSecondEntry = true;
input double InpSecondEntryMultiplier = 2.0;
input ulong InpMagic = 8;
input ulong InpSecondMagic = 9;

CTrade trade;
int ema_handle = INVALID_HANDLE;
int adx_handle = INVALID_HANDLE;

bool pending_active = false;
int pending_direction = 0; // 1 BUY, -1 SELL
datetime pending_setup_time = 0;
double pending_sl = 0.0;
bool first_status = false;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   ema_handle = iMA(_Symbol, InpTimeframe, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   adx_handle = iADX(_Symbol, InpTimeframe, InpADXPeriod);
   if(ema_handle == INVALID_HANDLE || adx_handle == INVALID_HANDLE)
      return INIT_FAILED;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(ema_handle != INVALID_HANDLE)
      IndicatorRelease(ema_handle);
   if(adx_handle != INVALID_HANDLE)
      IndicatorRelease(adx_handle);
}

double NormalizeVolume(const double requested)
{
   const double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double max_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volume = MathMax(min_volume, MathMin(max_volume, requested));
   if(step > 0.0)
      volume = MathFloor(volume / step + 0.5) * step;
   return NormalizeDouble(volume, 2);
}

bool HasPositionMagic(const ulong magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == magic)
         return true;
   }
   return false;
}

bool HasOrderMagic(const ulong magic)
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == magic)
         return true;
   }
   return false;
}

void CancelPendingMagic(const ulong magic)
{
   trade.SetExpertMagicNumber(magic);
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == magic)
         trade.OrderDelete(ticket);
   }
   trade.SetExpertMagicNumber(InpMagic);
}

bool LoadRates(MqlRates &rates[], const int count = 600)
{
   ArraySetAsSeries(rates, true);
   const int copied = CopyRates(_Symbol, InpTimeframe, 0, count, rates);
   return copied >= MathMin(count, InpEMAPeriod + InpADXPeriod + 10);
}

bool BufferValue(const int handle, const int buffer, const int shift, double &value)
{
   double values[1];
   if(CopyBuffer(handle, buffer, shift, 1, values) != 1)
      return false;
   value = values[0];
   return MathIsValidNumber(value) && value != EMPTY_VALUE;
}

bool DetectBuySetup(const MqlRates &r[])
{
   const double gap = InpPriceGapPoints * _Point;
   const double spike_body = r[2].close - r[2].open;
   return (
      r[0].low < r[1].low &&
      r[1].close > r[2].close &&
      r[1].open > r[2].open &&
      r[2].close > r[3].close &&
      r[2].open > r[3].open &&
      r[1].close > r[1].open &&
      r[2].close > r[2].open &&
      r[3].close > r[3].open &&
      r[1].low > r[3].high + gap &&
      spike_body > InpSpikeMultiplier * (r[1].close - r[1].open) &&
      spike_body > InpSpikeMultiplier * (r[3].close - r[3].open) &&
      spike_body > InpSpikeMultiplier * (r[0].close - r[0].open)
   );
}

bool DetectSellSetup(const MqlRates &r[])
{
   const double gap = InpPriceGapPoints * _Point;
   const double spike_body = r[2].open - r[2].close;
   return (
      r[0].high > r[1].high &&
      r[1].close < r[2].close &&
      r[1].open < r[2].open &&
      r[2].close < r[3].close &&
      r[2].open < r[3].open &&
      r[1].close < r[1].open &&
      r[2].close < r[2].open &&
      r[3].close < r[3].open &&
      r[1].high < r[3].low - gap &&
      spike_body > InpSpikeMultiplier * (r[1].open - r[1].close) &&
      spike_body > InpSpikeMultiplier * (r[3].open - r[3].close) &&
      spike_body > InpSpikeMultiplier * (r[0].open - r[0].close)
   );
}

int FindSetupShift(const MqlRates &r[])
{
   for(int i = 0; i < ArraySize(r); ++i)
      if(r[i].time == pending_setup_time)
         return i;
   return -1;
}

bool TrendIsValid(const MqlRates &r[], const int direction)
{
   if(!InpUseTrendFilter)
      return true;

   const int start_shift = FindSetupShift(r);
   if(start_shift < 0)
      return false;

   int consecutive_opposite = 0;
   for(int i = start_shift - 1; i >= 0; --i)
   {
      const bool continues = direction == 1
         ? r[i].high > r[i + 1].high
         : r[i].low < r[i + 1].low;
      if(continues)
         consecutive_opposite = 0;
      else
      {
         consecutive_opposite++;
         if(consecutive_opposite > InpMaxOppositeMoves)
            return false;
      }
   }
   return true;
}

bool EntryFiltersValid(const MqlRates &r[], const int direction)
{
   if(InpUseEMAFilter)
   {
      double ema = 0.0;
      if(!BufferValue(ema_handle, 0, 0, ema))
         return false;
      if(direction == 1 && r[0].close <= ema)
         return false;
      if(direction == -1 && r[0].close >= ema)
         return false;
   }

   if(InpUseADXRising)
   {
      double current_closed_adx = 0.0;
      double previous_closed_adx = 0.0;
      if(!BufferValue(adx_handle, 0, 1, current_closed_adx) ||
         !BufferValue(adx_handle, 0, 2, previous_closed_adx))
         return false;
      if(current_closed_adx <= previous_closed_adx)
         return false;
   }
   return true;
}

bool StopsAreValid(const bool buy, const double entry, const double sl, const double tp)
{
   if(buy && !(sl < entry && tp > entry))
      return false;
   if(!buy && !(sl > entry && tp < entry))
      return false;
   const double min_distance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   return MathAbs(entry - sl) >= min_distance && MathAbs(tp - entry) >= min_distance;
}

void PlaceSecondEntry(const int direction, const double signal_entry, const double sl)
{
   if(!InpUseSecondEntry || HasPositionMagic(InpSecondMagic) || HasOrderMagic(InpSecondMagic))
      return;

   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double first_risk = MathAbs(signal_entry - sl);
   const double second_entry = direction == 1
      ? signal_entry - first_risk / 2.0
      : signal_entry + first_risk / 2.0;
   const double second_risk = MathAbs(second_entry - sl);
   const double second_tp = direction == 1
      ? second_entry + InpTakeProfitR * second_risk
      : second_entry - InpTakeProfitR * second_risk;
   const double volume = NormalizeVolume(InpLot * InpSecondEntryMultiplier);

   trade.SetExpertMagicNumber(InpSecondMagic);
   bool placed = false;
   if(direction == 1)
      placed = trade.BuyLimit(volume, NormalizeDouble(second_entry, digits), _Symbol,
                              NormalizeDouble(sl, digits), NormalizeDouble(second_tp, digits),
                              ORDER_TIME_GTC, 0, "SP2L Advanced Entry 2");
   else
      placed = trade.SellLimit(volume, NormalizeDouble(second_entry, digits), _Symbol,
                               NormalizeDouble(sl, digits), NormalizeDouble(second_tp, digits),
                               ORDER_TIME_GTC, 0, "SP2L Advanced Entry 2");
   if(!placed)
      PrintFormat("Second entry failed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   trade.SetExpertMagicNumber(InpMagic);
}

bool OpenFirstEntry(const int direction, const double signal_entry, const double sl)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double actual_entry = direction == 1 ? tick.ask : tick.bid;
   const double risk = direction == 1 ? actual_entry - sl : sl - actual_entry;
   if(risk <= 0.0 || risk > InpMaxSLDistancePoints * _Point)
      return false;
   const double tp = direction == 1
      ? actual_entry + InpTakeProfitR * risk
      : actual_entry - InpTakeProfitR * risk;
   if(!StopsAreValid(direction == 1, actual_entry, sl, tp))
      return false;

   trade.SetExpertMagicNumber(InpMagic);
   const double volume = NormalizeVolume(InpLot);
   const bool opened = direction == 1
      ? trade.Buy(volume, _Symbol, 0.0, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits), "SP2L Advanced BUY")
      : trade.Sell(volume, _Symbol, 0.0, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits), "SP2L Advanced SELL");

   if(opened)
   {
      first_status = true;
      PlaceSecondEntry(direction, signal_entry, sl);
   }
   else
      PrintFormat("First entry failed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return opened;
}

void OnTick()
{
   const bool first_exists = HasPositionMagic(InpMagic);
   if(first_status && !first_exists)
   {
      CancelPendingMagic(InpSecondMagic);
      first_status = false;
      pending_active = false;
   }
   else if(!first_status && first_exists)
      first_status = true;

   if(first_status)
      return;

   MqlRates rates[];
   if(!LoadRates(rates))
      return;

   if(pending_active)
   {
      const double trigger = pending_direction == 1 ? rates[0].low : rates[0].high;
      const bool triggered = pending_direction == 1
         ? rates[0].low < rates[1].low
         : rates[0].high > rates[1].high;

      if(triggered)
      {
         const double risk = pending_direction == 1 ? trigger - pending_sl : pending_sl - trigger;
         if(risk <= 0.0 || risk > InpMaxSLDistancePoints * _Point)
            pending_active = false;
         else if(TrendIsValid(rates, pending_direction) && EntryFiltersValid(rates, pending_direction))
         {
            const int direction = pending_direction;
            const double sl = pending_sl;
            pending_active = false;
            OpenFirstEntry(direction, trigger, sl);
            return;
         }
      }
   }

   if(!pending_active)
   {
      const bool buy = DetectBuySetup(rates);
      const bool sell = DetectSellSetup(rates);
      if(buy && !sell)
      {
         pending_active = true;
         pending_direction = 1;
         pending_setup_time = rates[0].time;
         pending_sl = rates[3].low;
      }
      else if(sell && !buy)
      {
         pending_active = true;
         pending_direction = -1;
         pending_setup_time = rates[0].time;
         pending_sl = rates[3].high;
      }
   }
}

