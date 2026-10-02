# -*- coding: utf-8 -*-
"""Недельный отчёт V5 (для cron, воскресенье вечером). Read-only, без сделок.

Делает: счёт (MT5) + рынок H1/D1 (гэп пн., недельное движение, M2 55-дней) +
журнал советника (news-причины, сделки/ошибки) + deals.csv -> markdown-отчёт
в weekly_analysis/ и короткое резюме в stdout (для ntfy).
"""
import json, os, re, sys, datetime as dt
from collections import Counter

ROOT = r"D:\mql5-ml"
WA = os.path.join(ROOT, "weekly_analysis")
TERM = r"D:\mql5-ml\safety_stage\operational_round3\run_1790854336823992900\usd_portable"
LOGS = os.path.join(TERM, "MQL5", "Logs")
FILES = os.path.join(TERM, "MQL5", "Files")
SYMS = ["EURUSD", "GBPUSD"]
UTC = dt.timezone.utc

def fmt_d(t): return dt.datetime.fromtimestamp(t, UTC).strftime("%d.%m")

def d1_ts(b, i): return b["d1"][i]["t"]

def main():
    today = dt.datetime.now(UTC).replace(hour=0, minute=0, second=0, microsecond=0)
    # неделя для анализа: последний завершённый пн–пт
    this_mon = today - dt.timedelta(days=today.weekday())
    if today.weekday() == 0:  # понедельник -> прошлая неделя
        week_mon = this_mon - dt.timedelta(days=7)
    else:
        week_mon = this_mon
    week_fri = week_mon + dt.timedelta(days=4)
    prev_fri = week_mon - dt.timedelta(days=3)
    week_end = week_mon + dt.timedelta(days=5)  # [пн, суббота) — торговая неделя
    label = week_fri.strftime("%Y-%m-%d")

    # --- MT5: счёт + бары ---
    try:
        import MetaTrader5 as mt5
        ok = mt5.initialize(path=os.path.join(TERM, "terminal64.exe"), portable=True)
        if not ok:
            print("V5 недельный отчёт: терминал MT5 не поднялся (%s)" % mt5.last_error())
            return 2
        ai = mt5.account_info()
        if ai is None:
            print("V5 недельный отчёт: терминал MT5 не авторизован (нет входа в счёт). Запусти терминал и войди в демо-счёт.")
            return 2
        acct = {"login": ai.login, "equity": ai.equity, "currency": ai.currency,
                "positions": mt5.positions_total(), "orders": mt5.orders_total()}
        t1 = int(prev_fri.timestamp())
        t2 = int((week_end + dt.timedelta(days=1)).timestamp())  # включить всю пятницу
        d1_t1 = int((week_mon - dt.timedelta(days=80)).timestamp())
        bars = {}
        for s in SYMS:
            h1 = mt5.copy_rates_range(s, mt5.TIMEFRAME_H1, t1, t2)
            d1 = mt5.copy_rates_range(s, mt5.TIMEFRAME_D1, d1_t1, t2)
            if h1 is None or d1 is None:
                bars[s] = None; continue
            bars[s] = {
                "h1": [{"t": int(r[0]), "o": float(r[1]), "h": float(r[2]), "l": float(r[3]), "c": float(r[4])} for r in h1],
                "d1": [{"t": int(r[0]), "o": float(r[1]), "h": float(r[2]), "l": float(r[3]), "c": float(r[4])} for r in d1],
            }
        mt5.shutdown()
    except Exception as e:
        print("V5 недельный отчёт: ошибка MT5: %s" % e)
        return 2

    wstart = int(week_mon.timestamp()); wend = int(week_end.timestamp())
    pstart = int(prev_fri.timestamp())
    rows = []
    signals = []
    for s in SYMS:
        b = bars.get(s)
        if not b: rows.append("| %s | нет данных |" % s); continue
        week = [r for r in b["h1"] if wstart <= r["t"] < wend]
        fri = [r for r in b["h1"] if pstart <= r["t"] < pstart + 86400]
        if not week: rows.append("| %s | нет недели |" % s); continue
        o0, c0 = week[0]["o"], week[-1]["c"]
        hi = max(r["h"] for r in week); lo = min(r["l"] for r in week)
        chg = (c0 - o0) / o0 * 100
        gap_pips = round((week[0]["o"] - fri[-1]["c"]) * 10000, 1) if fri else 0
        m2 = ""
        closes = [r["c"] for r in b["d1"]]; highs = [r["h"] for r in b["d1"]]; lows = [r["l"] for r in b["d1"]]
        for i in range(55, len(b["d1"])):
            ph = max(highs[i-55:i]); pl = min(lows[i-55:i])
            if closes[i] > ph:
                m2 = "M2 up"; sig = "%s: D1 %s close %.5f > 55дн high %.5f" % (s, fmt_d(d1_ts(b, i)), closes[i], ph)
            elif closes[i] < pl:
                m2 = "M2 dn"; sig = "%s: D1 %s close %.5f < 55дн low %.5f" % (s, fmt_d(d1_ts(b, i)), closes[i], pl)
        if m2: signals.append(sig)
        rows.append("| %s | %.5f → %.5f | %+.2f%% | %.5f | %.5f | %+d пп %s | %s |"
                    % (s, o0, c0, chg, hi, lo, gap_pips, "gap" if gap_pips else "", m2 or "—"))

    # --- журнал ---
    jrn = {"news": Counter(), "deals": 0, "errors": 0, "guards": 0, "started": 0}
    for d in range((week_fri - week_mon).days + 1):
        day = week_mon + dt.timedelta(days=d)
        lp = os.path.join(LOGS, day.strftime("%Y%m%d") + ".log")
        if not os.path.exists(lp): continue
        for line in open(lp, "rb").read().decode("utf-16", errors="replace").splitlines():
            if "MYCODING NEWS mode=" in line:
                m = re.search(r"reason=(\S+)", line); jrn["news"][m.group(1) if m else "?"] += 1
            elif re.search(r"deal #|position #", line): jrn["deals"] += 1
            elif re.search(r"\berror\b", line, re.I): jrn["errors"] += 1
            elif "GUARD" in line: jrn["guards"] += 1
            elif "HermesForward started" in line: jrn["started"] += 1

    # --- deals.csv ---
    deals_csv = os.path.join(FILES, "HFSAFE_MetaQuotes-Demo_LOGIN_MAGIC_deals.csv")
    deals = 0
    if os.path.exists(deals_csv):
        deals = max(0, len(open(deals_csv, encoding="utf-8", errors="replace").read().splitlines()) - 1)

    md = []
    md.append("# Недельный анализ V5 — %s…%s\n" % (week_mon.strftime("%d.%m"), week_fri.strftime("%d.%m.%Y")))
    md.append("Счёт: login %s, equity %.2f %s, позиции %d, ордера %d.\n" % (acct["login"], acct["equity"], acct["currency"], acct["positions"], acct["orders"]))
    md.append("| Пара | Откр→Закр | Изм. | High | Low | Гэп пн. | M2 |")
    md.append("|---|---|---|---|---|---|---|")
    md += rows
    md.append("\nЖурнал: чтений %d (%s), сделок %d, ошибок %d, guard %d, стартов %d, deals.csv строк %d.\n"
              % (sum(jrn["news"].values()), ", ".join("%s=%d" % kv for kv in jrn["news"].most_common()), jrn["deals"], jrn["errors"], jrn["guards"], jrn["started"], deals))
    if signals:
        md.append("\nСигналы недели (M2 55-дн.):")
        md += ["- " + x for x in signals]
    out_md = os.path.join(WA, "WEEKLY_%s.md" % label)
    open(out_md, "w", encoding="utf-8").write("\n".join(md))

    # короткое резюме для ntfy
    chg = {r.split("|")[1].strip(): r.split("|")[3].strip() for r in rows if "→" in r}
    m2txt = "; ".join(s.split(": ", 1)[1] for s in signals) if signals else "M2 нет"
    summary = "V5 неделя %s | EURUSD %s, GBPUSD %s | %s | счёт %.0f, позиции %d, сделок %d, ошибок %d" % (
        week_fri.strftime("%d.%m"),
        chg.get("EURUSD", "?"), chg.get("GBPUSD", "?"),
        m2txt, acct["equity"], acct["positions"], jrn["deals"], jrn["errors"])
    print(summary[:2000])
    return 0

if __name__ == "__main__":
    sys.exit(main())
