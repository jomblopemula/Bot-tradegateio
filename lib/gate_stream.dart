import 'dart:convert';

import 'models.dart';

class GateCandlestickFrame {
  final bool subscribed;
  final String? subscriptionError;
  final List<Candle> candles;

  const GateCandlestickFrame({
    this.subscribed = false,
    this.subscriptionError,
    this.candles = const [],
  });
}

GateCandlestickFrame parseGateCandlestickFrame(
  Object frame, {
  required String contract,
  required String interval,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(frame is String ? frame : frame.toString());
  } on FormatException {
    return const GateCandlestickFrame();
  }
  if (decoded is! Map) return const GateCandlestickFrame();
  if (decoded['channel'] != 'futures.candlesticks') {
    return const GateCandlestickFrame();
  }

  if (decoded['event'] == 'subscribe') {
    final error = decoded['error'];
    if (error is Map) {
      return GateCandlestickFrame(
        subscriptionError: '${error['message'] ?? error['label'] ?? error}',
      );
    }
    return const GateCandlestickFrame(subscribed: true);
  }
  if (decoded['event'] != 'update') return const GateCandlestickFrame();

  final result = decoded['result'];
  final rows = result is List ? result : [result];
  final candles = <Candle>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final rowContract = row['n'];
    final rowInterval = row['w'];
    if (rowContract != null && rowContract != contract) continue;
    if (rowInterval != null && rowInterval != interval) continue;

    try {
      candles.add(Candle.fromGate(Map<String, dynamic>.from(row)));
    } on FormatException {
      continue;
    }
  }
  return GateCandlestickFrame(candles: candles);
}

List<Candle> mergeGateCandles(
  List<Candle> existing,
  List<Candle> updates, {
  int maxCandles = 240,
}) {
  final merged = List<Candle>.of(existing);
  for (final candle in updates) {
    final index = merged.indexWhere((item) => item.time == candle.time);
    if (index >= 0) {
      merged[index] = candle;
    } else if (merged.isEmpty || candle.time.isAfter(merged.last.time)) {
      merged.add(candle);
    }
  }
  if (merged.length > maxCandles) {
    return merged.sublist(merged.length - maxCandles);
  }
  return merged;
}
