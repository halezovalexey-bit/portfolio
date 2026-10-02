# -*- coding: utf-8 -*-
"""Недельный анализ V5: сводка рынка + состояние советника. Read-only, пишет отчёт."""
import json, datetime as dt, os, re
from collections import Counter

ROOT = r"D:\mql5-ml"
WA = os.path.join(ROOT, "weekly_analysis")
MARKET = json.load(open(os.path.join(WA, "market_week.json"), encoding="utf-8"))

UTC = dt.timezone.utc
def ts(t): return int(dt.datetime.strptime(t, "%Y-%m-%d").replace(tzinfo=UTC).timestamp())

W_START = ts("2026-09-28")          # понедельник 00:00 UTC
W_END   = ts("2026-10-03")          # суббота 00:00 UTC (исключающий)
FRI25   = ts("2026-09-25")

def fmt(tsv):
    return dt.datetime.fromtimestamp(tsv, UTC).strftime("%m-%d %H:%M")

report = {}
for sym, b in MARKET["bars"].items():
    h1 = b["h1"]; d1 = b["d1"]
    # --- неделя 28.09–02.10 ---
    week = [r for r in h1 if W_START <= r["t"] < W_END]
    fri = [r for r in h1 if FRI25 <= r["t"] < FRI25 + 86400]
    symr = {}
    if week:
        o0, c0 = week[0]["o"], week[-1]["c"]
        hi = max(r["h"] for r in week); lo = min(r["l"] for r in week)
        chg = (c0 - o0) / o0 * 100
        symr["week_open"] = o0
        symr["week_close"] = c0
        symr["week_high"] = hi
        symr["week_low"] = lo
        symr["week_change_pct"] = round(chg, 3)
        symr["week_dir"] = "UP" if c0 > o0 else ("DOWN" if c0 < o0 else "FLAT")
        symr["h1_in_week"] = len(week)
    # --- гэп выходных (пятница 25.09 close -> первый бар недели) ---
    if fri and week:
        fri_close = fri[-1]["c"]
        mon_open = week[0]["o"]
        gap = (mon_open - fri_close) / fri_close * 100
        gap_pips = round((mon_open - fri_close) * 10000, 1)
        symr["friday_close"] = fri_close
        symr["monday_open"] = mon_open
        symr["gap_pct"] = round(gap, 4)
        symr["gap_pips"] = gap_pips
        symr["gap_note"] = "gap up" if gap_pips > 0 else ("gap down" if gap_pips < 0 else "no gap")
    # --- M2: D1 close за 55 дней ---
    closes = [r["c"] for r in d1]
    highs  = [r["h"] for r in d1]
    lows   = [r["l"] for r in d1]
    m2 = []
    for i in range(len(d1)):
        if i < 55:
            continue
        prev_h = max(highs[i-55:i]); prev_l = min(lows[i-55:i])
        c = closes[i]
        if c > prev_h: m2.append((fmt(d1[i]["t"]), "BREAK_UP_55D", round(c,5), round(prev_h,5)))
        elif c < prev_l: m2.append((fmt(d1[i]["t"]), "BREAK_DN_55D", round(c,5), round(prev_l,5)))
    symr["m2_55d_triggers"] = m2 if m2 else "нет (за 55 дней истории)"
    symr["d1_bars_available"] = len(d1)
    report[sym] = symr

report["account"] = MARKET["account"]

# --- журнал советника: счёт news-причин + сделки/ошибки ---
LOGS = r"D:\mql5-ml\safety_stage\operational_round3\run_1790854336823992900\usd_portable\MQL5\Logs"
jrn = {"news_by_reason": Counter(), "news_by_symbol": Counter(), "deals": 0, "errors": 0, "guards": 0, "started": 0}
for f in ["20261001.log", "20261002.log"]:
    p = os.path.join(LOGS, f)
    if not os.path.exists(p): continue
    raw = open(p, "rb").read().decode("utf-16", errors="replace")
    for line in raw.splitlines():
        if "MYCODING NEWS mode=" in line:
            m = re.search(r"reason=(\S+)", line)
            if m: jrn["news_by_reason"][m.group(1)] += 1
            m2 = re.search(r"symbol=(\S+)", line)
            if m2: jrn["news_by_symbol"][m2.group(1)] += 1
        elif re.search(r"deal #|position #", line):
            jrn["deals"] += 1
        elif re.search(r"\berror\b", line, re.I):
            jrn["errors"] += 1
        elif "GUARD" in line:
            jrn["guards"] += 1
        elif "HermesForward started" in line:
            jrn["started"] += 1
report["journal_oct1_2"] = {
    "news_by_reason": dict(jrn["news_by_reason"]),
    "news_by_symbol": dict(jrn["news_by_symbol"]),
    "deals": jrn["deals"], "errors": jrn["errors"], "guards": jrn["guards"], "started": jrn["started"],
}

# --- deals.csv советника (magic MAGIC) ---
FILES = r"D:\mql5-ml\safety_stage\operational_round3\run_1790854336823992900\usd_portable\MQL5\Files"
deals_csv = os.path.join(FILES, "HFSAFE_MetaQuotes-Demo_LOGIN_MAGIC_deals.csv")
deals_rows = 0
if os.path.exists(deals_csv):
    deals_rows = len(open(deals_csv, encoding="utf-8", errors="replace").read().splitlines()) - 1  # минус заголовок
report["deals_csv_rows"] = max(0, deals_rows)

out_path = os.path.join(WA, "WEEKLY_2026-10-02.json")
json.dump(report, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(json.dumps(report, ensure_ascii=False, indent=1))
print("\nОТЧЁТ СОХРАНЁН:", out_path)
