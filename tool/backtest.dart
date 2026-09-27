import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'package:gateio_smc_pro/models.dart';
import 'package:gateio_smc_pro/smc_engine.dart';

const base = 'https://fx-api.gateio.ws/api/v4';
const contractName = 'BTC_USDT';
const intervalSeconds = 900;
const warmupCandles = 220;
const days = 30;
const initialEquity = 10.0;
const riskPercent = 2.0;
const rr = 3.0;

Future<List<Candle>> loadCandles() async {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  final end = now - (now % intervalSeconds);
  final start = end - (days * 24 * 60 * 60) - (warmupCandles * intervalSeconds);
  final result = <Candle>[];
  var from = start;

  while (from < end) {
    final to = min(end, from + (999 * intervalSeconds));
    final uri = Uri.parse('$base/futures/usdt/candlesticks').replace(
      queryParameters: {
        'contract': contractName,
        'interval': '15m',
        'from': '$from',
        'to': '$to',
      },
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Candle API ${response.statusCode}: ${response.body}');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    if (data.isEmpty) break;
    result.addAll(data.map((e) => Candle.fromGate(
          Map<String, dynamic>.from(e as Map),
        )));
    final last = result.map((c) => c.time.millisecondsSinceEpoch ~/ 1000).reduce(max);
    from = last + intervalSeconds;
    if (data.length < 1000) break;
  }

  final unique = <int, Candle>{
    for (final candle in result)
      candle.time.millisecondsSinceEpoch ~/ 1000: candle,
  };
  final candles = unique.values.toList()
    ..sort((a, b) => a.time.compareTo(b.time));
  return candles;
}

Future<ContractInfo> loadContract() async {
  final response = await http.get(
    Uri.parse('$base/futures/usdt/contracts/$contractName'),
  );
  if (response.statusCode != 200) {
    throw Exception('Contract API ${response.statusCode}: ${response.body}');
  }
  return ContractInfo.fromJson(
    Map<String, dynamic>.from(jsonDecode(response.body) as Map),
  );
}

String money(double value) => value.toStringAsFixed(4);

Future<void> main() async {
  final candles = await loadCandles();
  final info = await loadContract();
  final end = DateTime.now().toUtc();
  final start = end.subtract(const Duration(days: days));
  final engine = const SmcEngine();
  var equity = initialEquity;
  var wins = 0;
  var losses = 0;
  var skipped = 0;
  var maxEquity = equity;
  var maxDrawdown = 0.0;
  final trades = <Map<String, Object>>[];

  for (var i = warmupCandles + 1; i < candles.length - 1;) {
    final signalTime = candles[i - 1].time;
    if (signalTime.isBefore(start)) {
      i++;
      continue;
    }

    final windowStart = max(0, i - 219);
    final signal = engine.analyze(
      contract: contractName,
      candles: candles.sublist(windowStart, i + 1),
      equity: equity,
      info: info,
      riskPercent: riskPercent,
      rr: rr,
    );
    if (signal == null) {
      i++;
      continue;
    }

    var exitIndex = -1;
    var win = false;
    var exitPrice = signal.entry;
    for (var j = i; j < candles.length; j++) {
      final candle = candles[j];
      final stopHit = signal.side == 'BUY'
          ? candle.low <= signal.stop
          : candle.high >= signal.stop;
      final targetHit = signal.side == 'BUY'
          ? candle.high >= signal.tp
          : candle.low <= signal.tp;
      if (stopHit || targetHit) {
        exitIndex = j;
        win = !stopHit;
        exitPrice = win ? signal.tp : signal.stop;
        break;
      }
    }
    if (exitIndex < 0) break;

    final riskAmount = equity * riskPercent / 100;
    final pnl = win ? riskAmount * rr : -riskAmount;
    equity += pnl;
    maxEquity = max(maxEquity, equity);
    maxDrawdown = max(maxDrawdown, (maxEquity - equity) / maxEquity);
    if (win) {
      wins++;
    } else {
      losses++;
    }
    trades.add({
      'time': signalTime.toIso8601String(),
      'side': signal.side,
      'result': win ? 'WIN' : 'LOSS',
      'entry': signal.entry,
      'exit': exitPrice,
      'equity': equity,
    });
    i = exitIndex + 1;
  }

  final total = wins + losses;
  final elapsedDays = days.toDouble();
  final tradesPerDay = total / elapsedDays;
  stdout.writeln('BACKTEST $contractName 15m ${start.toIso8601String()} -> ${end.toIso8601String()}');
  stdout.writeln('Initial equity: ${money(initialEquity)} USDT');
  stdout.writeln('Final equity: ${money(equity)} USDT');
  stdout.writeln('Return: ${money((equity / initialEquity - 1) * 100)}%');
  stdout.writeln('Trades: $total ($wins wins, $losses losses, $skipped skipped)');
  stdout.writeln('Win rate: ${total == 0 ? '0.00' : money(wins * 100 / total)}%');
  stdout.writeln('Average trades/day: ${money(tradesPerDay)} (requested target: 50)');
  stdout.writeln('Max drawdown: ${money(maxDrawdown * 100)}%');
  stdout.writeln('First trade: ${trades.isEmpty ? 'none' : trades.first}');
  stdout.writeln('Last trade: ${trades.isEmpty ? 'none' : trades.last}');
}
