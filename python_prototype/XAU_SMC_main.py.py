# ============================================================ #
# XAU SMC Trader
# Strategy: H1 Order Block + M5 CHoCH Entry
# ============================================================ #
# 1.  Account config
# 2.  save_log
# 3.  connect_mt5
# 4.  get_price
# 5.  get_filling_mode
# 6.  place_order
# 7.  modify_order
# 8.  calculate_lot_size
# 9.  partial_close
# 10. check_open_orders
# 11. get_OB_H1          ← SMC: tìm Order Block trên H1
# 12. detect_m5_choch    ← SMC: xác nhận CHoCH trên M5
# 13. Main loop
#     13.1 Position management (partial close + trailing stop)
#     13.2 Trading logic (OB + CHoCH → entry)
# ============================================================ #

import math
from scipy.signal import find_peaks
import MetaTrader5 as mt5
import time
from datetime import datetime
import pandas as pd
import pandas_ta as ta

# ── 1. Account config ─────────────────────────────────────── #
tai_khoan      = 1039291
mat_khau       = "V!tubersbevib1"
server_ten     = "VTMarkets-Demo"
bot_magic_number = 202405
symbol         = "XAUUSD-VIP"
spread_filter  = 500   # bỏ qua nếu spread > 80 points (news)

print(f"Bot đã nạp Symbol: {symbol}")

# ── 2. save_log ───────────────────────────────────────────── #
def save_log(message):
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(r"C:\Users\Admin\Desktop\MT5 Bot Testing\market_log2.txt", "a", encoding="utf-8") as f:
        f.write(f"[{now}] | {message}\n")

# ── 3. connect_mt5 ────────────────────────────────────────── #
def connect_mt5(id, pw, server):
    if not mt5.initialize():
        print("Không thể khởi động MT5")
        return False
    authorized = mt5.login(id, password=pw, server=server)
    if authorized:
        account_info = mt5.account_info()
        print(f"Kết nối thành công! Số dư: {account_info.balance} {account_info.currency}")
        return True
    else:
        print(f"Đăng nhập thất bại. Lỗi: {mt5.last_error()}")
        return False

# ── 4. get_price ──────────────────────────────────────────── #
def get_price(symbol):
    tick = mt5.symbol_info_tick(symbol)
    if tick is not None:
        return tick.bid, tick.ask
    print(f"Không thể lấy giá cho {symbol}")
    return None, None

# ── 5. get_filling_mode ───────────────────────────────────── #
def get_filling_mode(symbol):
    info = mt5.symbol_info(symbol)
    if info is None:
        return mt5.ORDER_FILLING_RETURN
    filling_type = info.filling_mode
    # bitmask: bit0=FOK(1), bit1=IOC(2), bit2=RETURN(4)
    if filling_type & 4:
        return mt5.ORDER_FILLING_RETURN
    elif filling_type & 2:
        return mt5.ORDER_FILLING_IOC
    elif filling_type & 1:
        return mt5.ORDER_FILLING_FOK
    return mt5.ORDER_FILLING_RETURN

# ── 6. place_order ────────────────────────────────────────── #
def place_order(symbol, volume, order_type, price, sl, tp):
    request = {
        'action':       mt5.TRADE_ACTION_DEAL,
        'symbol':       symbol,
        'volume':       float(volume),
        'type':         order_type,
        'price':        price,
        'sl':           float(sl),
        'tp':           float(tp),
        'magic':        bot_magic_number,
        'comment':      'SMC Bot Order',
        'type_time':    mt5.ORDER_TIME_GTC,
        'type_filling': get_filling_mode(symbol),
    }
    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        msg = f"Lỗi khi đặt lệnh: {result.retcode}"
        print(msg); save_log(msg)
    else:
        msg = f"Lệnh đặt thành công: {result}"
        print(msg); save_log(msg)
    return result

# ── 7. modify_order ───────────────────────────────────────── #
def modify_order(ticket, new_sl, new_tp):
    pos_list = mt5.positions_get(ticket=ticket)
    if not pos_list:
        save_log(f"Không tìm thấy position {ticket} để sửa SL/TP")
        return False
    pos = pos_list[0]
    request = {
        'action':   mt5.TRADE_ACTION_SLTP,
        'symbol':   pos.symbol,
        'position': ticket,
        'sl':       float(new_sl),
        'tp':       float(new_tp),
    }
    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        msg = f"Lỗi khi sửa lệnh: {result.retcode}"
        print(msg); save_log(msg)
        return False
    msg = f"Lệnh sửa thành công: ticket={ticket} SL={new_sl} TP={new_tp}"
    print(msg); save_log(msg)
    return True

# ── 8. calculate_lot_size ─────────────────────────────────── #
def calculate_lot_size(symbol, account_balance, risk_percent, stop_loss_points):
    symbol_info    = mt5.symbol_info(symbol)
    tick_value     = symbol_info.trade_tick_value
    tick_size      = symbol_info.trade_tick_size
    value_per_point = tick_value / tick_size
    risk_amount    = account_balance * (risk_percent / 100)
    lot_size       = risk_amount / (stop_loss_points * value_per_point)
    lot_size       = max(0.01, math.floor(lot_size * 100) / 100)
    return lot_size

# ── 9. partial_close ──────────────────────────────────────── #
def partial_close(ticket, symbol, lot_to_close, order_type):
    close_type = mt5.ORDER_TYPE_SELL if order_type == mt5.ORDER_TYPE_BUY else mt5.ORDER_TYPE_BUY
    tick  = mt5.symbol_info_tick(symbol)
    price = tick.bid if order_type == mt5.ORDER_TYPE_BUY else tick.ask
    request = {
        'action':       mt5.TRADE_ACTION_DEAL,
        'symbol':       symbol,
        'volume':       float(lot_to_close),
        'type':         close_type,
        'position':     ticket,
        'price':        price,
        'magic':        bot_magic_number,
        'comment':      'Partial Close SMC',
        'type_time':    mt5.ORDER_TIME_GTC,
        'type_filling': get_filling_mode(symbol),
    }
    return mt5.order_send(request)

# ── 10. check_open_orders ─────────────────────────────────── #
def check_open_orders(symbol):
    positions = mt5.positions_get(symbol=symbol)
    if positions:
        for p in positions:
            if p.magic == bot_magic_number:
                return p
    return None

# ── 11. get_OB_H1 ─────────────────────────────────────────── #
# Quét 100 nến H1, tìm Order Block gần nhất còn hiệu lực.
# OB Bullish : nến đỏ [i-1] ngay trước nến xanh Marubozu [i]
# OB Bearish : nến xanh [i-1] ngay trước nến đỏ Marubozu [i]
def get_OB_H1(symbol):
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_H1, 0, 100)
    if rates is None:
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df['ATR']  = ta.atr(df['high'], df['low'], df['close'], length=15)
    current_price = df['close'].iloc[-1]

    for i in range(len(df) - 2, 14, -1):
        body_size = abs(df['close'].iloc[i] - df['open'].iloc[i])
        atr_i     = df['ATR'].iloc[i]

        # ── Bullish OB ──
        if df['close'].iloc[i] > df['open'].iloc[i] and body_size > atr_i * 1.5:
            if df['close'].iloc[i-1] < df['open'].iloc[i-1]:   # nến trước đỏ
                ob_top    = df['high'].iloc[i-1]
                ob_bottom = df['low'].iloc[i-1]
                if ob_bottom < current_price < ob_top:          # giá còn trong vùng
                    return {
                        'type':       'BULLISH',
                        'top':        ob_top,
                        'bottom':     ob_bottom,
                        'time_found': df['time'].iloc[i-1],
                    }

        # ── Bearish OB ──
        if df['close'].iloc[i] < df['open'].iloc[i] and body_size > atr_i * 1.5:
            if df['close'].iloc[i-1] > df['open'].iloc[i-1]:   # nến trước xanh
                ob_top    = df['high'].iloc[i-1]
                ob_bottom = df['low'].iloc[i-1]
                if ob_bottom < current_price < ob_top:          # giá còn trong vùng
                    return {
                        'type':       'BEARISH',
                        'top':        ob_top,
                        'bottom':     ob_bottom,
                        'time_found': df['time'].iloc[i-1],
                    }
    return None

# ── 12. detect_m5_choch ───────────────────────────────────── #
# Sau khi có OB H1, xác nhận CHoCH trên M5:
#   - Giá đã chạm vào vùng OB (touch)
#   - Sau khi touch, giá phá vỡ swing high/low gần nhất (CHoCH)
# Trả về: (bool, choch_type, smart_sl)
def detect_m5_choch(symbol, ob_zone):
    if not ob_zone:
        return False, None, None
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M5, 0, 100)
    if rates is None:
        return False, None, None

    df = pd.DataFrame(rates)
    df['ATR']     = ta.atr(df['high'], df['low'], df['close'], length=14)
    atr_m5        = df['ATR'].iloc[-1]
    current_close = df['close'].iloc[-1]

    if ob_zone['type'] == 'BULLISH':
        recent_lows  = df['low'].iloc[-100:]
        has_touched_ob = (
            (recent_lows <= ob_zone['top']).any() and
            (recent_lows >= ob_zone['bottom']).any()
        )
        if has_touched_ob:
            highs = df['high'].values
            peaks, _ = find_peaks(highs, distance=5, prominence=atr_m5 * 0.5)
            if len(peaks) > 0:
                last_peak_idx   = peaks[-1]
                last_swing_high = df['high'].iloc[last_peak_idx]
                # Smart SL = lowest low sau khi swing high hình thành
                lowest_low_in_zone = df['low'].iloc[last_peak_idx:].min()
                if current_close > last_swing_high:
                    return True, "Bullish CHoCH", lowest_low_in_zone

    elif ob_zone['type'] == 'BEARISH':
        recent_highs = df['high'].iloc[-100:]
        has_touched_ob = (
            (recent_highs >= ob_zone['bottom']).any() and
            (recent_highs <= ob_zone['top']).any()
        )
        if has_touched_ob:
            lows_inverted = -df['low'].values
            troughs, _ = find_peaks(lows_inverted, distance=5, prominence=atr_m5 * 0.5)
            if len(troughs) > 0:
                last_trough_idx    = troughs[-1]
                last_swing_low     = df['low'].iloc[last_trough_idx]
                # Smart SL = highest high sau khi swing low hình thành
                highest_high_in_zone = df['high'].iloc[last_trough_idx:].max()
                if current_close < last_swing_low:
                    return True, "Bearish CHoCH", highest_high_in_zone

    return False, None, None

# ═══════════════════════════════════════════════════════════ #
# ── 13. Main loop ─────────────────────────────────────────── #
# ═══════════════════════════════════════════════════════════ #
initial_volume  = 0.0
trailing_point  = 400   # points để bắt đầu trailing stop
partial_point   = 600   # points để đóng 2/3
risk_percent    = 1.0   # % tài khoản risk mỗi lệnh
min_rr          = 1.5   # R:R tối thiểu để vào lệnh

try:
    if not connect_mt5(tai_khoan, mat_khau, server_ten):
        raise SystemExit("Không thể kết nối MT5")

    print("Bot SMC đang sẵn sàng...")
    if not mt5.symbol_select(symbol, True):
        raise SystemExit("Không thể select symbol")

    symbol_info = mt5.symbol_info(symbol)
    point       = symbol_info.point
    digits      = symbol_info.digits

    while True:
        # ── Lấy giá ──────────────────────────────────────────
        bid, ask = get_price(symbol)
        if bid is None or ask is None:
            print("Không lấy được giá, thử lại sau...")
            time.sleep(5)
            continue

        # ── Spread filter ─────────────────────────────────────
        spread = (ask - bid) / point
        if spread > spread_filter:
            print(f"Spread {spread:.1f} > {spread_filter} pts, bỏ qua (news).")
            time.sleep(5)
            continue

        # ════════════════════════════════════════════════════ #
        # 13.1  POSITION MANAGEMENT (khi đang có lệnh mở)     #
        # ════════════════════════════════════════════════════ #
        open_position = check_open_orders(symbol)
        if open_position is not None:
            pos_list = mt5.positions_get(ticket=open_position.ticket)
            if not pos_list:
                # Lệnh vừa đóng hoàn toàn (hit TP/SL)
                initial_volume = 0.0
                time.sleep(5)
                continue

            pos        = pos_list[0]
            ticket     = pos.ticket
            open_price = pos.price_open
            tp         = pos.tp if pos.tp != 0.0 else 0.0
            current_sl = pos.sl if pos.sl != 0.0 else (
                open_price - 500 * point if pos.type == mt5.ORDER_TYPE_BUY
                else open_price + 500 * point
            )

            # Track initial volume để detect partial close
            if initial_volume == 0.0 or pos.volume > initial_volume:
                initial_volume = pos.volume

            # Tính profit hiện tại (points)
            if pos.type == mt5.ORDER_TYPE_BUY:
                profit_points = (bid - open_price) / point
            elif pos.type == mt5.ORDER_TYPE_SELL:
                profit_points = (open_price - ask) / point
            else:
                profit_points = 0.0

            # ── 13.1a  Partial close 2/3 khi đủ partial_point ──
            if profit_points >= partial_point and pos.volume == initial_volume:
                lot_to_close = round(pos.volume * 2 / 3, 2)
                if lot_to_close >= 0.01:
                    result = partial_close(ticket, symbol, lot_to_close, pos.type)
                    if result.retcode == mt5.TRADE_RETCODE_DONE:
                        msg = f"Đóng 2/3 lệnh {ticket} | lot={lot_to_close} | profit={profit_points:.0f} pts"
                        print(msg); save_log(msg)
                    else:
                        print(f"Lỗi partial close: {result.retcode}")

            # ── 13.1b  Trailing stop khi đủ trailing_point ──────
            if profit_points >= trailing_point:
                # Refresh pos sau partial close
                pos_list2 = mt5.positions_get(ticket=ticket)
                if not pos_list2:
                    # Lệnh đã đóng hoàn toàn
                    initial_volume = 0.0
                    time.sleep(5)
                    continue
                pos        = pos_list2[0]
                current_sl = pos.sl   # SL thực tế mới nhất từ MT5
                tp         = pos.tp if pos.tp != 0.0 else tp

                current_price = bid if pos.type == mt5.ORDER_TYPE_BUY else ask

                if pos.type == mt5.ORDER_TYPE_BUY:
                    new_sl = round(current_price - trailing_point * point, 2)
                    if current_sl != 0.0 and new_sl > current_sl + 50 * point:
                        if modify_order(ticket, new_sl, tp):
                            save_log(f"Trail BUY {ticket}: SL {current_sl} → {new_sl}")

                elif pos.type == mt5.ORDER_TYPE_SELL:
                    new_sl = round(current_price + trailing_point * point, 2)
                    if current_sl != 0.0 and new_sl < current_sl - 50 * point:
                        if modify_order(ticket, new_sl, tp):
                            save_log(f"Trail SELL {ticket}: SL {current_sl} → {new_sl}")

            time.sleep(10)
            continue

        # ════════════════════════════════════════════════════ #
        # 13.2  TRADING LOGIC (khi chưa có lệnh)              #
        # Flow: tìm OB H1 → xác nhận CHoCH M5 → vào lệnh     #
        # ════════════════════════════════════════════════════ #
        initial_volume = 0.0  # reset khi không có lệnh

        ob_zone = get_OB_H1(symbol)
        if not ob_zone:
            print("Không tìm thấy OB zone nào trên H1.")
            time.sleep(5)
            continue

        print(f"OB zone tìm thấy: {ob_zone['type']} | {ob_zone['bottom']:.2f} – {ob_zone['top']:.2f} | từ {ob_zone['time_found']}")

        is_choch, choch_type, smart_sl = detect_m5_choch(symbol, ob_zone)
        if not is_choch:
            print(f"OB {ob_zone['type']} tồn tại nhưng chưa có CHoCH xác nhận.")
            time.sleep(5)
            continue

        save_log(f"Phát hiện {choch_type} | OB từ {ob_zone['time_found']} | Smart SL: {smart_sl:.2f}")

        # ── Tính SL, TP, lot ─────────────────────────────────
        if ob_zone['type'] == 'BULLISH':
            if not (ob_zone ['bottom'] < ask < ob_zone['top']):
                print("Giá đã thoát khỏi OB zone, bỏ qua.")
                time.sleep(5)
                continue
            # Entry: ask (market buy)
            # SL   : smart_sl từ CHoCH (lowest low sau swing high)
            # TP   : đỉnh OB H1 hoặc R:R tối thiểu
            entry       = ask
            sl_price    = round(smart_sl - 0.5, 2)          # thêm buffer nhỏ dưới smart SL
            min_tp      = round(entry + (entry - sl_price) * min_rr, 2)
            tp_price    = max(ob_zone['top'], min_tp)        # TP ít nhất bằng đỉnh OB
            order_type  = mt5.ORDER_TYPE_BUY

        else:  # BEARISH
            if not (ob_zone ['bottom'] < bid < ob_zone['top']):
                print("Giá đã thoát khỏi OB zone, bỏ qua.")
                time.sleep(5)
                continue
            entry       = bid
            sl_price    = round(smart_sl + 0.5, 2)          # buffer trên smart SL
            min_tp      = round(entry - (sl_price - entry) * min_rr, 2)
            tp_price    = min(ob_zone['bottom'], min_tp)     # TP ít nhất bằng đáy OB
            order_type  = mt5.ORDER_TYPE_SELL

        sl_points  = abs(entry - sl_price) / point
        tp_points  = abs(tp_price - entry) / point

        # ── Kiểm tra R:R ─────────────────────────────────────
        if sl_points <= 0:
            print("SL distance = 0, bỏ qua.")
            time.sleep(5)
            continue

        actual_rr = tp_points / sl_points
        if actual_rr < min_rr:
            print(f"R:R {actual_rr:.2f} < {min_rr}, bỏ qua tín hiệu.")
            time.sleep(5)
            continue

        # ── Tính lot size ─────────────────────────────────────
        balance  = mt5.account_info().balance
        lot_size = calculate_lot_size(symbol, balance, risk_percent, sl_points)

        # ── Đặt lệnh ─────────────────────────────────────────
        result = place_order(symbol, lot_size, order_type, entry, sl_price, tp_price)
        if result.retcode == mt5.TRADE_RETCODE_DONE:
            msg = (
                f"{choch_type} | Entry={entry:.2f} | SL={sl_price:.2f} | TP={tp_price:.2f} "
                f"| R:R={actual_rr:.2f} | Lot={lot_size} | OB={ob_zone['time_found']}"
            )
            print(msg); save_log(msg)

        time.sleep(5)

except Exception as e:
    msg = f"Lỗi nghiêm trọng: {e}"
    print(msg)
    try:
        save_log(msg)
    except:
        pass

finally:
    mt5.shutdown()
    print("Đã đóng kết nối MT5.")