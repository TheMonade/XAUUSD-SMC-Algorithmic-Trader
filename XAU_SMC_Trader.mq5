//+------------------------------------------------------------------+
//|                                    XAU_SMC_Trader.mq5            |
//| Strategy: H1 Order Block + M5 CHoCH Entry                        |
//| FIXED VERSION, see change-log at bottom of file                  |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Indicators\Indicators.mqh>

input group "=== TRADE SETTINGS ==="
input double   RiskPercent      = 1.0;
input double   MinRR            = 1.5;
input int      MagicNumber      = 202405;

input group "=== ORDER BLOCK (H1) ==="
input int      OB_Lookback      = 100;
input int      OB_ATR_Period    = 15;
input double   OB_ATR_Mult      = 1.5;

input group "=== SL BUFFER (ATR-based, not fixed $) ==="
input double   SL_Buffer_ATR_Mult = 0.15;   // buffer = this * M5 ATR (was fixed $0.50)

input group "=== CHoCH (M5) ==="
input int      CHoCH_Lookback   = 100;
input int      ATR_Period_M5    = 14;
input double   CHoCH_Prom_Mult  = 0.5;
input int      Peak_Distance    = 5;

input group "=== POSITION MANAGEMENT (R-multiple based) ==="
input double   PartialAtR       = 1.0;   // start partial close once profit >= 1.0 x initial risk
input double   PartialClosePct  = 0.66;  // close 66% of volume at PartialAtR
input double   TrailingStartR   = 1.0;   // start trailing once profit >= 1.0 x initial risk
input double   TrailingStepR    = 1.0;   // Khoang cach trailing cach gia hien tai 1R
input double   TrailingBufferR  = 0.10;  // minimum improvement (in R) before re-modifying SL

input group "=== OVERTRADE / COOLDOWN CONTROL ==="
input int      MaxTradesPerDay      = 4;   // hard cap on new entries per calendar day
input int      MaxConsecutiveLosses = 2;   // after this many losses in a row, pause
input int      CooldownBarsH1       = 12;  // pause duration (H1 bars) after hitting loss streak
input double   ZoneProximityATRMult = 1.0; // block re-entry near a zone that just caused a loss
input int      ZoneCooldownBarsH1   = 24;  // how long (H1 bars) a losing zone stays blocked

input group "=== MISC ==="
input int      SpreadFilter     = 80;   // in points

CTrade         Trade;
CPositionInfo  PosInfo;

double         Point_val;
int            Digits_val;
bool           PartialDone      = false;
double         InitialVolume    = 0.0;
double         InitialSLDistance = 0.0;
double         LastTrailSL      = 0.0;
ulong          CurrentTicket    = 0;
ENUM_ORDER_TYPE_FILLING g_FillingMode      = ORDER_FILLING_FOK;
int                     g_FillingFallbacks = 0;

int            hATR_H1;
int            hATR_M5;

datetime       g_CurrentDay        = 0;
int            g_TradesToday       = 0;
int            g_ConsecutiveLosses = 0;
datetime       g_CooldownUntilBarTime = 0;

double         g_OpenZoneTop    = 0.0;
double         g_OpenZoneBottom = 0.0;
bool           g_HasOpenZone    = false;

struct LossZone
{
   double   top;
   double   bottom;
   datetime blockedUntilBarTime;
};
#define MAX_LOSS_ZONES 10
LossZone g_LossZones[MAX_LOSS_ZONES];
int      g_LossZoneCount = 0;

struct OBZone
{
   int    ob_type;
   double top;
   double bottom;
   datetime time_found;
};

struct CHoCHResult
{
   string choch_type;
   double smart_sl;
};

//+------------------------------------------------------------------+
int OnInit()
{
   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(30);
   
   g_FillingMode = ResolveFillingMode(_Symbol);
   Trade.SetTypeFilling(g_FillingMode);
   PrintFormat("[FEAT-P0-001] Filling mode selected: %s", EnumToString(g_FillingMode));

   Point_val  = _Point;
   Digits_val = _Digits;

   hATR_H1 = iATR(_Symbol, PERIOD_H1, OB_ATR_Period);
   hATR_M5 = iATR(_Symbol, PERIOD_M5, ATR_Period_M5);

   if(hATR_H1 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE)
   {
      Print("Init Failed: ATR handle error");
      return INIT_FAILED;
   }

   ZeroMemory(g_LossZones);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hATR_H1);
   IndicatorRelease(hATR_M5);
}

//+------------------------------------------------------------------+
bool IsMarketTradeable()
{
   long trade_mode = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(trade_mode == SYMBOL_TRADE_MODE_DISABLED || trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return false;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   datetime from, to;
   if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, 0, from, to))
      return false;

   return true;
}


//+------------------------------------------------------------------+
bool IsZoneBlocked(double top, double bottom)
{
   datetime nowBar = iTime(_Symbol, PERIOD_H1, 0);
   double atr_h1[];
   ArraySetAsSeries(atr_h1, true);
   double proximity = 0;
   if(CopyBuffer(hATR_H1, 0, 0, 1, atr_h1) > 0)
      proximity = atr_h1[0] * ZoneProximityATRMult;

   // Giới hạn vòng quét không vượt quá 10 phần tử
   int limit = MathMin(g_LossZoneCount, MAX_LOSS_ZONES);

   for(int i = 0; i < limit; i++)
   {
      if(g_LossZones[i].blockedUntilBarTime <= nowBar) continue;
      if(top >= g_LossZones[i].bottom - proximity && bottom <= g_LossZones[i].top + proximity)
         return true;
   }
   return false;
}

void RegisterLossZone(double top, double bottom)
{
   datetime nowBar = iTime(_Symbol, PERIOD_H1, 0);
   datetime blockUntil = nowBar + ZoneCooldownBarsH1 * PeriodSeconds(PERIOD_H1);

   int slot = g_LossZoneCount % MAX_LOSS_ZONES;
   g_LossZones[slot].top    = top;
   g_LossZones[slot].bottom = bottom;
   g_LossZones[slot].blockedUntilBarTime = blockUntil;
   g_LossZoneCount++;
}

//+------------------------------------------------------------------+
void UpdateDailyCounterIfNewDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   if(today != g_CurrentDay)
   {
      g_CurrentDay  = today;
      g_TradesToday = 0;
   }
}

bool InCooldown()
{
   datetime nowBar = iTime(_Symbol, PERIOD_H1, 0);
   return (nowBar < g_CooldownUntilBarTime);
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(profit < 0)
   {
      g_ConsecutiveLosses++;
      if(g_HasOpenZone)
         RegisterLossZone(g_OpenZoneTop, g_OpenZoneBottom);

      if(g_ConsecutiveLosses >= MaxConsecutiveLosses)
      {
         datetime nowBar = iTime(_Symbol, PERIOD_H1, 0);
         g_CooldownUntilBarTime = nowBar + CooldownBarsH1 * PeriodSeconds(PERIOD_H1);
         g_ConsecutiveLosses = 0;
      }
   }
   else if(profit > 0)
   {
      g_ConsecutiveLosses = 0;
   }

   if(!HasOpenPosition())
   {
      g_HasOpenZone     = false;
      PartialDone       = false;
      InitialVolume     = 0.0;
      InitialSLDistance = 0.0;
      LastTrailSL       = 0.0;
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   UpdateDailyCounterIfNewDay();

   if(HasOpenPosition())
   {
      ManagePosition();
      return;
   }

   static datetime LastBarTime = 0;
   datetime CurrBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(CurrBarTime == LastBarTime) return;
   LastBarTime = CurrBarTime;

   if(!IsMarketTradeable())          return;
   if(InCooldown())                  return;
   if(g_TradesToday >= MaxTradesPerDay) return;

   double Ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double Spread = (Ask - Bid) / Point_val;

   if(Spread > SpreadFilter) return;

   OBZone ob;
   if(!GetOB_H1(ob)) return;

   if(IsZoneBlocked(ob.top, ob.bottom)) return;

   CHoCHResult choch;
   if(!DetectCHoCH_M5(ob, choch)) return;

   double entry, sl_price, tp_price;
   ENUM_ORDER_TYPE order_type;

   double atr_m5[];
   ArraySetAsSeries(atr_m5, true);
   double atr_val = 0;
   if(CopyBuffer(hATR_M5, 0, 0, 1, atr_m5) > 0) atr_val = atr_m5[0];
   double sl_buffer = atr_val * SL_Buffer_ATR_Mult;

   if(ob.ob_type == 1) // BULLISH
   {
      entry      = Ask;
      sl_price   = NormalizeDouble(choch.smart_sl - sl_buffer, Digits_val);
      double sl_dist  = entry - sl_price;
      if(sl_dist <= 0) return;
      double min_tp   = NormalizeDouble(entry + sl_dist * MinRR, Digits_val);
      tp_price        = MathMax(ob.top, min_tp);
      order_type      = ORDER_TYPE_BUY;
   }
   else // BEARISH
   {
      entry      = Bid;
      sl_price   = NormalizeDouble(choch.smart_sl + sl_buffer, Digits_val);
      double sl_dist  = sl_price - entry;
      if(sl_dist <= 0) return;
      double min_tp   = NormalizeDouble(entry - sl_dist * MinRR, Digits_val);
      tp_price        = MathMin(ob.bottom, min_tp);
      order_type      = ORDER_TYPE_SELL;
   }

   double sl_points = MathAbs(entry - sl_price) / Point_val;
   double tp_points = MathAbs(tp_price - entry) / Point_val;

   if(sl_points <= 0) return;
   double actual_rr = tp_points / sl_points;
   if(actual_rr < MinRR) return;

   double lot = CalcLotSize(sl_points);
   if(lot < 0.01) return;

   bool placed = false;
   if(order_type == ORDER_TYPE_BUY)
      placed = SafeOrderSend(ORDER_TYPE_BUY, lot, entry, sl_price, tp_price, "SMC Bot - BUY");
   else
      placed = SafeOrderSend(ORDER_TYPE_SELL, lot, entry, sl_price, tp_price, "SMC Bot - SELL");

   if(placed)
   {
      CurrentTicket     = Trade.ResultOrder();
      InitialVolume     = lot;
      InitialSLDistance = MathAbs(entry - sl_price);
      PartialDone       = false;
      LastTrailSL       = 0.0;

      g_OpenZoneTop    = ob.top;
      g_OpenZoneBottom = ob.bottom;
      g_HasOpenZone    = true;

      g_TradesToday++;
   }
}

//+------------------------------------------------------------------+
bool GetOB_H1(OBZone &ob)
{
   int    bars    = OB_Lookback + 2;
   double atr_h1[];
   double high_h1[], low_h1[], open_h1[], close_h1[];

   ArraySetAsSeries(atr_h1,   true);
   ArraySetAsSeries(high_h1,  true);
   ArraySetAsSeries(low_h1,   true);
   ArraySetAsSeries(open_h1,  true);
   ArraySetAsSeries(close_h1, true);

   if(CopyBuffer(hATR_H1,  0, 0, bars, atr_h1)   < bars) return false;
   if(CopyHigh(_Symbol,  PERIOD_H1, 0, bars, high_h1)  < bars) return false;
   if(CopyLow(_Symbol,   PERIOD_H1, 0, bars, low_h1)   < bars) return false;
   if(CopyOpen(_Symbol,  PERIOD_H1, 0, bars, open_h1)  < bars) return false;
   if(CopyClose(_Symbol, PERIOD_H1, 0, bars, close_h1) < bars) return false;

   for(int i = 1; i < OB_Lookback - 1; i++)
   {
      if(atr_h1[i] <= 0) continue;
      double body_size = MathAbs(close_h1[i] - open_h1[i]);

      if(close_h1[i] > open_h1[i] && body_size > atr_h1[i] * OB_ATR_Mult)
      {
         if(close_h1[i+1] < open_h1[i+1])
         {
            double ob_top    = high_h1[i+1];
            double ob_bottom = low_h1[i+1];

            bool is_valid = true;
            for(int j = i; j >= 1; j--) {
               if(close_h1[j] < ob_bottom) { is_valid = false; break; }
            }

            if(is_valid)
            {
               ob.ob_type    = 1;
               ob.top        = ob_top;
               ob.bottom     = ob_bottom;
               ob.time_found = iTime(_Symbol, PERIOD_H1, i+1);
               return true;
            }
         }
      }

      if(close_h1[i] < open_h1[i] && body_size > atr_h1[i] * OB_ATR_Mult)
      {
         if(close_h1[i+1] > open_h1[i+1])
         {
            double ob_top    = high_h1[i+1];
            double ob_bottom = low_h1[i+1];

            bool is_valid = true;
            for(int j = i; j >= 1; j--) {
               if(close_h1[j] > ob_top) { is_valid = false; break; }
            }

            if(is_valid)
            {
               ob.ob_type    = -1;
               ob.top        = ob_top;
               ob.bottom     = ob_bottom;
               ob.time_found = iTime(_Symbol, PERIOD_H1, i+1);
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
bool DetectCHoCH_M5(const OBZone &ob, CHoCHResult &result)
{
   int bars = CHoCH_Lookback + 3;
   double atr_m5[];
   double high_m5[], low_m5[], close_m5[];

   ArraySetAsSeries(atr_m5,   true);
   ArraySetAsSeries(high_m5,  true);
   ArraySetAsSeries(low_m5,   true);
   ArraySetAsSeries(close_m5, true);

   if(CopyBuffer(hATR_M5,  0, 0, bars, atr_m5)   < bars) return false;
   if(CopyHigh(_Symbol,  PERIOD_M5, 0, bars, high_m5)  < bars) return false;
   if(CopyLow(_Symbol,   PERIOD_M5, 0, bars, low_m5)   < bars) return false;
   if(CopyClose(_Symbol, PERIOD_M5, 0, bars, close_m5) < bars) return false;

   double atr_val = atr_m5[1];
   if(atr_val <= 0) return false;

   if(ob.ob_type == 1)
   {
      bool has_touch = false;
      for(int i = 1; i < CHoCH_Lookback; i++)
      {
         if(low_m5[i] <= ob.top && low_m5[i] >= ob.bottom)
         {
            has_touch = true;
            break;
         }
      }
      if(!has_touch) return false;

      int    last_peak_idx   = -1;
      double last_swing_high = 0;
      double prominence      = atr_val * CHoCH_Prom_Mult;

      for(int i = Peak_Distance; i < CHoCH_Lookback - Peak_Distance; i++)
      {
         if(IsPeak(high_m5, i, Peak_Distance, prominence))
         {
            last_peak_idx   = i;
            last_swing_high = high_m5[i];
            break;
         }
      }

      if(last_peak_idx < 0) return false;

      if(close_m5[1] > last_swing_high && close_m5[2] <= last_swing_high)
      {
         double lowest_low = low_m5[last_peak_idx];
         for(int i = 1; i <= last_peak_idx; i++)
            if(low_m5[i] < lowest_low) lowest_low = low_m5[i];

         if(lowest_low > ob.top) return false;

         result.choch_type = "Bullish CHoCH";
         result.smart_sl   = lowest_low;
         return true;
      }
   }
   else if(ob.ob_type == -1)
   {
      bool has_touch = false;
      for(int i = 1; i < CHoCH_Lookback; i++)
      {
         if(high_m5[i] >= ob.bottom && high_m5[i] <= ob.top)
         {
            has_touch = true;
            break;
         }
      }
      if(!has_touch) return false;

      int    last_trough_idx = -1;
      double last_swing_low  = DBL_MAX;
      double prominence      = atr_val * CHoCH_Prom_Mult;

      for(int i = Peak_Distance; i < CHoCH_Lookback - Peak_Distance; i++)
      {
         if(IsTrough(low_m5, i, Peak_Distance, prominence))
         {
            last_trough_idx = i;
            last_swing_low  = low_m5[i];
            break;
         }
      }

      if(last_trough_idx < 0) return false;

      if(close_m5[1] < last_swing_low && close_m5[2] >= last_swing_low)
      {
         double highest_high = high_m5[last_trough_idx];
         for(int i = 1; i <= last_trough_idx; i++)
            if(high_m5[i] > highest_high) highest_high = high_m5[i];

         if(highest_high < ob.bottom) return false;

         result.choch_type = "Bearish CHoCH";
         result.smart_sl   = highest_high;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsPeak(const double &high[], int idx, int dist, double prominence)
{
   double center = high[idx];
   for(int d = 1; d <= dist; d++)
   {
      if(idx - d < 0 || idx + d >= ArraySize(high)) return false;
      if(high[idx-d] >= center) return false;
      if(high[idx+d] >= center) return false;
   }
   double left_min  = center, right_min = center;
   for(int d = 1; d <= dist * 2; d++)
   {
      if(idx + d < ArraySize(high)) left_min  = MathMin(left_min,  high[idx+d]);
      if(idx - d >= 0)              right_min = MathMin(right_min, high[idx-d]);
   }
   return (center - MathMax(left_min, right_min)) >= prominence;
}

//+------------------------------------------------------------------+
bool IsTrough(const double &low[], int idx, int dist, double prominence)
{
   double center = low[idx];
   for(int d = 1; d <= dist; d++)
   {
      if(idx - d < 0 || idx + d >= ArraySize(low)) return false;
      if(low[idx-d] <= center) return false;
      if(low[idx+d] <= center) return false;
   }
   double left_max  = center, right_max = center;
   for(int d = 1; d <= dist * 2; d++)
   {
      if(idx + d < ArraySize(low)) left_max  = MathMax(left_max,  low[idx+d]);
      if(idx - d >= 0)             right_max = MathMax(right_max, low[idx-d]);
   }
   return (MathMin(left_max, right_max) - center) >= prominence;
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(PosInfo.SelectByIndex(i))
      {
         if(PosInfo.Symbol() == _Symbol && PosInfo.Magic() == MagicNumber)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
bool GetOpenPosition(ulong &ticket, double &open_price, double &current_sl,
                     double &tp, double &volume, ENUM_POSITION_TYPE &pos_type)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(PosInfo.SelectByIndex(i))
      {
         if(PosInfo.Symbol() == _Symbol && PosInfo.Magic() == MagicNumber)
         {
            ticket      = PosInfo.Ticket();
            open_price  = PosInfo.PriceOpen();
            current_sl  = PosInfo.StopLoss();
            tp          = PosInfo.TakeProfit();
            volume      = PosInfo.Volume();
            pos_type    = PosInfo.PositionType();
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
void ManagePosition()
{
   ulong                ticket;
   double               open_price, current_sl, tp, volume;
   ENUM_POSITION_TYPE   pos_type;

   if(!GetOpenPosition(ticket, open_price, current_sl, tp, volume, pos_type))
      return;

   if(InitialVolume == 0.0) InitialVolume = volume;
   if(InitialSLDistance <= 0.0)
   {
      if(current_sl > 0) InitialSLDistance = MathAbs(open_price - current_sl);
      else return;
   }

   if(!IsMarketTradeable()) return;

   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double profit_price   = (pos_type == POSITION_TYPE_BUY) ? (Bid - open_price) : (open_price - Ask);
   double profit_R        = profit_price / InitialSLDistance;

   if(!PartialDone && profit_R >= PartialAtR)
   {
      double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      double lot_to_close = MathFloor((volume * PartialClosePct) / lot_step) * lot_step;
      double remaining = volume - lot_to_close;

      if(lot_to_close >= lot_min && remaining >= lot_min)
      {
         if(Trade.PositionClosePartial(ticket, lot_to_close))
         {
            PartialDone = true;
         }
         else if(Trade.ResultRetcode() == TRADE_RETCODE_INVALID_FILL)
         {
            if(FallbackFillingMode())
            {
               if(Trade.PositionClosePartial(ticket, lot_to_close))
               {
                  PartialDone = true;
               }
               else
               {
                  PrintFormat("[FEAT-P0-001] Retry partial close failed, retcode: %d, comment: %s", Trade.ResultRetcode(), Trade.ResultComment());
               }
            }
            else
            {
               PrintFormat("[FEAT-P0-001] FATAL: All filling modes failed for partial close");
            }
         }
         else
         {
            PrintFormat("[FEAT-P0-001] PositionClosePartial failed, retcode: %d, comment: %s", Trade.ResultRetcode(), Trade.ResultComment());
         }
      }
      else
      {
         PartialDone = true;
      }
   }

   if(profit_R >= TrailingStartR)
   {
      if(!GetOpenPosition(ticket, open_price, current_sl, tp, volume, pos_type))
         return;

      double trail_distance_price = InitialSLDistance * TrailingStepR;
      double buffer_price         = InitialSLDistance * TrailingBufferR;
      double new_sl = 0;
      bool   should_modify = false;

      if(pos_type == POSITION_TYPE_BUY)
      {
         new_sl = NormalizeDouble(Bid - trail_distance_price, Digits_val);
         if(current_sl == 0 || new_sl > current_sl + buffer_price)
            should_modify = true;
      }
      else if(pos_type == POSITION_TYPE_SELL)
      {
         new_sl = NormalizeDouble(Ask + trail_distance_price, Digits_val);
         if(current_sl == 0 || new_sl < current_sl - buffer_price)
            should_modify = true;
      }

      if(should_modify && MathAbs(new_sl - LastTrailSL) > Point_val)
      {
         if(Trade.PositionModify(ticket, new_sl, tp))
            LastTrailSL = new_sl;
      }
   }
}

//+------------------------------------------------------------------+
double CalcLotSize(double sl_points)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amt   = balance * (RiskPercent / 100.0);
   double tick_val   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double value_per_point = tick_val / (tick_size / Point_val);

   if(value_per_point <= 0 || sl_points <= 0) return 0.01;

   double lot = risk_amt / (sl_points * value_per_point);

   double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / lot_step) * lot_step;
   return MathMax(lot_min, MathMin(lot_max, lot));
}

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING ResolveFillingMode(const string symbol)
{
   long mask = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   long exemode = SymbolInfoInteger(symbol, SYMBOL_TRADE_EXEMODE);
   if((mask & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((mask & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   if(exemode == SYMBOL_TRADE_EXECUTION_EXCHANGE || exemode == SYMBOL_TRADE_EXECUTION_REQUEST || exemode == SYMBOL_TRADE_EXECUTION_INSTANT) return ORDER_FILLING_RETURN;
   return ORDER_FILLING_FOK;
}

//+------------------------------------------------------------------+
bool FallbackFillingMode()
{
   if(g_FillingMode == ORDER_FILLING_FOK)
      g_FillingMode = ORDER_FILLING_IOC;
   else if(g_FillingMode == ORDER_FILLING_IOC)
      g_FillingMode = ORDER_FILLING_RETURN;
   else
      return false;

   g_FillingFallbacks++;
   Trade.SetTypeFilling(g_FillingMode);
   PrintFormat("[FEAT-P0-001] Fallback filling mode selected: %s", EnumToString(g_FillingMode));
   return true;
}

//+------------------------------------------------------------------+
bool SafeOrderSend(const ENUM_ORDER_TYPE type, const double lot,
                   const double price, const double sl, const double tp,
                   const string comment)
{
   int MAX_RETRY = 2;
   for(int i = 0; i <= MAX_RETRY; i++)
   {
      bool placed = false;
      if(type == ORDER_TYPE_BUY)
         placed = Trade.Buy(lot, _Symbol, price, sl, tp, comment);
      else
         placed = Trade.Sell(lot, _Symbol, price, sl, tp, comment);

      uint retcode = Trade.ResultRetcode();
      if(placed && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
         return true;

      if(retcode == TRADE_RETCODE_INVALID_FILL)
      {
         if(!FallbackFillingMode())
         {
            PrintFormat("[FEAT-P0-001] FATAL: All filling modes failed for retcode 10030");
            return false;
         }
         continue;
      }

      PrintFormat("[FEAT-P0-001] Order failed with retcode: %d, comment: %s", retcode, Trade.ResultComment());
      return false;
   }
   return false;
}

// [FEAT-P0-001] Auto Filling Mode Detection: FOK->IOC->RETURN, runtime fallback on retcode 10030