import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gateio_smc_pro/gate_stream.dart';
import 'package:gateio_smc_pro/models.dart';

void main() {
  test('parses matching futures candle updates only', () {
    final frame = parseGateCandlestickFrame(
      jsonEncode({
        'channel': 'futures.candlesticks',
        'event': 'update',
        'result': [
          {
            't': 1790700000,
            'v': '12',
            'c': '101.5',
            'h': '102',
            'l': '100',
            'o': '100.5',
            'n': 'BTC_USDT',
            'w': '1m',
          },
          {
            't': 1790700000,
            'v': '8',
            'c': '20',
            'h': '21',
            'l': '19',
            'o': '19.5',
            'n': 'ETH_USDT',
            'w': '1m',
          },
        ],
      }),
      contract: 'BTC_USDT',
      interval: '1m',
    );

    expect(frame.candles, hasLength(1));
    expect(frame.candles.single.close, 101.5);
    expect(frame.candles.single.volume, 12);
  });

  test('parses subscription acknowledgements and errors', () {
    final accepted = parseGateCandlestickFrame(
      jsonEncode({
        'channel': 'futures.candlesticks',
        'event': 'subscribe',
        'result': {'status': 'success'},
      }),
      contract: 'BTC_USDT',
      interval: '15m',
    );
    final rejected = parseGateCandlestickFrame(
      jsonEncode({
        'channel': 'futures.candlesticks',
        'event': 'subscribe',
        'error': {'label': 'INVALID_PARAM_VALUE', 'message': 'bad interval'},
      }),
      contract: 'BTC_USDT',
      interval: '15m',
    );

    expect(accepted.subscribed, isTrue);
    expect(rejected.subscriptionError, 'bad interval');
  });

  test('ignores malformed and unrelated websocket frames', () {
    final malformed = parseGateCandlestickFrame(
      'not-json',
      contract: 'BTC_USDT',
      interval: '1m',
    );
    final unrelated = parseGateCandlestickFrame(
      jsonEncode({
        'channel': 'futures.trades',
        'event': 'update',
        'result': [],
      }),
      contract: 'BTC_USDT',
      interval: '1m',
    );

    expect(malformed.candles, isEmpty);
    expect(unrelated.candles, isEmpty);
  });

  test(
    'updates the open candle without duplicates and ignores stale candles',
    () {
      final start = DateTime.utc(2026, 9, 29, 12);
      final history = [
        _candle(start, close: 100),
        _candle(start.add(const Duration(minutes: 1)), close: 101),
      ];
      final merged = mergeGateCandles(history, [
        _candle(start.add(const Duration(minutes: 1)), close: 102),
        _candle(start.add(const Duration(minutes: 2)), close: 103),
        _candle(start.subtract(const Duration(minutes: 1)), close: 99),
      ]);

      expect(merged, hasLength(3));
      expect(merged[1].close, 102);
      expect(merged.last.close, 103);
    },
  );
}

Candle _candle(DateTime time, {required double close}) => Candle(
  time: time,
  open: close,
  high: close,
  low: close,
  close: close,
  volume: 1,
);
