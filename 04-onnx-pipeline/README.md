# Конвейер ML → ONNX → MetaTrader 5 (Python)

Обучение модели временных рядов (LSTM), экспорт в ONNX и интеграция в советник
MetaTrader 5.

## Этапы

- `12_train_lstm.py` — подготовка и обучение LSTM на барах.
- `13_export_onnx.py` — экспорт обученной модели в ONNX.
- `14_make_ea.py` — генерация советника, который вызывает ONNX-модель.

## Стек

Python · PyTorch · ONNX Runtime · MetaTrader 5
