import 'dart:math';
import 'models.dart';

class SmcEngine {
  const SmcEngine();

  static const minimumSetupScore = 80;

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
      tr.add(
        max(
          c[i].high - c[i].low,
          max(
            (c[i].high - c[i - 1].close).abs(),
            (c[i].low - c[i - 1].close).abs(),
          ),
        ),
      );
    }
    final start = max(0, tr.length - n);
    return tr.sublist(start).reduce((a, b) => a + b) / tr.sublist(start).length;
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
    if (bullTrend && bullishBos) {
      side = 'BUY';
    } else if (bearTrend && bearishBos) {
      side = 'SELL';
    } else {
      return null;
    }

    if (rr <= 0) return null;

    final entry = last.close;
    final stop = side == 'BUY'
        ? min(prev.low, last.low) - atr * 0.25
        : max(prev.high, last.high) + atr * 0.25;
    final riskDistance = (entry - stop).abs();
    if (riskDistance <= 0) return null;

    final direction = side == 'BUY' ? 1 : -1;
    final tp1 = entry + direction * riskDistance;
    final tp2 = entry + direction * riskDistance * 2;
    final tp3 = entry + direction * riskDistance * rr;

    final alignedSweep = side == 'BUY' ? bullishSweep : bearishSweep;
    final alignedFvg = side == 'BUY' ? bullishFvg : bearishFvg;
    final score = min(
      100,
      25 +
          25 +
          (alignedSweep ? 25 : 0) +
          (alignedFvg ? 15 : 0) +
          (rr >= 2 ? 10 : 0),
    );
    if (score < minimumSetupScore) return null;

    final reasons = <String>[
      side == 'BUY' ? 'EMA200 bullish (+25)' : 'EMA200 bearish (+25)',
      side == 'BUY' ? 'BOS up (+25)' : 'BOS down (+25)',
      if (alignedSweep)
        side == 'BUY'
            ? 'Liquidity sweep low (+25)'
            : 'Liquidity sweep high (+25)',
      if (alignedFvg) side == 'BUY' ? 'Bullish FVG (+15)' : 'Bearish FVG (+15)',
      if (rr >= 2)
        'Risk/reward 1:${rr.toStringAsFixed(rr == rr.roundToDouble() ? 0 : 1)} (+10)',
    ];

    // For linear USDT contracts, approximate risk per contract using
    // the contract's quanto multiplier. Gate currently exposes size
    // fields as strings/decimals; the app rounds to the minimum size.
    final riskPerContract = riskDistance * info.quantoMultiplier;
    if (riskPerContract <= 0) return null;

    final riskAmount = equity * riskPercent / 100;
    var size = riskAmount / riskPerContract;
    if (info.orderSizeMin > 0) {
      size = (size / info.orderSizeMin).floor() * info.orderSizeMin;
      if (size < info.orderSizeMin) return null;
    }
    if (info.orderSizeMax > 0) size = min(size, info.orderSizeMax);
    if (size <= 0) return null;

    return Signal(
      contract: contract,
      side: side,
      entry: entry,
      stop: stop,
      tp1: tp1,
      tp2: tp2,
      tp3: tp3,
      riskAmount: riskAmount,
      size: size,
      score: score,
      reasons: reasons,
    );
  }
}
