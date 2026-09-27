import 'dart:math';
import 'models.dart';

class SmcEngine {
  const SmcEngine();

  double _ema(List<double> x, int n) {
    if (x.isEmpty) return 0;
    final a = 2 / (n + 1);
    var e = x.first;
    for (var i = 1; i < x.length; i++) {
      e = a * x[i] + (1 - a) * e;
    }
    return e;
  }

  double _atr(List<Candle> c, int n) {
    if (c.length < n + 1) return 0;
    final tr = <double>[];
    for (var i = 1; i < c.length; i++) {
      tr.add(max(c[i].high - c[i].low,
          max((c[i].high - c[i - 1].close).abs(),
              (c[i].low - c[i - 1].close).abs())));
    }
    final start = max(0, tr.length - n);
    return tr.sublist(start).reduce((a, b) => a + b) /
        tr.sublist(start).length;
  }

  Signal? analyze({
    required String contract,
    required List<Candle> candles,
    required double equity,
    required ContractInfo info,
    required double riskPercent,
    required double rr,
  }) {
    if (candles.length < 80) return null;

    // Ignore the newest candle so the signal is based on a closed bar.
    final c = candles.sublist(0, candles.length - 1);
    final closes = c.map((e) => e.close).toList();
    final last = c.last;
    final prev = c[c.length - 2];
    final ema200 = _ema(closes, min(200, closes.length));
    final atr = _atr(c, 14);
    if (atr <= 0) return null;

    final look = min(20, c.length - 3);
    var priorHigh = -double.infinity;
    var priorLow = double.infinity;
    final priorStart = max(0, c.length - look - 2);
    final priorEnd = c.length - 2;
    for (var i = priorStart; i < priorEnd; i++) {
      priorHigh = max(priorHigh, c[i].high);
      priorLow = min(priorLow, c[i].low);
    }

    final bullishSweep = prev.low < priorLow && prev.close > priorLow;
    final bearishSweep = prev.high > priorHigh && prev.close < priorHigh;

    final bullishBos = last.close > priorHigh;
    final bearishBos = last.close < priorLow;

    final bullishFvg = c.length >= 4 && last.low > c[c.length - 3].high;
    final bearishFvg = c.length >= 4 && last.high < c[c.length - 3].low;

    final bullTrend = last.close > ema200;
    final bearTrend = last.close < ema200;

    String? side;
    final reasons = <String>[];
    if (bullTrend) reasons.add('EMA200 bullish');
    if (bearTrend) reasons.add('EMA200 bearish');
    if (bullishSweep) reasons.add('liquidity sweep low');
    if (bearishSweep) reasons.add('liquidity sweep high');
    if (bullishBos) reasons.add('BOS up');
    if (bearishBos) reasons.add('BOS down');
    if (bullishFvg) reasons.add('FVG up');
    if (bearishFvg) reasons.add('FVG down');

    if (bullTrend && bullishSweep && bullishBos) {
      side = 'BUY';
    } else if (bearTrend && bearishSweep && bearishBos) {
      side = 'SELL';
    } else {
      return null;
    }

    final entry = last.close;
    final stop = side == 'BUY'
        ? min(prev.low, last.low) - atr * 0.25
        : max(prev.high, last.high) + atr * 0.25;
    final riskDistance = (entry - stop).abs();
    if (riskDistance <= 0) return null;

    final tp = side == 'BUY'
        ? entry + riskDistance * rr
        : entry - riskDistance * rr;

    // For linear USDT contracts, approximate risk per contract using
    // the contract's quanto multiplier. Gate currently exposes size
    // fields as strings/decimals; the app rounds to the minimum size.
    final riskPerContract = riskDistance * info.quantoMultiplier;
    if (riskPerContract <= 0) return null;

    final riskAmount = equity * riskPercent / 100;
    var size = riskAmount / riskPerContract;
    if (info.orderSizeMin > 0) {
      size = (size / info.orderSizeMin).floor() * info.orderSizeMin;
      if (size < info.orderSizeMin) size = info.orderSizeMin;
    }
    if (info.orderSizeMax > 0) size = min(size, info.orderSizeMax);
    if (size <= 0) return null;

    final score = min(
      100,
      35 +
          (bullTrend || bearTrend ? 20 : 0) +
          ((bullishSweep || bearishSweep) ? 20 : 0) +
          ((bullishBos || bearishBos) ? 20 : 0) +
          ((bullishFvg || bearishFvg) ? 5 : 0),
    );

    return Signal(
      contract: contract,
      side: side,
      entry: entry,
      stop: stop,
      tp: tp,
      riskAmount: riskAmount,
      size: size,
      score: score,
      reasons: reasons,
    );
  }
}
