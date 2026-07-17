//+------------------------------------------------------------------+
//|                                                      MT5_Bot.mq5 |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>

input double RiskPercent = 2.0;
input int StopLossPoints = 500;
input int PartialPoint = 600;
input int TrailingPoint = 400;
input int MinTPDistance = 500;
input int SpreadFilter = 80;
input int MagicNumber = 202405;
input int CooldownSeconds = 300;

CTrade trade;
int atr_handle;
bool is_partial_closed = false;
datetime last_close_time = 0;
ulong current_ticket = 0;

//+------------------------------------------------------------------+
//| Khởi tạo EA                                                      |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(MagicNumber);
    atr_handle = iATR(_Symbol, PERIOD_M5, 14);
    if(atr_handle == INVALID_HANDLE) {
        Print("Lỗi tải ATR indicator");
        return INIT_FAILED;
    }
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Hàm gộp vùng cản (Merge Levels)                                  |
//+------------------------------------------------------------------+
void MergeLevels(double &levels[], double threshold=5.0) {
    int size = ArraySize(levels);
    if(size <= 1) return;
    ArraySort(levels);
    
    double merged[];
    ArrayResize(merged, size);
    int merged_count = 0;
    
    double current_cluster_sum = levels[0];
    int cluster_size = 1;
    double last_val = levels[0];
    
    for(int i=1; i<size; i++) {
        if(levels[i] - last_val < threshold) {
            current_cluster_sum += levels[i];
            cluster_size++;
            last_val = levels[i];
        } else {
            merged[merged_count++] = current_cluster_sum / cluster_size;
            current_cluster_sum = levels[i];
            cluster_size = 1;
            last_val = levels[i];
        }
    }
    merged[merged_count++] = current_cluster_sum / cluster_size;
    ArrayResize(merged, merged_count);
    ArrayCopy(levels, merged);
}

//+------------------------------------------------------------------+
//| Tính Lot Size                                                    |
//+------------------------------------------------------------------+
double CalculateLotSize(double risk_percent, double sl_points) {
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double value_per_point = tick_value / tick_size;
    
    double risk_amount = balance * (risk_percent / 100.0);
    double lot_size = risk_amount / (sl_points * value_per_point);
    
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    lot_size = MathFloor(lot_size / step_lot) * step_lot;
    if(lot_size < min_lot) return min_lot;
    return lot_size;
}

//+------------------------------------------------------------------+
//| Vòng lặp chính                                                   |
//+------------------------------------------------------------------+
void OnTick() {
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    
    // Quản lý trạng thái lệnh và Cooldown
    bool position_open = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) {
            position_open = true;
            current_ticket = ticket;
            
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl = PositionGetDouble(POSITION_SL);
            double tp = PositionGetDouble(POSITION_TP);
            double vol = PositionGetDouble(POSITION_VOLUME);
            long type = PositionGetInteger(POSITION_TYPE);
            
            double profit_points = 0;
            if(type == POSITION_TYPE_BUY) profit_points = (bid - open_price) / point;
            else if(type == POSITION_TYPE_SELL) profit_points = (open_price - ask) / point;
            
            // Partial Close 2/3
            if(profit_points >= PartialPoint && !is_partial_closed) {
                double lot_to_close = NormalizeDouble(vol * 2.0 / 3.0, 2);
                double remaining = NormalizeDouble(vol - lot_to_close, 2);
                if(lot_to_close >= 0.01 && remaining >= 0.01) {
                    if(trade.PositionClosePartial(ticket, lot_to_close)) {
                        is_partial_closed = true;
                    }
                }
            }
            
            // Trailing Stop Loss
            if(profit_points >= TrailingPoint) {
                double new_sl;
                if(type == POSITION_TYPE_BUY) {
                    new_sl = NormalizeDouble(bid - TrailingPoint * point, digits);
                    if(new_sl > sl + 50 * point) trade.PositionModify(ticket, new_sl, tp);
                } else if(type == POSITION_TYPE_SELL) {
                    new_sl = NormalizeDouble(ask + TrailingPoint * point, digits);
                    if(new_sl < sl - 50 * point || sl == 0) trade.PositionModify(ticket, new_sl, tp);
                }
            }
            return;
        }
    }
    
    if(!position_open && current_ticket != 0) {
        last_close_time = TimeCurrent();
        current_ticket = 0;
        is_partial_closed = false;
    }
    
    if(TimeCurrent() - last_close_time < CooldownSeconds) return;
    
    // Spread Filter
    double spread = (ask - bid) / point;
    if(spread > SpreadFilter) return;
    
    // Nạp dữ liệu giá
    double high[], low[], close[];
    double atr[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(atr, true);
    
    if(CopyHigh(_Symbol, PERIOD_M5, 0, 300, high) < 300) return;
    if(CopyLow(_Symbol, PERIOD_M5, 0, 300, low) < 300) return;
    if(CopyClose(_Symbol, PERIOD_M5, 0, 300, close) < 300) return;
    if(CopyBuffer(atr_handle, 0, 0, 1, atr) < 1) return;
    
    double prominence = atr[0] * 0.5;
    double current_price = close[0];
    
    double resistance[], support[];
    ArrayResize(resistance, 300);
    ArrayResize(support, 300);
    int res_count = 0, sup_count = 0;
    
    // Thuật toán tìm đỉnh/đáy mô phỏng scipy.signal.find_peaks
    for(int i = 12; i < 300 - 12; i++) {
        // Tìm Kháng cự
        bool is_peak = true;
        double min_low = low[i];
        for(int j = i - 12; j <= i + 12; j++) {
            if(high[j] > high[i] && j != i) { is_peak = false; break; }
            if(low[j] < min_low) min_low = low[j];
        }
        if(is_peak && (high[i] - min_low >= prominence)) {
            if(high[i] - current_price > 0 && high[i] - current_price < 50.0) {
                resistance[res_count++] = high[i];
            }
        }
        
        // Tìm Hỗ trợ
        bool is_valley = true;
        double max_high = high[i];
        for(int j = i - 12; j <= i + 12; j++) {
            if(low[j] < low[i] && j != i) { is_valley = false; break; }
            if(high[j] > max_high) max_high = high[j];
        }
        if(is_valley && (max_high - low[i] >= prominence)) {
            if(current_price - low[i] > 0 && current_price - low[i] < 50.0) {
                support[sup_count++] = low[i];
            }
        }
    }
    
    ArrayResize(resistance, res_count);
    ArrayResize(support, sup_count);
    
    MergeLevels(resistance, 5.0);
    MergeLevels(support, 5.0);
    
    if(ArraySize(resistance) == 0 || ArraySize(support) == 0) return;
    
    // Lọc mức giá vào lệnh và chốt lời
    double nearest_res_entry = DBL_MAX, nearest_sup_entry = -DBL_MAX;
    double nearest_res_tp = DBL_MAX, nearest_sup_tp = -DBL_MAX;
    
    for(int i = 0; i < ArraySize(resistance); i++) {
        if(resistance[i] > ask && resistance[i] < nearest_res_entry) nearest_res_entry = resistance[i];
        if(resistance[i] > ask + MinTPDistance * point && resistance[i] < nearest_res_tp) nearest_res_tp = resistance[i];
    }
    
    for(int i = 0; i < ArraySize(support); i++) {
        if(support[i] < bid && support[i] > nearest_sup_entry) nearest_sup_entry = support[i];
        if(support[i] < bid - MinTPDistance * point && support[i] > nearest_sup_tp) nearest_sup_tp = support[i];
    }
    
    double buffer_zone = 0.2;
    bool buy_signal = (nearest_sup_entry != -DBL_MAX && MathAbs(bid - nearest_sup_entry) <= buffer_zone);
    bool sell_signal = (nearest_res_entry != DBL_MAX && MathAbs(ask - nearest_res_entry) <= buffer_zone);
    
    if(buy_signal) {
        double sl_price = NormalizeDouble(ask - StopLossPoints * point, digits);
        double tp_price = (nearest_res_tp != DBL_MAX) ? nearest_res_tp - 0.5 : ask + (ask - sl_price) * 2.0;
        
        double actual_sl_points = (ask - sl_price) / point;
        double actual_tp_points = (tp_price - ask) / point;
        
        if(actual_tp_points >= actual_sl_points * 1.5) {
            double lot_size = CalculateLotSize(RiskPercent, actual_sl_points);
            trade.Buy(lot_size, _Symbol, ask, sl_price, tp_price, "MT5 Bot Order");
        }
    } 
    else if(sell_signal) {
        double sl_price = NormalizeDouble(bid + StopLossPoints * point, digits);
        double tp_price = (nearest_sup_tp != -DBL_MAX) ? nearest_sup_tp + 0.5 : bid - (sl_price - bid) * 2.0;
        
        double actual_sl_points = (sl_price - bid) / point;
        double actual_tp_points = (bid - tp_price) / point;
        
        if(actual_tp_points >= actual_sl_points * 1.5) {
            double lot_size = CalculateLotSize(RiskPercent, actual_sl_points);
            trade.Sell(lot_size, _Symbol, bid, sl_price, tp_price, "MT5 Bot Order");
        }
    }
}
//+------------------------------------------------------------------+