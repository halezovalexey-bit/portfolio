"""
Шаг 4: LSTM на GPU (PyTorch + CUDA) с той же walk-forward схемой и той же симуляцией.

Особенности:
  * на вход идут последовательности последних SEQ баров из признаков;
  * нормировка (z-оценка) считается только на обучающем окне и сохраняется для EA;
  * обучаем на длинном горизонте (издержки меньше давят на результат);
  * по завершении сохраняем модель, нормировку, список признаков и порог входа —
    всё это потом пойдёт в ONNX и в советник.

Запуск:
    D:\\mql5-ml\\venv\\Scripts\\python.exe D:\\mql5-ml\\scripts\\12_train_lstm.py
"""
import json
import os
import warnings
from datetime import timedelta

import numpy as np
import pandas as pd
import torch
import torch.nn as nn
from sklearn.metrics import roc_auc_score

warnings.filterwarnings("ignore")

FEAT = os.environ.get("HERMES_FEAT", r"D:\mql5-ml\features")
REP = os.environ.get("HERMES_REP", r"D:\mql5-ml\reports")
MOD = os.environ.get("HERMES_MOD", r"D:\mql5-ml\models")
for d in (REP, MOD):
    os.makedirs(d, exist_ok=True)

JOBS = [("EURUSD_H1", 24), ("GBPUSD_H1", 24), ("USDJPY_H1", 24), ("EURUSD_M15", 96)]
SEQ = 32
TRAIN_DAYS = 730
TEST_DAYS = 90
THRESHOLDS = [0.50, 0.52, 0.55, 0.60]
COMMISSION_PTS = 0.5
EPOCHS = 12
BATCH = 256
LR = 1e-3
DROP = ["time", "close", "point"]

DEV = "cuda" if torch.cuda.is_available() else "cpu"
print("устройство:", DEV, "|", torch.cuda.get_device_name(0) if DEV == "cuda" else "-", flush=True)


class Net(nn.Module):
    def __init__(self, n_feat, hidden=64, layers=2):
        super().__init__()
        self.lstm = nn.LSTM(n_feat, hidden, num_layers=layers, batch_first=True, dropout=0.2)
        self.head = nn.Sequential(nn.Linear(hidden, 32), nn.ReLU(), nn.Linear(32, 1))

    def forward(self, x):
        out, _ = self.lstm(x)
        return self.head(out[:, -1, :]).squeeze(-1)


def make_sequences(x, y, seq):
    """x: (n, f) -> (n-seq+1, seq, f); метка берётся у последнего бара окна."""
    n = len(x)
    idx = np.arange(seq - 1, n)
    xs = np.stack([x[i - seq + 1:i + 1] for i in idx])
    ys = y[idx]
    return xs.astype("float32"), ys.astype("float32")


def simulate(p, fwd, cost, horizon, thr):
    n = len(p)
    grid = np.arange(0, max(0, n - horizon), horizon)
    if len(grid) == 0:
        return dict(trades=0, pts=0.0, pf=0.0, hit=0.0, dd=0.0)
    sig = np.where(p[grid] >= thr, 1, np.where(p[grid] <= 1 - thr, -1, 0))
    take = sig != 0
    if take.sum() == 0:
        return dict(trades=0, pts=0.0, pf=0.0, hit=0.0, dd=0.0)
    pnl = sig[take] * fwd[grid][take] - cost[grid][take]
    eq = np.cumsum(pnl)
    peak = np.maximum.accumulate(np.concatenate([[0.0], eq]))[:-1]
    win, loss = pnl[pnl > 0].sum(), -pnl[pnl <= 0].sum()
    return dict(trades=int(take.sum()), pts=float(pnl.sum()),
                pf=float(win / loss) if loss > 0 else float("inf"),
                hit=float((pnl > 0).mean()), dd=float(np.min(eq - peak)))


def run(name, horizon):
    tag = "h%d" % horizon
    df = pd.read_csv(os.path.join(FEAT, name + "_feat.csv"))
    df["time"] = pd.to_datetime(df["time"])
    df = df.dropna(subset=["y_" + tag]).reset_index(drop=True)
    feats = [c for c in df.columns if c not in DROP and not c.startswith("y_") and not c.startswith("fwd_pts_")]
    df[feats] = df[feats].fillna(0.0)   # как в советнике: в спорных случаях признак равен 0

    pos = df["spread_pts"][df["spread_pts"] > 0]
    floor = max(1.0, float(np.percentile(pos, 25)) if len(pos) else 1.0)

    start, end = df["time"].iloc[0], df["time"].iloc[-1]
    folds, cursor = [], start
    while True:
        tr_end = cursor + timedelta(days=TRAIN_DAYS)
        if tr_end >= end:
            break
        te_end = tr_end + timedelta(days=TEST_DAYS)
        tr = df[(df["time"] >= cursor) & (df["time"] < tr_end)]
        te = df[(df["time"] >= tr_end) & (df["time"] < te_end)].reset_index(drop=True)
        if len(tr) > 2000 and len(te) > 200:
            folds.append((tr.iloc[:-horizon] if horizon < len(tr) else tr, te))
        cursor += timedelta(days=TEST_DAYS)
    if not folds:
        print(name, tag, "нет окон")
        return None

    rows, last_art = [], None
    for i, (tr, te) in enumerate(folds, 1):
        mean = tr[feats].mean().to_numpy("float32")
        std = tr[feats].std().replace(0, 1).to_numpy("float32")

        # валидация — последние 10% обучающего окна
        cut = int(len(tr) * 0.9)
        tr_a, va = tr.iloc[:cut], tr.iloc[cut:]
        xa = ((tr_a[feats].to_numpy("float32") - mean) / std)
        xv = ((va[feats].to_numpy("float32") - mean) / std)
        Xa, ya = make_sequences(xa, tr_a["y_" + tag].to_numpy("float32"), SEQ)
        Xv, yv = make_sequences(xv, va["y_" + tag].to_numpy("float32"), SEQ)

        torch.manual_seed(42)
        model = Net(len(feats)).to(DEV)
        opt = torch.optim.Adam(model.parameters(), lr=LR)
        lossf = nn.BCEWithLogitsLoss()
        Xa_t = torch.from_numpy(Xa).to(DEV)
        ya_t = torch.from_numpy(ya).to(DEV)
        Xv_t = torch.from_numpy(Xv).to(DEV)

        best_auc, best_state, patience = -1, None, 0
        for ep in range(EPOCHS):
            model.train()
            perm = torch.randperm(len(Xa_t), device=DEV)
            for b in range(0, len(perm), BATCH):
                idx = perm[b:b + BATCH]
                opt.zero_grad()
                loss = lossf(model(Xa_t[idx]), ya_t[idx])
                loss.backward()
                opt.step()
            model.eval()
            with torch.no_grad():
                pv = torch.sigmoid(model(Xv_t)).cpu().numpy()
            try:
                auc_v = roc_auc_score(yv, pv)
            except Exception:
                auc_v = 0.5
            if auc_v > best_auc:
                best_auc, best_state, patience = auc_v, {k: v.detach().clone() for k, v in model.state_dict().items()}, 0
            else:
                patience += 1
                if patience >= 3:
                    break
        model.load_state_dict(best_state)

        # тест
        te_all = pd.concat([tr.tail(SEQ - 1), te], ignore_index=True)   # чтобы окна на начале теста были полными
        xt = ((te_all[feats].to_numpy("float32") - mean) / std)
        Xt, _ = make_sequences(xt, te_all["y_" + tag].to_numpy("float32"), SEQ)
        model.eval()
        with torch.no_grad():
            p = torch.sigmoid(model(torch.from_numpy(Xt).to(DEV))).cpu().numpy()
        p = p[-(len(te)):]
        fwd = te["fwd_pts_" + tag].to_numpy(float)
        cost = np.maximum(te["spread_pts"].to_numpy(float), floor) + COMMISSION_PTS
        p = np.nan_to_num(p, nan=0.5, posinf=1.0, neginf=0.0)   # сеть не должна ронять расчёт

        row = dict(fold=i, test_end=str(te["time"].iloc[-1])[:10], n_test=len(te),
                   acc=float(((p > 0.5).astype(int) == te["y_" + tag].astype(int)).mean()),
                   auc=float(roc_auc_score(te["y_" + tag].astype(int), p)),
                   auc_val=float(best_auc))
        grid = np.arange(0, max(0, len(p) - horizon), horizon)
        row["long_pts"] = round(float((fwd[grid] - cost[grid]).sum()), 1) if len(grid) else 0.0
        row["short_pts"] = round(float((-fwd[grid] - cost[grid]).sum()), 1) if len(grid) else 0.0
        for thr in THRESHOLDS:
            s = simulate(p, fwd, cost, horizon, thr)
            t2 = "t%.2f" % thr
            row[t2 + "_tr"], row[t2 + "_pts"] = s["trades"], round(s["pts"], 1)
            row[t2 + "_pf"] = round(s["pf"], 2) if np.isfinite(s["pf"]) else 0.0
            row[t2 + "_hit"], row[t2 + "_dd"] = round(s["hit"], 3), round(s["dd"], 1)
        rows.append(row)
        print("  окно %2d (%s): AUC %.4f (валид. %.4f) | лонг %+.0f | шорт %+.0f | модель@0.55 %+.0f пунктов, сделок %d" % (
            i, row["test_end"], row["auc"], row["auc_val"], row["long_pts"], row["short_pts"],
            row["t0.55_pts"], row["t0.55_tr"]), flush=True)
        last_art = dict(model=model, mean=mean, std=std, feats=feats, seq=SEQ, horizon=horizon, floor=floor)

    r = pd.DataFrame(rows)
    r.to_csv(os.path.join(REP, "%s_%s_lstm_wf.csv" % (name, tag)), index=False)

    # сохраняем последнюю (самую свежую) модель — именно её выгрузим в ONNX
    art = os.path.join(MOD, "lstm_%s_%s.pt" % (name, tag))
    torch.save({"state_dict": last_art["model"].state_dict(), "mean": last_art["mean"], "std": last_art["std"],
                "feats": last_art["feats"], "seq": last_art["seq"], "horizon": last_art["horizon"],
                "floor": last_art["floor"], "n_feat": len(last_art["feats"])}, art)

    print("=" * 110)
    print("%s %s | окон %d | средняя точность %.4f | средний AUC %.4f (валид. %.4f)" % (
        name, tag, len(r), r.acc.mean(), r.auc.mean(), r.auc_val.mean()))
    for thr in THRESHOLDS:
        t2 = "t%.2f" % thr
        hit = (r[t2 + "_hit"] * r[t2 + "_tr"]).sum() / max(1, r[t2 + "_tr"].sum())
        print("   порог %.2f: сделок %5d | пунктов %9.1f | проф.фактор %.2f | плюсовых окон %d/%d | доля приб. %.3f" % (
            thr, r[t2 + "_tr"].sum(), r[t2 + "_pts"].sum(), r[t2 + "_pf"].mean(),
            int((r[t2 + "_pts"] > 0).sum()), len(r), hit))
    print("   базовая линия: всегда лонг %+.0f | всегда шорт %+.0f пунктов" % (r.long_pts.sum(), r.short_pts.sum()))
    print("   модель сохранена:", art)
    return r


DEPLOY_END = os.environ.get("HERMES_TRAIN_END", "").strip()


def train_deploy(name, horizon, cutoff):
    """Одна модель, обученная строго до даты cutoff, — её и прогоняем в тестере
    на периоде после cutoff, то есть на данных, которых модель не видела."""
    tag = "h%d" % horizon
    df = pd.read_csv(os.path.join(FEAT, name + "_feat.csv"))
    df["time"] = pd.to_datetime(df["time"])
    df = df.dropna(subset=["y_" + tag]).reset_index(drop=True)
    feats = [c for c in df.columns if c not in DROP and not c.startswith("y_") and not c.startswith("fwd_pts_")]
    df[feats] = df[feats].fillna(0.0)
    pos = df["spread_pts"][df["spread_pts"] > 0]
    floor = max(1.0, float(np.percentile(pos, 25)) if len(pos) else 1.0)

    tr = df[df["time"] < pd.Timestamp(cutoff)]
    if horizon < len(tr):
        tr = tr.iloc[:-horizon]
    if len(tr) < 3000:
        print("%s %s: мало данных для обучения до %s" % (name, tag, cutoff))
        return None

    mean = tr[feats].mean().to_numpy("float32")
    std = tr[feats].std().replace(0, 1).to_numpy("float32")
    cut = int(len(tr) * 0.9)
    tr_a, va = tr.iloc[:cut], tr.iloc[cut:]
    xa = ((tr_a[feats].to_numpy("float32") - mean) / std)
    xv = ((va[feats].to_numpy("float32") - mean) / std)
    Xa, ya = make_sequences(xa, tr_a["y_" + tag].to_numpy("float32"), SEQ)
    Xv, yv = make_sequences(xv, va["y_" + tag].to_numpy("float32"), SEQ)

    torch.manual_seed(42)
    model = Net(len(feats)).to(DEV)
    opt = torch.optim.Adam(model.parameters(), lr=LR)
    lossf = nn.BCEWithLogitsLoss()
    Xa_t = torch.from_numpy(Xa).to(DEV)
    ya_t = torch.from_numpy(ya).to(DEV)
    Xv_t = torch.from_numpy(Xv).to(DEV)

    best_auc, best_state, patience = -1, None, 0
    for ep in range(EPOCHS):
        model.train()
        perm = torch.randperm(len(Xa_t), device=DEV)
        for b in range(0, len(perm), BATCH):
            idx = perm[b:b + BATCH]
            opt.zero_grad()
            lossf(model(Xa_t[idx]), ya_t[idx]).backward()
            opt.step()
        model.eval()
        with torch.no_grad():
            pv = torch.sigmoid(model(Xv_t)).cpu().numpy()
        try:
            auc_v = roc_auc_score(yv, pv)
        except Exception:
            auc_v = 0.5
        if auc_v > best_auc:
            best_auc, best_state, patience = auc_v, {k: v.detach().clone() for k, v in model.state_dict().items()}, 0
        else:
            patience += 1
            if patience >= 3:
                break
    model.load_state_dict(best_state)

    art = os.path.join(MOD, "lstm_%s_%s_deploy.pt" % (name, tag))
    torch.save({"state_dict": model.state_dict(), "mean": mean, "std": std, "feats": feats,
                "seq": SEQ, "horizon": horizon, "floor": floor, "n_feat": len(feats)}, art)
    print("%s %s | обучение до %s: %d баров | AUC на валидации %.4f | сохранено %s" % (
        name, tag, cutoff, len(tr), best_auc, art), flush=True)
    return art


out = []
if DEPLOY_END:
    print("=== режим подготовки модели к прогону в тестере: обучение до", DEPLOY_END, "===", flush=True)
    for name, hz in JOBS:
        if os.path.exists(os.path.join(FEAT, name + "_feat.csv")):
            train_deploy(name, hz, DEPLOY_END)
else:
    for name, hz in JOBS:
        if os.path.exists(os.path.join(FEAT, name + "_feat.csv")):
            print("\n>>> %s горизонт %d баров" % (name, hz), flush=True)
            res = run(name, hz)
            if res is not None:
                out.append(res)
print("LSTM DONE")
