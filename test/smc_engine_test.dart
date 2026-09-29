import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gateio_smc_pro/models.dart';
import 'package:gateio_smc_pro/smc_chart.dart';
import 'package:gateio_smc_pro/smc_engine.dart';

void main() {
  test('only active futures contracts are eligible for scanning', () {
    const active = ContractInfo(
      name: 'BTC_USDT',
      quantoMultiplier: 1,
      orderSizeMin: 1,
      orderSizeMax: 0,
      markPrice: 100,
      state: 'normal',
    );
    const delisted = ContractInfo(
      name: 'OLD_USDT',
      quantoMultiplier: 1,
      orderSizeMin: 1,
      orderSizeMax: 0,
      markPrice: 0,
      state: 'true',
    );

    expect(active.isActive, isTrue);
    expect(delisted.isActive, isFalse);
  });

  test('engine does not throw on insufficient candles', () {
    final candles = List.generate(
      10,
      (i) => Candle(
        time: DateTime.utc(2026, 1, 1).add(Duration(minutes: i * 15)),
        open: 100,
        high: 101,
        low: 99,
        close: 100,
        volume: 1,
      ),
    );
    final info = ContractInfo(
      name: 'BTC_USDT',
      quantoMultiplier: 0.0001,
      orderSizeMin: 1,
      orderSizeMax: 100000,
      markPrice: 100,
      state: 'normal',
    );
    expect(
      const SmcEngine().analyze(
        contract: 'BTC_USDT',
        candles: candles,
        equity: 100,
        info: info,
        riskPercent: 2,
        rr: 3,
      ),
      isNull,
    );
  });

  test('setup above the 80 point threshold is accepted', () {
    final signal = const SmcEngine().analyze(
      contract: 'BTC_USDT',
      candles: _setupCandles(withSweep: true),
      equity: 100,
      info: _contractInfo,
      riskPercent: 2,
      rr: 3,
    );

    expect(signal, isNotNull);
    expect(signal!.score, 85);
    final riskDistance = signal.entry - signal.stop;
    expect(signal.tp1, closeTo(signal.entry + riskDistance, 1e-9));
    expect(signal.tp2, closeTo(signal.entry + riskDistance * 2, 1e-9));
    expect(signal.tp3, closeTo(signal.entry + riskDistance * 3, 1e-9));
  });

  test('75 point setup is rejected by the 80 point threshold', () {
    final signal = const SmcEngine().analyze(
      contract: 'BTC_USDT',
      candles: _setupCandles(withSweep: true),
      equity: 100,
      info: _contractInfo,
      riskPercent: 2,
      rr: 1,
    );

    expect(signal, isNull);
  });

  test('setup below 80 points is rejected', () {
    final signal = const SmcEngine().analyze(
      contract: 'BTC_USDT',
      candles: _setupCandles(withSweep: false),
      equity: 100,
      info: _contractInfo,
      riskPercent: 2,
      rr: 1,
    );

    expect(signal, isNull);
  });

  test('minimum order size cannot exceed the risk budget', () {
    final signal = const SmcEngine().analyze(
      contract: 'BTC_USDT',
      candles: _setupCandles(withSweep: true),
      equity: 0.000001,
      info: _contractInfo,
      riskPercent: 2,
      rr: 3,
    );

    expect(signal, isNull);
  });

  test('changing the open candle does not change a closed-candle signal', () {
    final candles = _setupCandles(withSweep: true);
    final baseline = const SmcEngine().analyze(
      contract: 'BTC_USDT',
      candles: candles,
      equity: 100,
      info: _contractInfo,
      riskPercent: 2,
      rr: 3,
    );
    candles[89] = Candle(
      time: candles[89].time,
      open: 1,
      high: 10000,
      low: 0.01,
      close: 9000,
      volume: 1000000,
    );
    final withChangedOpenCandle = const SmcEngine().analyze(
      contract: 'BTC_USDT',
      candles: candles,
      equity: 100,
      info: _contractInfo,
      riskPercent: 2,
      rr: 3,
    );

    expect(withChangedOpenCandle?.score, baseline?.score);
    expect(withChangedOpenCandle?.entry, baseline?.entry);
    expect(withChangedOpenCandle?.stop, baseline?.stop);
  });

  testWidgets('chart renders candles when no signal exists', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 320,
          child: SmcCandlestickChart(
            candles: _setupCandles(withSweep: false),
            signal: null,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter != null,
      ),
      findsOneWidget,
    );
  });
}

const _contractInfo = ContractInfo(
  name: 'BTC_USDT',
  quantoMultiplier: 0.0001,
  orderSizeMin: 1,
  orderSizeMax: 100000,
  markPrice: 100,
  state: 'normal',
);

List<Candle> _setupCandles({required bool withSweep}) {
  final candles = List.generate(90, (index) {
    final close = 100 + index * 0.2;
    return Candle(
      time: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
      open: close - 0.05,
      high: close + 0.1,
      low: close - 0.1,
      close: close,
      volume: 1,
    );
  });

  if (withSweep) {
    candles[87] = Candle(
      time: candles[87].time,
      open: 114,
      high: 114.1,
      low: 113,
      close: 113.4,
      volume: 1,
    );
  }
  candles[88] = Candle(
    time: candles[88].time,
    open: 117.5,
    high: 118.1,
    low: 117.25,
    close: 118,
    volume: 1,
  );
  return candles;
}
