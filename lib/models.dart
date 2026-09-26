class Candle {
  final DateTime time;
  final double open, high, low, close, volume;

  const Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  factory Candle.fromGate(Map<String, dynamic> j) => Candle(
        time: DateTime.fromMillisecondsSinceEpoch(
            ((double.tryParse('${j['t']}') ?? 0) * 1000).round(),
            isUtc: true),
        open: double.parse('${j['o']}'),
        high: double.parse('${j['h']}'),
        low: double.parse('${j['l']}'),
        close: double.parse('${j['c']}'),
        volume: double.tryParse('${j['v'] ?? 0}') ?? 0,
      );
}

class ContractInfo {
  final String name;
  final double quantoMultiplier;
  final double orderSizeMin;
  final double orderSizeMax;
  final double markPrice;
  final String state;

  const ContractInfo({
    required this.name,
    required this.quantoMultiplier,
    required this.orderSizeMin,
    required this.orderSizeMax,
    required this.markPrice,
    required this.state,
  });

  factory ContractInfo.fromJson(Map<String, dynamic> j) => ContractInfo(
        name: '${j['name']}',
        quantoMultiplier:
            double.tryParse('${j['quanto_multiplier'] ?? 1}') ?? 1,
        orderSizeMin: double.tryParse('${j['order_size_min'] ?? 1}') ?? 1,
        orderSizeMax: double.tryParse('${j['order_size_max'] ?? 0}') ?? 0,
        markPrice: double.tryParse('${j['mark_price'] ?? 0}') ?? 0,
        state: '${j['status'] ?? j['in_delisting'] ?? 'normal'}',
      );
}

class Signal {
  final String contract;
  final String side;
  final double entry, stop, tp;
  final double riskAmount;
  final double size;
  final int score;
  final List<String> reasons;

  const Signal({
    required this.contract,
    required this.side,
    required this.entry,
    required this.stop,
    required this.tp,
    required this.riskAmount,
    required this.size,
    required this.score,
    required this.reasons,
  });
}

class PositionInfo {
  final String contract;
  final double size;
  final double entryPrice;
  final double markPrice;
  final double unrealisedPnl;
  final String leverage;
  final String marginMode;

  const PositionInfo({
    required this.contract,
    required this.size,
    required this.entryPrice,
    required this.markPrice,
    required this.unrealisedPnl,
    required this.leverage,
    required this.marginMode,
  });

  factory PositionInfo.fromJson(Map<String, dynamic> j) => PositionInfo(
        contract: '${j['contract']}',
        size: double.tryParse('${j['size'] ?? 0}') ?? 0,
        entryPrice: double.tryParse('${j['entry_price'] ?? 0}') ?? 0,
        markPrice: double.tryParse('${j['mark_price'] ?? 0}') ?? 0,
        unrealisedPnl:
            double.tryParse('${j['unrealised_pnl'] ?? 0}') ?? 0,
        leverage: '${j['lever'] ?? j['leverage'] ?? '0'}',
        marginMode: '${j['pos_margin_mode'] ?? 'unknown'}',
      );
}

class BotSettings {
  final bool testnet;
  final bool dryRun;
  final double riskPercent;
  final double rr;
  final int leverage;
  final int maxPositions;
  final String interval;
  final int scanSeconds;

  const BotSettings({
    this.testnet = true,
    this.dryRun = true,
    this.riskPercent = 2.0,
    this.rr = 3.0,
    this.leverage = 15,
    this.maxPositions = 3,
    this.interval = '15m',
    this.scanSeconds = 60,
  });

  BotSettings copyWith({
    bool? testnet,
    bool? dryRun,
    double? riskPercent,
    double? rr,
    int? leverage,
    int? maxPositions,
    String? interval,
    int? scanSeconds,
  }) =>
      BotSettings(
        testnet: testnet ?? this.testnet,
        dryRun: dryRun ?? this.dryRun,
        riskPercent: riskPercent ?? this.riskPercent,
        rr: rr ?? this.rr,
        leverage: leverage ?? this.leverage,
        maxPositions: maxPositions ?? this.maxPositions,
        interval: interval ?? this.interval,
        scanSeconds: scanSeconds ?? this.scanSeconds,
      );
}
