import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';

class SmcCandlestickChart extends StatelessWidget {
  final List<Candle> candles;
  final Signal? signal;

  const SmcCandlestickChart({
    super.key,
    required this.candles,
    required this.signal,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0D191D),
        border: Border.all(color: const Color(0xFF26383D)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: CustomPaint(
        painter: _SmcChartPainter(candles, signal),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SmcChartPainter extends CustomPainter {
  final List<Candle> candles;
  final Signal? signal;

  const _SmcChartPainter(this.candles, this.signal);

  static const _up = Color(0xFF52D6A0);
  static const _down = Color(0xFFFF6B6B);
  static const _entry = Color(0xFF4FC3F7);
  static const _target = Color(0xFF69DB7C);
  static const _emaColor = Color(0xFFFFD166);

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width <= 0 || size.height <= 0) return;

    const left = 10.0;
    const top = 16.0;
    const right = 64.0;
    const bottom = 25.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      math.max(left + 1, size.width - right),
      math.max(top + 1, size.height - bottom),
    );
    final visibleStart = math.max(0, candles.length - 90);
    final visible = candles.sublist(visibleStart);
    final emaValues = _ema(candles, 200);
    var minPrice = visible.map((candle) => candle.low).reduce(math.min);
    var maxPrice = visible.map((candle) => candle.high).reduce(math.max);
    final selectedSignal = signal;
    if (selectedSignal != null) {
      for (final level in [
        selectedSignal.entry,
        selectedSignal.stop,
        selectedSignal.tp1,
        selectedSignal.tp2,
        selectedSignal.tp3,
      ]) {
        minPrice = math.min(minPrice, level);
        maxPrice = math.max(maxPrice, level);
      }
    }
    final padding = math.max(
      (maxPrice - minPrice) * 0.08,
      maxPrice.abs() * 0.0005,
    );
    minPrice -= padding;
    maxPrice += padding;
    if (maxPrice <= minPrice) maxPrice = minPrice + 1;

    double yFor(double price) =>
        plot.bottom - (price - minPrice) / (maxPrice - minPrice) * plot.height;

    final gridPaint = Paint()
      ..color = const Color(0xFF26383D)
      ..strokeWidth = 1;
    for (var index = 0; index <= 4; index++) {
      final y = plot.top + plot.height * index / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _drawText(
        canvas,
        _formatPrice(maxPrice - (maxPrice - minPrice) * index / 4),
        Offset(plot.right + 5, y - 7),
        const Color(0xFFA7B7BA),
        10,
      );
    }

    final slotWidth = plot.width / visible.length;
    final bodyWidth = math.min(8.0, math.max(2.0, slotWidth * 0.62));
    for (var visibleIndex = 0; visibleIndex < visible.length; visibleIndex++) {
      final candleIndex = visibleStart + visibleIndex;
      final candle = candles[candleIndex];
      final x = plot.left + slotWidth * (visibleIndex + 0.5);
      final color = candle.close >= candle.open ? _up : _down;
      final candlePaint = Paint()
        ..color = color
        ..strokeWidth = 1.2;
      canvas.drawLine(
        Offset(x, yFor(candle.high)),
        Offset(x, yFor(candle.low)),
        candlePaint,
      );
      final bodyTop = yFor(math.max(candle.open, candle.close));
      final bodyBottom = yFor(math.min(candle.open, candle.close));
      canvas.drawRect(
        Rect.fromLTRB(
          x - bodyWidth / 2,
          bodyTop,
          x + bodyWidth / 2,
          math.max(bodyTop + 1.5, bodyBottom),
        ),
        candlePaint,
      );
    }

    final emaPaint = Paint()
      ..color = _emaColor
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final emaPath = Path();
    for (var visibleIndex = 0; visibleIndex < visible.length; visibleIndex++) {
      final candleIndex = visibleStart + visibleIndex;
      final point = Offset(
        plot.left + slotWidth * (visibleIndex + 0.5),
        yFor(emaValues[candleIndex]),
      );
      if (visibleIndex == 0) {
        emaPath.moveTo(point.dx, point.dy);
      } else {
        emaPath.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(emaPath, emaPaint);

    if (selectedSignal != null) {
      _drawSignalLevel(
        canvas,
        plot,
        yFor,
        selectedSignal.entry,
        _entry,
        'ENTRY',
      );
      _drawSignalLevel(canvas, plot, yFor, selectedSignal.stop, _down, 'SL');
      _drawSignalLevel(canvas, plot, yFor, selectedSignal.tp1, _target, 'TP1');
      _drawSignalLevel(
        canvas,
        plot,
        yFor,
        selectedSignal.tp2,
        _target.withValues(alpha: 0.75),
        'TP2',
      );
      _drawSignalLevel(
        canvas,
        plot,
        yFor,
        selectedSignal.tp3,
        _target.withValues(alpha: 0.5),
        'TP3',
      );
    }
    _drawSmcAnnotations(canvas, plot, slotWidth, visibleStart, yFor);

    _drawText(
      canvas,
      'lebih lama',
      Offset(plot.left, plot.bottom + 7),
      const Color(0xFFA7B7BA),
      9,
    );
    _drawText(
      canvas,
      'terbaru',
      Offset(plot.right - 34, plot.bottom + 7),
      const Color(0xFFA7B7BA),
      9,
    );
  }

  void _drawSignalLevel(
    Canvas canvas,
    Rect plot,
    double Function(double) yFor,
    double price,
    Color color,
    String label,
  ) {
    final y = yFor(price);
    if (y < plot.top || y > plot.bottom) return;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), paint);
    _drawText(canvas, label, Offset(plot.left + 4, y - 13), color, 9);
  }

  void _drawSmcAnnotations(
    Canvas canvas,
    Rect plot,
    double slotWidth,
    int visibleStart,
    double Function(double) yFor,
  ) {
    final closedCount = candles.length - 1;
    if (closedCount < 4) return;
    final lastIndex = closedCount - 1;
    final previousIndex = closedCount - 2;
    final lookback = math.min(20, closedCount - 3);
    final priorStart = math.max(0, closedCount - lookback - 2);
    final priorEnd = closedCount - 2;
    var priorHigh = double.negativeInfinity;
    var priorLow = double.infinity;
    for (var index = priorStart; index < priorEnd; index++) {
      priorHigh = math.max(priorHigh, candles[index].high);
      priorLow = math.min(priorLow, candles[index].low);
    }

    final previous = candles[previousIndex];
    final last = candles[lastIndex];
    final bullishSweep = previous.low < priorLow && previous.close > priorLow;
    final bearishSweep =
        previous.high > priorHigh && previous.close < priorHigh;
    final bullishBos = last.close > priorHigh;
    final bearishBos = last.close < priorLow;
    final bullishFvg = last.low > candles[closedCount - 3].high;
    final bearishFvg = last.high < candles[closedCount - 3].low;

    void mark(int index, double price, String label, Color color) {
      if (index < visibleStart || index >= candles.length) return;
      final x = plot.left + slotWidth * (index - visibleStart + 0.5);
      final y = yFor(price);
      final paint = Paint()..color = color;
      final marker = Path()
        ..moveTo(x, y - 7)
        ..lineTo(x - 5, y + 2)
        ..lineTo(x + 5, y + 2)
        ..close();
      canvas.drawPath(marker, paint);
      _drawText(canvas, label, Offset(x + 5, y - 9), color, 9);
    }

    if (bullishSweep) mark(previousIndex, previous.low, 'Sweep', _entry);
    if (bearishSweep) mark(previousIndex, previous.high, 'Sweep', _down);
    if (bullishBos) mark(lastIndex, last.high, 'BOS', _up);
    if (bearishBos) mark(lastIndex, last.low, 'BOS', _down);

    if (bullishFvg || bearishFvg) {
      final firstIndex = closedCount - 3;
      final lower = bullishFvg ? candles[firstIndex].high : last.high;
      final upper = bullishFvg ? last.low : candles[firstIndex].low;
      final x1 = plot.left + slotWidth * math.max(0, firstIndex - visibleStart);
      final x2 = plot.left + slotWidth * (lastIndex - visibleStart + 1);
      final zone = Rect.fromLTRB(x1, yFor(upper), x2, yFor(lower));
      canvas.drawRect(
        zone,
        Paint()..color = (bullishFvg ? _up : _down).withValues(alpha: 0.14),
      );
      _drawText(
        canvas,
        'FVG',
        Offset(x1 + 3, zone.top + 2),
        bullishFvg ? _up : _down,
        9,
      );
    }
  }

  List<double> _ema(List<Candle> values, int period) {
    final multiplier = 2 / (period + 1);
    var current = values.first.close;
    final result = <double>[current];
    for (final candle in values.skip(1)) {
      current = multiplier * candle.close + (1 - multiplier) * current;
      result.add(current);
    }
    return result;
  }

  String _formatPrice(double value) =>
      value.abs() >= 100 ? value.toStringAsFixed(1) : value.toStringAsFixed(4);

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double fontSize,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _SmcChartPainter oldDelegate) =>
      !identical(candles, oldDelegate.candles) || signal != oldDelegate.signal;
}
