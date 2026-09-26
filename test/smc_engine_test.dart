import 'package:flutter_test/flutter_test.dart';
import 'package:gateio_smc_pro/models.dart';
import 'package:gateio_smc_pro/smc_engine.dart';

void main() {
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
}
