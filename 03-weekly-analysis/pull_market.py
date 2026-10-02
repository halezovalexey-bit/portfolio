# -*- coding: utf-8 -*-
"""Недельный анализ V5: рынок (H1/D1) + состояние советника. Read-only."""
import MetaTrader5 as mt5
import json, datetime as dt

PATH = r"D:\mql5-ml\safety_stage\operational_round3\run_1790854336823992900\usd_portable\terminal64.exe"
SYMS = ["EURUSD", "GBPUSD"]

out = {}

if not mt5.initialize(path=PATH, portable=True):
    print(json.dumps({"error": "init failed: %s" % mt5.last_error()}))
    raise SystemExit(1)

try:
    ai = mt5.account_info()
    out["account"] = {"login": ai.login, "equity": ai.equity, "currency": ai.currency,
                      "positions": mt5.positions_total(), "orders": mt5.orders_total()}

    utc = dt.timezone.utc
    # H1: пятница 25.09 00:00 UTC -> сегодня (захватить гэп открытия понедельника)
    t1_h1 = dt.datetime(2026, 9, 25, 0, 0, tzinfo=utc)
    t2_h1 = dt.datetime(2026, 10, 3, 23, 59, tzinfo=utc)
    # D1: ~75 дней назад (для 55-дневного экстремума)
    t1_d1 = dt.datetime(2026, 7, 20, 0, 0, tzinfo=utc)
    t2_d1 = dt.datetime(2026, 10, 3, 23, 59, tzinfo=utc)

    out["bars"] = {}
    for sym in SYMS:
        h1 = mt5.copy_rates_range(sym, mt5.TIMEFRAME_H1, t1_h1, t2_h1)
        d1 = mt5.copy_rates_range(sym, mt5.TIMEFRAME_D1, t1_d1, t2_d1)
        if h1 is None or d1 is None:
            out["bars"][sym] = {"error": str(mt5.last_error())}
            continue
        out["bars"][sym] = {
            "h1": [{"t": int(r[0]), "o": float(r[1]), "h": float(r[2]), "l": float(r[3]), "c": float(r[4]), "v": int(r[5])} for r in h1],
            "d1": [{"t": int(r[0]), "o": float(r[1]), "h": float(r[2]), "l": float(r[3]), "c": float(r[4]), "v": int(r[5])} for r in d1],
        }
finally:
    mt5.shutdown()

# Сохранить на диск (большой объём) + вывести компактное резюме
with open(r"D:\mql5-ml\weekly_analysis\market_week.json", "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False)

# компакт: H1 свечи только за неделю 28.09–02.10 + последняя пятница/понедельник для гэпа
res = {"account": out.get("account")}
for sym in SYMS:
    b = out.get("bars", {}).get(sym, {})
    if "h1" not in b:
        res[sym] = b; continue
    d1 = b["d1"]
    res[sym] = {
        "h1_count": len(b["h1"]),
        "d1_count": len(d1),
        "last_d1": [{"t": r["t"], "o": r["o"], "h": r["h"], "l": r["l"], "c": r["c"]} for r in d1[-3:]],
    }
print(json.dumps(res, ensure_ascii=False, indent=1))
