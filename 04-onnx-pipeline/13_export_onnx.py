"""
Шаг 5: выгрузка обученной LSTM в ONNX + проверка совпадения с PyTorch.

Нормировку (вычитание среднего, деление на сигму) вшиваем внутрь ONNX-графа,
чтобы советнику в MT5 не пришлось её повторять — он подаёт сырые признаки.

Что проверяем:
  * onnx.checker — граф корректен;
  * onnxruntime на тех же входах даёт то же, что PyTorch (максимальное расхождение печатаем);
  * показываем имена и формы входов/выходов, чтобы советник знал, что подавать.

Запуск:
    D:\\mql5-ml\\venv\\Scripts\\python.exe D:\\mql5-ml\\scripts\\13_export_onnx.py
"""
import glob
import os
import shutil

import numpy as np
import onnx
import onnxruntime as ort
import torch
import torch.nn as nn

MOD = r"D:\mql5-ml\models"
ONNX_DIR = r"D:\mql5-ml\models\onnx"
MT5_FILES = r"D:\MetaTrader 5\MQL5\Files"
TERMINAL = r"D:\MetaTrader 5\terminal64.exe"
os.makedirs(ONNX_DIR, exist_ok=True)


def common_files_dir():
    """Общая папка MetaQuotes: её видит и терминал, и агент тестера."""
    p = os.environ.get("HERMES_COMMON", "").strip()
    if p:
        return p
    try:
        import MetaTrader5 as mt5
        if mt5.initialize(path=TERMINAL, portable=True):
            p = os.path.join(mt5.terminal_info().commondata_path, "Files")
            mt5.shutdown()
            return p
    except Exception:
        pass
    return os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files")


class Net(nn.Module):
    def __init__(self, n_feat, hidden=64, layers=2):
        super().__init__()
        self.lstm = nn.LSTM(n_feat, hidden, num_layers=layers, batch_first=True, dropout=0.2)
        self.head = nn.Sequential(nn.Linear(hidden, 32), nn.ReLU(), nn.Linear(32, 1))

    def forward(self, x):
        out, _ = self.lstm(x)
        return self.head(out[:, -1, :]).squeeze(-1)


class NetWithNorm(nn.Module):
    """Сырые признаки -> нормировка -> LSTM -> вероятность."""

    def __init__(self, n_feat, mean, std, hidden=64, layers=2):
        super().__init__()
        self.net = Net(n_feat, hidden, layers)
        self.register_buffer("mean", torch.tensor(mean, dtype=torch.float32))
        self.register_buffer("std", torch.tensor(std, dtype=torch.float32))

    def forward(self, x):
        return torch.sigmoid(self.net((x - self.mean) / self.std))


def export_all():
    arts = sorted(glob.glob(os.path.join(MOD, "lstm_*.pt")))
    if not arts:
        print("нет обученных моделей — сначала 12_train_lstm.py")
        return
    for art in arts:
        base = os.path.splitext(os.path.basename(art))[0]
        blob = torch.load(art, map_location="cpu", weights_only=False)   # свой файл, там ещё нормировка
        feats, seq = blob["feats"], blob["seq"]
        model = NetWithNorm(len(feats), blob["mean"], blob["std"])
        model.net.load_state_dict(blob["state_dict"])
        model.eval()

        dummy = torch.randn(1, seq, len(feats))
        out_path = os.path.join(ONNX_DIR, base + ".onnx")
        # Партия строго 1: так же будет подавать данные советник в MT5
        # (OnnxSetInputShape(handle, 0, {1, SEQ, NFEAT})).
        torch.onnx.export(
            model, dummy, out_path,
            input_names=["input"], output_names=["prob"],
            opset_version=17, dynamo=False,
        )

        m = onnx.load(out_path)
        onnx.checker.check_model(m)
        size_kb = os.path.getsize(out_path) / 1024

        sess = ort.InferenceSession(out_path, providers=["CPUExecutionProvider"])
        x = np.random.randn(1, seq, len(feats)).astype("float32")   # партия 1, как в советнике
        got = sess.run(None, {"input": x})[0].ravel()
        with torch.no_grad():
            want = model(torch.from_numpy(x)).numpy().ravel()
        diff = float(np.max(np.abs(got - want)))

        print("-" * 96)
        print("модель      :", base)
        print("файл ONNX   :", out_path, "(%.1f КБ)" % size_kb)
        print("вход        : input  (batch, %d, %d) = (%d бар, %d признак)" % (seq, len(feats), seq, len(feats)))
        print("выход       : prob   (batch,) вероятность роста")
        print("горизонт    :", blob["horizon"], "баров | порог входа задаётся в советнике")
        print("расхождение ONNX и PyTorch: %.3e" % diff, "| проверка графа: ok")
        print("признаки (%d): %s" % (len(feats), ", ".join(feats)))

        dst = os.path.join(MT5_FILES, base + ".onnx")
        with open(out_path, "rb") as s, open(dst, "wb") as d:
            d.write(s.read())
        print("скопировано в терминал:", dst)

        # агент тестера видит только общую папку — кладём и туда
        try:
            com = common_files_dir()
            os.makedirs(com, exist_ok=True)
            shutil.copy2(out_path, os.path.join(com, base + ".onnx"))
            print("скопировано в общую папку (для тестера):", os.path.join(com, base + ".onnx"))
        except Exception as e:
            print("не удалось скопировать в общую папку:", e)

        with open(os.path.join(ONNX_DIR, base + ".meta.json"), "w", encoding="utf-8") as f:
            import json
            json.dump({"feats": feats, "seq": seq, "horizon": blob["horizon"], "floor": blob["floor"],
                       "mean": [float(v) for v in blob["mean"]], "std": [float(v) for v in blob["std"]]},
                      f, ensure_ascii=False, indent=1)
    print("ONNX DONE")


if __name__ == "__main__":
    export_all()
