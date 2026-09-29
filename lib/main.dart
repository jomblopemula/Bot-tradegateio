import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'gate_api.dart';
import 'gate_stream.dart';
import 'models.dart';
import 'notification_service.dart';
import 'order_manager.dart';
import 'smc_chart.dart';
import 'smc_engine.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const GateSmcApp());
}

class GateSmcApp extends StatelessWidget {
  const GateSmcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SMC FUTURES AI TRADER',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC4E86B),
          brightness: Brightness.dark,
          surface: const Color(0xFF101715),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF090E0C),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF090E0C),
          surfaceTintColor: Colors.transparent,
        ),
        tabBarTheme: const TabBarThemeData(
          indicatorColor: Color(0xFFC4E86B),
          labelColor: Color(0xFFC4E86B),
          unselectedLabelColor: Color(0xFF91A098),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF111916),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF29362F)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF29362F)),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const storage = FlutterSecureStorage();
  static const intervals = ['1m', '5m', '15m', '30m', '1h', '4h', '1d'];

  final apiKey = TextEditingController();
  final apiSecret = TextEditingController();
  final marketSearch = TextEditingController();

  // Default sesuai kebutuhan:
  // 2% modal/equity per posisi
  final risk = TextEditingController(text: '2');

  // Risk reward 1:3
  final rr = TextEditingController(text: '3');

  final maxPos = TextEditingController(text: '5');

  // Scan setiap 60 detik
  final scan = TextEditingController(text: '60');

  bool testnet = true;
  bool dryRun = true;
  bool running = false;
  bool notificationsEnabled = true;
  bool notificationPermissionGranted = false;

  int leverage = 15;
  String selectedInterval = '15m';

  double equity = 0;
  double availableBalance = 0;

  String status = 'Belum terhubung';

  Timer? timer;
  bool scanInProgress = false;

  GateApi? api;

  final engine = const SmcEngine();
  final notificationService = NotificationService();

  final logs = <String>[];
  final signals = <Signal>[];
  final favoriteMarkets = <String>{};
  List<ContractInfo> markets = [];
  List<Candle> chartCandles = [];
  String selectedMarket = 'BTC_USDT';
  Signal? chartSignal;
  bool chartLoading = false;
  String? chartError;
  String chartFeedStatus = 'REST';
  bool chartRealtimeConnected = false;
  bool showFavoritesOnly = false;
  int _chartRequestId = 0;
  WebSocketChannel? _candleChannel;
  StreamSubscription<dynamic>? _candleSubscription;
  Timer? _candlePingTimer;
  Timer? _candleSubscribeTimer;
  Timer? _candleReconnectTimer;
  Timer? _candleFallbackTimer;
  int _candleReconnectAttempts = 0;
  bool _restFallbackInProgress = false;
  bool _disposed = false;

  List<PositionInfo> positions = [];
  final processedSignalIds = <String>{};

  // ============================================================
  // LOG
  // ============================================================

  void log(String message) {
    if (!mounted) return;

    setState(() {
      logs.insert(
        0,
        '${DateTime.now().toLocal().toString().substring(0, 19)}  $message',
      );

      if (logs.length > 120) {
        logs.removeLast();
      }
    });
  }

  String _safeErrorDetails(Object error) {
    var detail = error is GateApiException
        ? error.diagnostic
        : error.toString();
    for (final secret in [apiKey.text.trim(), apiSecret.text.trim()]) {
      if (secret.isNotEmpty) detail = detail.replaceAll(secret, '[REDACTED]');
    }
    if (detail.length > 280) detail = '${detail.substring(0, 280)}...';
    return detail;
  }

  void logError(
    String operation,
    Object error, {
    String? contract,
    String? orderId,
  }) {
    final detail = _safeErrorDetails(error);
    final context = [
      if (contract != null) 'contract=$contract',
      if (orderId != null) 'order=$orderId',
    ].join(' ');
    log('ERROR [$operation]${context.isEmpty ? '' : ' $context'}: $detail');
  }

  Future<OrderFillVerification> _verifyOrderWithRetries({
    required String contract,
    required String orderId,
    required String side,
  }) async {
    final currentApi = api;
    if (currentApi == null) return _inconclusiveOrderVerification();

    var latest = _inconclusiveOrderVerification();
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final order = await currentApi.orderStatus(
          contract: contract,
          orderId: orderId,
        );
        positions = await currentApi.positions();
        latest = verifyFuturesOrder(
          order: order,
          positions: positions,
          contract: contract,
          side: side,
        );
        log(
          'ORDER CHECK ${attempt + 1}/3 $contract: ${latest.state.name} '
          'status=${latest.orderStatus} finish=${latest.finishAs} '
          'filled=${latest.filledSize} position=${latest.matchingPositionFound}',
        );
        if (!latest.shouldRetry) return latest;
      } catch (error) {
        logError('order.verify', error, contract: contract, orderId: orderId);
      }

      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    return latest;
  }

  OrderFillVerification _inconclusiveOrderVerification() =>
      const OrderFillVerification(
        state: OrderFillState.inconclusive,
        orderStatus: 'unknown',
        finishAs: 'unknown',
        orderSize: null,
        leftSize: null,
        filledSize: 0,
        matchingPositionFound: false,
      );

  // ============================================================
  // LOAD SETTINGS
  // ============================================================

  Future<void> loadSaved() async {
    apiKey.text = await storage.read(key: 'api_key') ?? '';
    apiSecret.text = await storage.read(key: 'api_secret') ?? '';

    testnet = (await storage.read(key: 'testnet')) != 'false';
    dryRun = (await storage.read(key: 'dry_run')) != 'false';
    notificationsEnabled =
        (await storage.read(key: 'notifications_enabled')) != 'false';
    selectedInterval = await storage.read(key: 'interval') ?? '15m';
    if (!intervals.contains(selectedInterval)) selectedInterval = '15m';
    selectedMarket = await storage.read(key: 'selected_market') ?? 'BTC_USDT';
    final savedFavorites = await storage.read(key: 'favorite_markets');
    favoriteMarkets
      ..clear()
      ..addAll(
        (savedFavorites ?? '').split(',').where((symbol) => symbol.isNotEmpty),
      );
    processedSignalIds.addAll(
      (await storage.read(key: 'processed_signal_ids') ?? '')
          .split('\n')
          .where((id) => id.isNotEmpty),
    );
    api?.dispose();
    api = GateApi(
      apiKey: apiKey.text.trim(),
      apiSecret: apiSecret.text.trim(),
      testnet: testnet,
    );

    await notificationService.initialize();
    if (notificationsEnabled) {
      notificationPermissionGranted = await notificationService
          .requestPermission();
    }

    if (!mounted) return;

    setState(() {});
    unawaited(refreshMarkets());
  }

  @override
  void initState() {
    super.initState();

    loadSaved();
  }

  Future<void> refreshMarkets() async {
    final currentApi = api;
    if (currentApi == null) return;

    try {
      final fetchedMarkets = await currentApi.contracts();
      if (!mounted) return;

      setState(() {
        markets = fetchedMarkets;
        if (!fetchedMarkets.any((market) => market.name == selectedMarket)) {
          selectedMarket = fetchedMarkets
              .firstWhere(
                (market) => market.name == 'BTC_USDT',
                orElse: () => fetchedMarkets.firstWhere(
                  (market) => market.isActive,
                  orElse: () => fetchedMarkets.first,
                ),
              )
              .name;
        }
        chartError = fetchedMarkets.isEmpty
            ? 'No futures markets available.'
            : null;
      });
      if (fetchedMarkets.isNotEmpty) unawaited(loadSelectedChart());
    } catch (error) {
      if (!mounted) return;
      setState(() => chartError = 'Market load failed: $error');
    }
  }

  Future<void> loadSelectedChart() async {
    final currentApi = api;
    if (currentApi == null || selectedMarket.isEmpty) return;

    final requestId = ++_chartRequestId;
    final market = selectedMarket;
    final interval = selectedInterval;
    _stopCandleStream();
    if (mounted) {
      setState(() {
        chartLoading = true;
        chartError = null;
        chartSignal = null;
        chartCandles = [];
        chartRealtimeConnected = false;
        chartFeedStatus = 'CONNECTING';
      });
    }

    try {
      final candles = await currentApi.candles(market, interval, limit: 220);
      if (!mounted || requestId != _chartRequestId) return;

      setState(() {
        chartCandles = candles;
        chartSignal = _analyzeChart(candles, market);
        chartLoading = false;
        chartError = candles.isEmpty
            ? 'No candles returned for $market.'
            : null;
      });
      unawaited(_connectCandleStream(market, interval, requestId));
    } catch (error) {
      if (!mounted || requestId != _chartRequestId) return;
      setState(() {
        chartLoading = false;
        chartError = 'Candle load failed: $error';
        chartFeedStatus = 'CONNECTING';
      });
      logError('candles.history', error, contract: market);
      unawaited(_connectCandleStream(market, interval, requestId));
    }
  }

  Signal? _analyzeChart(List<Candle> candles, String market) {
    if (equity <= 0) return null;
    final contract = markets.firstWhere(
      (item) => item.name == market,
      orElse: () => ContractInfo(
        name: market,
        quantoMultiplier: 1,
        orderSizeMin: 1,
        orderSizeMax: 0,
        markPrice: candles.isEmpty ? 0 : candles.last.close,
        state: 'unknown',
      ),
    );
    if (!contract.isActive) return null;
    return engine.analyze(
      contract: market,
      candles: candles,
      equity: equity,
      info: contract,
      riskPercent: settings.riskPercent,
      rr: settings.rr,
    );
  }

  Future<void> _connectCandleStream(
    String market,
    String interval,
    int requestId,
  ) async {
    if (_disposed || !mounted || requestId != _chartRequestId) return;

    final socketUrl = testnet
        ? 'wss://fx-ws-testnet.gateio.ws/v4/ws/usdt'
        : 'wss://fx-ws.gateio.ws/v4/ws/usdt';
    WebSocketChannel? channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(socketUrl));
      _candleChannel = channel;
      await channel.ready.timeout(const Duration(seconds: 10));
      if (_disposed || !mounted || requestId != _chartRequestId) {
        if (identical(_candleChannel, channel)) _candleChannel = null;
        await channel.sink.close();
        return;
      }

      channel.sink.add(
        jsonEncode({
          'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'channel': 'futures.candlesticks',
          'event': 'subscribe',
          'payload': [interval, market],
        }),
      );
      _candlePingTimer?.cancel();
      _candlePingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (!identical(_candleChannel, channel)) return;
        try {
          channel!.sink.add(
            jsonEncode({
              'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
              'channel': 'futures.ping',
            }),
          );
        } catch (error) {
          logError('candles.websocket.ping', error, contract: market);
          _scheduleCandleReconnect(market, interval, requestId, channel);
        }
      });
      _candleSubscribeTimer?.cancel();
      _candleSubscribeTimer = Timer(const Duration(seconds: 10), () {
        if (requestId == _chartRequestId && !chartRealtimeConnected) {
          _scheduleCandleReconnect(market, interval, requestId, channel);
        }
      });
      _candleSubscription = channel.stream.listen(
        (message) => _handleCandleFrame(
          message,
          market: market,
          interval: interval,
          requestId: requestId,
        ),
        onError: (Object error) {
          logError('candles.websocket', error, contract: market);
          _scheduleCandleReconnect(market, interval, requestId, channel!);
        },
        onDone: () =>
            _scheduleCandleReconnect(market, interval, requestId, channel!),
        cancelOnError: true,
      );
    } catch (error) {
      if (channel != null) unawaited(channel.sink.close());
      if (requestId == _chartRequestId) {
        logError('candles.websocket.connect', error, contract: market);
        _scheduleCandleReconnect(market, interval, requestId, channel);
      }
    }
  }

  void _handleCandleFrame(
    Object message, {
    required String market,
    required String interval,
    required int requestId,
  }) {
    if (!mounted || requestId != _chartRequestId) return;
    final frame = parseGateCandlestickFrame(
      message,
      contract: market,
      interval: interval,
    );
    if (frame.subscriptionError != null) {
      logError(
        'candles.websocket.subscribe',
        StateError(frame.subscriptionError!),
        contract: market,
      );
      _scheduleCandleReconnect(market, interval, requestId, _candleChannel);
      return;
    }
    if (frame.subscribed || frame.candles.isNotEmpty) {
      _candleReconnectAttempts = 0;
      _candleReconnectTimer?.cancel();
      _candleSubscribeTimer?.cancel();
      _candleFallbackTimer?.cancel();
      setState(() {
        chartRealtimeConnected = true;
        chartFeedStatus = 'REALTIME';
      });
    }
    if (frame.candles.isEmpty) return;

    final candles = mergeGateCandles(chartCandles, frame.candles);
    setState(() {
      chartCandles = candles;
      chartSignal = _analyzeChart(candles, market);
      chartError = null;
    });
  }

  void _scheduleCandleReconnect(
    String market,
    String interval,
    int requestId,
    WebSocketChannel? sourceChannel,
  ) {
    if (_disposed || !mounted || requestId != _chartRequestId) return;
    if (sourceChannel != null && !identical(_candleChannel, sourceChannel)) {
      return;
    }
    _candlePingTimer?.cancel();
    _candleSubscribeTimer?.cancel();
    final subscription = _candleSubscription;
    _candleSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _candleChannel = null;
    if (sourceChannel != null) unawaited(sourceChannel.sink.close());
    if (mounted) {
      setState(() {
        chartRealtimeConnected = false;
        chartFeedStatus = 'REST FALLBACK · RECONNECTING';
      });
    }
    _startCandleRestFallback(market, interval, requestId);
    if (_candleReconnectTimer?.isActive ?? false) return;

    const delays = [1, 2, 4, 8, 16, 30];
    final delayIndex = _candleReconnectAttempts
        .clamp(0, delays.length - 1)
        .toInt();
    final delay = delays[delayIndex];
    _candleReconnectAttempts++;
    _candleReconnectTimer = Timer(Duration(seconds: delay), () {
      unawaited(_connectCandleStream(market, interval, requestId));
    });
  }

  void _startCandleRestFallback(String market, String interval, int requestId) {
    if (_candleFallbackTimer?.isActive ?? false) return;
    _candleFallbackTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_pollLatestCandles(market, interval, requestId));
    });
    unawaited(_pollLatestCandles(market, interval, requestId));
  }

  Future<void> _pollLatestCandles(
    String market,
    String interval,
    int requestId,
  ) async {
    if (_restFallbackInProgress ||
        chartRealtimeConnected ||
        requestId != _chartRequestId) {
      return;
    }
    final currentApi = api;
    if (currentApi == null) return;
    _restFallbackInProgress = true;
    try {
      final updates = await currentApi.candles(market, interval, limit: 3);
      if (!mounted ||
          requestId != _chartRequestId ||
          chartRealtimeConnected ||
          updates.isEmpty) {
        return;
      }
      final candles = mergeGateCandles(chartCandles, updates);
      setState(() {
        chartCandles = candles;
        chartSignal = _analyzeChart(candles, market);
        chartError = null;
        chartFeedStatus = 'REST FALLBACK';
      });
    } catch (error) {
      if (requestId == _chartRequestId) {
        logError('candles.rest-fallback', error, contract: market);
      }
    } finally {
      _restFallbackInProgress = false;
    }
  }

  void _stopCandleStream() {
    _candlePingTimer?.cancel();
    _candleSubscribeTimer?.cancel();
    _candleReconnectTimer?.cancel();
    _candleFallbackTimer?.cancel();
    final subscription = _candleSubscription;
    _candleSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    final channel = _candleChannel;
    _candleChannel = null;
    if (channel != null) unawaited(channel.sink.close());
  }

  Future<void> setChartInterval(String interval) async {
    if (selectedInterval == interval) return;
    setState(() => selectedInterval = interval);
    await storage.write(key: 'interval', value: interval);
    await loadSelectedChart();
  }

  Future<void> _toggleFavorite(String market) async {
    setState(() {
      if (!favoriteMarkets.add(market)) favoriteMarkets.remove(market);
    });
    await storage.write(
      key: 'favorite_markets',
      value: favoriteMarkets.join(','),
    );
  }

  Future<void> _pickMarket() async {
    marketSearch.clear();
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101715),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final query = marketSearch.text.trim().toUpperCase();
            final filteredMarkets =
                markets.where((market) {
                  final matchesQuery =
                      query.isEmpty ||
                      market.name.toUpperCase().contains(query);
                  final matchesFavorite =
                      !showFavoritesOnly ||
                      favoriteMarkets.contains(market.name);
                  return matchesQuery && matchesFavorite;
                }).toList()..sort((left, right) {
                  if (left.isActive != right.isActive) {
                    return left.isActive ? -1 : 1;
                  }
                  return left.name.compareTo(right.name);
                });

            return SafeArea(
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.82,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: TextField(
                        controller: marketSearch,
                        autofocus: true,
                        onChanged: (_) => setSheetState(() {}),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search USDT perpetual markets',
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Text('${filteredMarkets.length} markets'),
                          const Spacer(),
                          FilterChip(
                            label: const Text('Favorites'),
                            selected: showFavoritesOnly,
                            onSelected: (value) {
                              setState(() => showFavoritesOnly = value);
                              setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filteredMarkets.length,
                        itemBuilder: (context, index) {
                          final market = filteredMarkets[index];
                          final favorite = favoriteMarkets.contains(
                            market.name,
                          );
                          return ListTile(
                            title: Text(market.name),
                            subtitle: Text(
                              market.isActive ? 'ACTIVE' : 'NON ACTIVE',
                              style: TextStyle(
                                color: market.isActive
                                    ? const Color(0xFFC4E86B)
                                    : const Color(0xFFFF8C7A),
                                fontSize: 11,
                              ),
                            ),
                            trailing: IconButton(
                              tooltip: favorite
                                  ? 'Remove favorite'
                                  : 'Add favorite',
                              onPressed: () async {
                                await _toggleFavorite(market.name);
                                setSheetState(() {});
                              },
                              icon: Icon(
                                favorite ? Icons.star : Icons.star_border,
                                color: favorite
                                    ? const Color(0xFFC4E86B)
                                    : null,
                              ),
                            ),
                            onTap: () =>
                                Navigator.pop(sheetContext, market.name),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    marketSearch.clear();
    if (selected == null || selected == selectedMarket) return;

    setState(() => selectedMarket = selected);
    await storage.write(key: 'selected_market', value: selected);
    await loadSelectedChart();
  }

  // ============================================================
  // SAVE + TEST CONNECTION
  // ============================================================

  Future<void> saveAndTest() async {
    try {
      await storage.write(key: 'api_key', value: apiKey.text.trim());

      await storage.write(key: 'api_secret', value: apiSecret.text.trim());

      await storage.write(key: 'testnet', value: '$testnet');

      await storage.write(key: 'dry_run', value: '$dryRun');

      await storage.write(key: 'interval', value: selectedInterval);

      api?.dispose();
      _stopCandleStream();

      api = GateApi(
        apiKey: apiKey.text.trim(),
        apiSecret: apiSecret.text.trim(),
        testnet: testnet,
      );

      await api!.testConnection();

      final acc = await api!.futuresAccount();

      equity = double.tryParse('${acc['total'] ?? acc['available'] ?? 0}') ?? 0;
      availableBalance =
          double.tryParse('${acc['available'] ?? acc['total'] ?? 0}') ?? 0;

      positions = await api!.positions();

      if (!mounted) return;

      setState(() {
        status = 'Terhubung • Equity ${equity.toStringAsFixed(2)} USDT';
      });

      log('Connection OK • ${testnet ? 'TESTNET' : 'LIVE'}');
      unawaited(refreshMarkets());
    } catch (e) {
      if (!mounted) return;

      setState(() {
        status = 'Gagal: ${_safeErrorDetails(e)}';
      });

      logError('connection.test', e);
    }
  }

  // ============================================================
  // BOT SETTINGS
  // ============================================================

  BotSettings get settings {
    return BotSettings(
      testnet: testnet,
      dryRun: dryRun,
      riskPercent: double.tryParse(risk.text) ?? 2,
      rr: double.tryParse(rr.text) ?? 3,
      leverage: leverage,
      maxPositions: int.tryParse(maxPos.text) ?? 5,
      scanSeconds: int.tryParse(scan.text) ?? 60,
      interval: selectedInterval,
    );
  }

  // ============================================================
  // START / STOP BOT
  // ============================================================

  Future<void> toggleBot() async {
    // ----------------------------------------------------------
    // STOP
    // ----------------------------------------------------------

    if (running) {
      timer?.cancel();

      if (!mounted) return;

      setState(() {
        running = false;
      });

      log('BOT STOPPED');

      return;
    }

    // ----------------------------------------------------------
    // CONNECTION
    // ----------------------------------------------------------

    if (api == null) {
      await saveAndTest();

      if (!mounted) return;

      if (api == null) {
        return;
      }
    }

    // ----------------------------------------------------------
    // LIVE CONFIRMATION
    // ----------------------------------------------------------

    if (!settings.dryRun && settings.testnet == false) {
      final ok =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) {
              return AlertDialog(
                title: const Text('Konfirmasi LIVE'),
                content: const Text(
                  'Mode LIVE akan mengirim order ke Gate.io. '
                  'Pastikan API key hanya memiliki izin yang diperlukan, '
                  'dan uji TESTNET/DRY-RUN terlebih dahulu.',
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext, false);
                    },
                    child: const Text('BATAL'),
                  ),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(dialogContext, true);
                    },
                    child: const Text('LANJUT'),
                  ),
                ],
              );
            },
          ) ??
          false;

      if (!mounted) return;

      if (!ok) {
        return;
      }
    }

    // ----------------------------------------------------------
    // START
    // ----------------------------------------------------------

    if (!mounted) return;

    setState(() {
      running = true;
    });

    log(
      'BOT STARTED • '
      '${settings.dryRun ? 'DRY-RUN' : 'ORDER ENABLED'}',
    );

    // Jalankan scan pertama langsung
    await scanOnce();

    if (!mounted || !running) {
      return;
    }

    // ----------------------------------------------------------
    // TIMER
    // ----------------------------------------------------------

    timer = Timer.periodic(
      Duration(seconds: settings.scanSeconds.clamp(15, 3600)),
      (_) {
        scanOnce();
      },
    );
  }

  // ============================================================
  // SCAN MARKET
  // ============================================================

  Future<void> scanOnce() async {
    if (api == null || scanInProgress) {
      return;
    }
    scanInProgress = true;

    try {
      // --------------------------------------------------------
      // GET CONTRACTS
      // --------------------------------------------------------

      final list = await api!.contracts();
      final activeMarkets = list
          .where((contract) => contract.isActive)
          .toList();
      log('Market scan: ${activeMarkets.length} active / ${list.length} total');

      final account = await api!.futuresAccount();
      equity =
          double.tryParse('${account['total'] ?? account['available'] ?? 0}') ??
          0;
      availableBalance =
          double.tryParse('${account['available'] ?? account['total'] ?? 0}') ??
          0;

      // --------------------------------------------------------
      // GET POSITIONS
      // --------------------------------------------------------

      positions = await api!.positions();

      final active = positions.length;

      if (mounted) {
        setState(() {});
      }

      // --------------------------------------------------------
      // MAX POSITIONS
      // --------------------------------------------------------

      final limit = settings.maxPositions;

      if (active >= limit) {
        log('Max positions reached: $active/$limit');

        return;
      }

      // --------------------------------------------------------
      // BATCH SCAN
      // --------------------------------------------------------

      final batch = activeMarkets;

      for (final c in batch) {
        if (!running) {
          break;
        }

        // Jangan entry contract yang sudah punya posisi
        if (positions.any((p) => p.contract == c.name)) {
          continue;
        }

        var orderSubmitted = false;
        var stage = 'candles.fetch';
        try {
          // ----------------------------------------------------
          // GET CANDLES
          // ----------------------------------------------------

          final candles = await api!.candles(c.name, settings.interval);

          // ----------------------------------------------------
          // SMC ENGINE
          // ----------------------------------------------------

          stage = 'signal.analyze';
          final signal = engine.analyze(
            contract: c.name,
            candles: candles,
            equity: equity,
            info: c,
            riskPercent: settings.riskPercent,
            rr: settings.rr,
          );

          if (signal == null) {
            continue;
          }

          final closedCandle = candles[candles.length - 2];
          final signalId =
              '${c.name}|${settings.interval}|'
              '${closedCandle.time.toUtc().millisecondsSinceEpoch}|${signal.side}';
          if (!processedSignalIds.add(signalId)) {
            continue;
          }
          if (processedSignalIds.length > 500) {
            processedSignalIds.remove(processedSignalIds.first);
          }
          stage = 'signal.persist';
          await storage.write(
            key: 'processed_signal_ids',
            value: processedSignalIds.join('\n'),
          );

          // ----------------------------------------------------
          // SAVE SIGNAL
          // ----------------------------------------------------

          signals.insert(0, signal);

          if (signals.length > 30) {
            signals.removeLast();
          }

          log(
            '${signal.side} ${signal.contract} '
            'Entry ${signal.entry} '
            'SL ${signal.stop} '
            'TP1 ${signal.tp1} TP2 ${signal.tp2} TP3 ${signal.tp3} '
            'setup ${signal.score}/100',
          );

          if (notificationsEnabled && notificationPermissionGranted) {
            try {
              await notificationService.showSignal(signal);
            } catch (e) {
              log('NOTIFICATION ERROR: $e');
            }
          }

          // ----------------------------------------------------
          // DRY RUN
          // ----------------------------------------------------

          if (settings.dryRun) {
            continue;
          }

          if (equity <= 0) {
            log(
              'ORDER SKIPPED ${signal.contract}: '
              'equity belum tersedia',
            );
            continue;
          }

          // ----------------------------------------------------
          // MAX POSITION CHECK
          // ----------------------------------------------------

          if (positions.length >= settings.maxPositions) {
            break;
          }

          final estimatedMargin =
              signal.size *
              signal.entry *
              c.quantoMultiplier /
              settings.leverage;
          if (availableBalance <= 0 || estimatedMargin > availableBalance) {
            log(
              'ORDER SKIPPED ${signal.contract}: '
              'insufficient available balance',
            );
            continue;
          }

          // ----------------------------------------------------
          // SET ISOLATED LEVERAGE
          // ----------------------------------------------------

          stage = 'leverage.set';
          await api!.setIsolatedLeverage(signal.contract, settings.leverage);

          // ----------------------------------------------------
          // ORDER SIZE
          // ----------------------------------------------------

          final signedSize = signal.side == 'BUY' ? signal.size : -signal.size;

          final id =
              't-smc-${DateTime.now().millisecondsSinceEpoch % 100000000}';

          // ----------------------------------------------------
          // PLACE MARKET ORDER
          // ----------------------------------------------------

          stage = 'order.submit';
          orderSubmitted = true;
          final result = await api!.placeMarketOrder(
            contract: signal.contract,
            size: signedSize,
            tp: signal.tp,
            sl: signal.stop,
            clientId: id,
          );
          final orderId = '${result['id'] ?? ''}';
          if (orderId.isEmpty) {
            throw StateError('Gate.io did not return an order id');
          }
          stage = 'order.verify';
          final verification = await _verifyOrderWithRetries(
            contract: signal.contract,
            orderId: orderId,
            side: signal.side,
          );

          if (verification.state == OrderFillState.noFill) {
            log(
              'ORDER NO FILL ${signal.contract}: '
              'finish=${verification.finishAs} '
              'status=${verification.orderStatus}',
            );
            continue;
          }

          if (!verification.isVerifiedFill) {
            timer?.cancel();
            running = false;
            if (mounted) {
              setState(
                () => status = 'SAFE MODE • Order/position inconclusive',
              );
            }
            log(
              'SAFE MODE ${signal.contract}: order $orderId '
              'could not be reconciled after 3 attempts',
            );
            break;
          }

          log(
            'ORDER VERIFIED ${signal.contract}: id $orderId '
            'state=${verification.state.name} '
            'filled=${verification.filledSize}',
          );
        } catch (e) {
          logError(stage, e, contract: c.name);
          if (orderSubmitted) {
            timer?.cancel();
            running = false;
            if (mounted) {
              setState(() => status = 'SAFE MODE • Order verification failed');
            }
            log('SAFE MODE: order result could not be reconciled');
            break;
          }
        }

        if (positions.length >= settings.maxPositions) {
          break;
        }
      }

      // --------------------------------------------------------
      // UPDATE UI
      // --------------------------------------------------------

      if (!mounted) return;

      setState(() {});
    } catch (e) {
      timer?.cancel();
      if (mounted) {
        setState(() {
          running = false;
          status = 'SAFE MODE • Account/position sync failed';
        });
      }
      logError('account.position.reconcile', e);
      log('SAFE MODE: scanner paused after account/position sync failure');
    } finally {
      scanInProgress = false;
    }
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _disposed = true;
    _chartRequestId++;
    _stopCandleStream();
    timer?.cancel();

    api?.dispose();

    apiKey.dispose();
    apiSecret.dispose();
    marketSearch.dispose();
    risk.dispose();
    rr.dispose();
    maxPos.dispose();
    scan.dispose();

    super.dispose();
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('SMC FUTURES AI TRADER'),
          actions: [
            Icon(
              running ? Icons.monitor_heart : Icons.circle_outlined,
              color: running
                  ? const Color(0xFFC4E86B)
                  : const Color(0xFF75847A),
            ),
            const SizedBox(width: 12),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(icon: Icon(Icons.dashboard), text: 'Dashboard'),
              Tab(icon: Icon(Icons.candlestick_chart), text: 'Signals'),
              Tab(icon: Icon(Icons.show_chart), text: 'Chart'),
              Tab(icon: Icon(Icons.account_balance_wallet), text: 'Positions'),
              Tab(icon: Icon(Icons.settings), text: 'Settings'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _dashboard(),
            _signals(),
            _chart(),
            _positions(),
            _settings(),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // DASHBOARD
  // ============================================================

  Widget _dashboard() {
    return RefreshIndicator(
      onRefresh: saveAndTest,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ANALYSIS TIMEFRAME',
                  style: TextStyle(
                    color: Color(0xFFB2C0B8),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: intervals.map((interval) {
                      final selected = interval == selectedInterval;
                      return Padding(
                        padding: const EdgeInsets.only(right: 7),
                        child: ChoiceChip(
                          label: Text(interval.toUpperCase()),
                          selected: selected,
                          showCheckmark: false,
                          onSelected: (_) => setChartInterval(interval),
                          labelStyle: TextStyle(
                            color: selected
                                ? const Color(0xFF11170E)
                                : const Color(0xFFB2C0B8),
                            fontWeight: FontWeight.w700,
                          ),
                          selectedColor: const Color(0xFFC4E86B),
                          backgroundColor: const Color(0xFF1A241F),
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Closed candle  •  minimum setup ${SmcEngine.minimumSetupScore}/100',
                  style: const TextStyle(
                    color: Color(0xFF91A098),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 10),

                Row(
                  children: [
                    Expanded(
                      child: _metric(
                        'Equity',
                        '${equity.toStringAsFixed(2)} USDT',
                      ),
                    ),
                    Expanded(
                      child: _metric('Risk', '${settings.riskPercent}%'),
                    ),
                    Expanded(child: _metric('RR', '1:${settings.rr}')),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ----------------------------------------------------
          // MODE
          // ----------------------------------------------------
          _card(
            Column(
              children: [
                SwitchListTile(
                  title: const Text('TESTNET'),
                  subtitle: Text(testnet ? 'Gate testnet' : 'Gate LIVE'),
                  value: testnet,
                  onChanged: (value) {
                    setState(() {
                      testnet = value;
                    });
                  },
                ),

                SwitchListTile(
                  title: const Text('DRY-RUN'),
                  subtitle: Text(
                    dryRun ? 'Tidak mengirim order' : 'Order diizinkan',
                  ),
                  value: dryRun,
                  onChanged: (value) {
                    setState(() {
                      dryRun = value;
                    });
                  },
                ),

                const SizedBox(height: 8),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: toggleBot,
                    icon: Icon(running ? Icons.stop : Icons.play_arrow),
                    label: Text(running ? 'STOP BOT' : 'START BOT'),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ----------------------------------------------------
          // ENGINE
          // ----------------------------------------------------
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Engine',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),

                const SizedBox(height: 8),

                const Text('EMA200 • Liquidity sweep • BOS • FVG • ATR levels'),

                const SizedBox(height: 8),

                Text(
                  '${selectedInterval.toUpperCase()} closed candle  •  Setup minimum ${SmcEngine.minimumSetupScore}/100',
                  style: const TextStyle(
                    color: Color(0xFF91A098),
                    fontSize: 12,
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'Risk: ${settings.riskPercent}% '
                  'per position',
                ),

                const SizedBox(height: 4),

                Text(
                  'Leverage: ${settings.leverage}x isolated '
                  '• Max positions: ${settings.maxPositions}',
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          if (signals.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(left: 2, bottom: 8),
              child: Text(
                'LATEST SETUPS',
                style: TextStyle(
                  color: Color(0xFFB2C0B8),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
            ...signals
                .take(3)
                .map(
                  (signal) => _card(
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        signal.side == 'BUY'
                            ? Icons.north_east
                            : Icons.south_east,
                        color: signal.side == 'BUY'
                            ? const Color(0xFFC4E86B)
                            : const Color(0xFFFF8C7A),
                      ),
                      title: Text('${signal.contract}  •  ${signal.side}'),
                      subtitle: Text(
                        'Entry ${signal.entry}  /  SL ${signal.stop}  /  TP1 ${signal.tp1}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: _scoreBadge(signal.score),
                    ),
                  ),
                ),
            const SizedBox(height: 4),
          ],

          // ----------------------------------------------------
          // LOG
          // ----------------------------------------------------
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Log',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),

                const SizedBox(height: 8),

                if (logs.isEmpty)
                  const Text('Belum ada log.')
                else
                  ...logs.take(12).map((entry) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(entry, style: const TextStyle(fontSize: 11)),
                    );
                  }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // SIGNALS
  // ============================================================

  Widget _signals() {
    if (signals.isEmpty) {
      return const Center(child: Text('Belum ada signal.'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: signals.length,
      itemBuilder: (_, index) {
        final signal = signals[index];

        return Card(
          child: ListTile(
            title: Text('${signal.side} • ${signal.contract}'),
            subtitle: Text(
              'Entry ${signal.entry}\n'
              'SL ${signal.stop}  '
              'TP1 ${signal.tp1}  TP2 ${signal.tp2}  TP3 ${signal.tp3}\n'
              'Risk ${signal.riskAmount.toStringAsFixed(3)} USDT '
              '• Size ${signal.size}',
            ),
            trailing: _scoreBadge(signal.score),
          ),
        );
      },
    );
  }

  Widget _chart() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: markets.isEmpty ? refreshMarkets : _pickMarket,
                icon: const Icon(Icons.search),
                label: Text(
                  markets.isEmpty ? 'LOAD MARKETS' : selectedMarket,
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                  side: const BorderSide(color: Color(0xFF29362F)),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Refresh market and chart',
              onPressed: refreshMarkets,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: intervals
                .map(
                  (interval) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(interval.toUpperCase()),
                      selected: selectedInterval == interval,
                      showCheckmark: false,
                      onSelected: (_) => setChartInterval(interval),
                      labelStyle: TextStyle(
                        color: selectedInterval == interval
                            ? const Color(0xFF11170E)
                            : const Color(0xFFB2C0B8),
                        fontWeight: FontWeight.w700,
                      ),
                      selectedColor: const Color(0xFFC4E86B),
                      backgroundColor: const Color(0xFF1A241F),
                      side: BorderSide.none,
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                '$selectedMarket  •  ${selectedInterval.toUpperCase()}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (chartCandles.isNotEmpty)
              Text(
                chartCandles.last.close.toString(),
                style: const TextStyle(
                  color: Color(0xFFC4E86B),
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          chartFeedStatus,
          style: TextStyle(
            color: chartRealtimeConnected
                ? const Color(0xFFC4E86B)
                : const Color(0xFFE7B96E),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (chartLoading) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 2),
        ],
        const SizedBox(height: 8),
        if (chartError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              chartError!,
              style: const TextStyle(color: Color(0xFFFF8C7A), fontSize: 12),
            ),
          ),
        SizedBox(
          height: 360,
          child: chartCandles.isEmpty
              ? Center(
                  child: chartLoading
                      ? const CircularProgressIndicator()
                      : const Text('Select a market to load its chart.'),
                )
              : SmcCandlestickChart(candles: chartCandles, signal: chartSignal),
        ),
        const SizedBox(height: 12),
        if (chartSignal case final signal?)
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${signal.side} SETUP',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    _scoreBadge(signal.score),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Entry ${signal.entry}  •  SL ${signal.stop}\n'
                  'TP1 ${signal.tp1}  •  TP2 ${signal.tp2}  •  TP3 ${signal.tp3}',
                ),
                const SizedBox(height: 6),
                Text(
                  signal.reasons.join('  •  '),
                  style: const TextStyle(
                    color: Color(0xFF91A098),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          )
        else if (chartCandles.isNotEmpty)
          const Text(
            'Chart uses closed candles. No eligible setup is available for this market yet.',
            style: TextStyle(color: Color(0xFF91A098), fontSize: 12),
          ),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            _chartLegend('Entry', const Color(0xFF4FC3F7)),
            _chartLegend('Stop loss', const Color(0xFFFF6B6B)),
            _chartLegend('Take profit', const Color(0xFF69DB7C)),
            _chartLegend('EMA 200', const Color(0xFFFFD166)),
          ],
        ),
      ],
    );
  }

  Widget _chartLegend(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 9, height: 9, color: color),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  // ============================================================
  // POSITIONS
  // ============================================================

  Widget _positions() {
    if (positions.isEmpty) {
      return const Center(child: Text('Tidak ada posisi aktif.'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: positions.length,
      itemBuilder: (_, index) {
        final position = positions[index];

        return Card(
          child: ListTile(
            title: Text(position.contract),
            subtitle: Text(
              'Size ${position.size} • '
              'Entry ${position.entryPrice}\n'
              'Mark ${position.markPrice} • '
              '${position.marginMode}',
            ),
            trailing: Text(
              position.unrealisedPnl.toStringAsFixed(4),
              style: TextStyle(
                color: position.unrealisedPnl >= 0
                    ? Colors.greenAccent
                    : Colors.redAccent,
              ),
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // SETTINGS
  // ============================================================

  Widget _settings() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Notifikasi signal'),
          subtitle: Text(
            !notificationsEnabled
                ? 'Nonaktif'
                : notificationPermissionGranted
                ? 'Peringatan SMC aktif'
                : 'Izin notifikasi belum diberikan',
          ),
          value: notificationsEnabled,
          onChanged: (value) async {
            if (value) {
              final granted = await notificationService.requestPermission();
              if (!mounted) return;
              if (!granted) {
                setState(() => notificationPermissionGranted = false);
                log('Izin notifikasi belum diberikan');
                return;
              }
              notificationPermissionGranted = true;
            }
            await storage.write(key: 'notifications_enabled', value: '$value');
            if (!mounted) return;
            setState(() => notificationsEnabled = value);
          },
        ),

        _field('Gate API Key', apiKey, obscure: true),

        _field('Gate API Secret', apiSecret, obscure: true),

        _field('Risk per position (%)', risk, keyboard: TextInputType.number),

        _field('Risk/Reward', rr, keyboard: TextInputType.number),

        _field('Max positions', maxPos, keyboard: TextInputType.number),

        _field('Scan seconds', scan, keyboard: TextInputType.number),

        DropdownButtonFormField<String>(
          initialValue: selectedInterval,
          decoration: const InputDecoration(labelText: 'Analysis timeframe'),
          items: intervals
              .map(
                (interval) => DropdownMenuItem(
                  value: interval,
                  child: Text(interval.toUpperCase()),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) unawaited(setChartInterval(value));
          },
        ),

        const SizedBox(height: 12),

        // ------------------------------------------------------
        // LEVERAGE
        // ------------------------------------------------------
        DropdownButtonFormField<int>(
          initialValue: leverage,
          decoration: const InputDecoration(labelText: 'Isolated leverage'),
          items: const [5, 10, 15, 20, 25]
              .map(
                (value) =>
                    DropdownMenuItem(value: value, child: Text('${value}x')),
              )
              .toList(),
          onChanged: (value) {
            setState(() {
              leverage = value ?? 15;
            });
          },
        ),

        const SizedBox(height: 12),

        // ------------------------------------------------------
        // ENVIRONMENT
        // ------------------------------------------------------
        DropdownButtonFormField<bool>(
          initialValue: testnet,
          decoration: const InputDecoration(labelText: 'Environment'),
          items: const [
            DropdownMenuItem(value: true, child: Text('TESTNET')),
            DropdownMenuItem(value: false, child: Text('LIVE')),
          ],
          onChanged: (value) {
            setState(() {
              testnet = value ?? true;
            });
          },
        ),

        const SizedBox(height: 12),

        // ------------------------------------------------------
        // EXECUTION
        // ------------------------------------------------------
        DropdownButtonFormField<bool>(
          initialValue: dryRun,
          decoration: const InputDecoration(labelText: 'Execution'),
          items: const [
            DropdownMenuItem(value: true, child: Text('DRY-RUN')),
            DropdownMenuItem(value: false, child: Text('SEND ORDERS')),
          ],
          onChanged: (value) {
            setState(() {
              dryRun = value ?? true;
            });
          },
        ),

        const SizedBox(height: 18),

        // ------------------------------------------------------
        // SAVE
        // ------------------------------------------------------
        FilledButton.icon(
          onPressed: saveAndTest,
          icon: const Icon(Icons.save),
          label: const Text('SAVE & TEST CONNECTION'),
        ),

        const SizedBox(height: 8),

        // ------------------------------------------------------
        // RISK WARNING
        // ------------------------------------------------------
        OutlinedButton(
          onPressed: () {
            showDialog(
              context: context,
              builder: (dialogContext) {
                return AlertDialog(
                  title: const Text('Risk warning'),
                  content: const Text(
                    'Risk 2% dihitung dari equity '
                    'yang terbaca saat scan. '
                    'Leverage 15x tidak berarti '
                    'risiko 30%; leverage mengubah '
                    'margin/notional. '
                    'Slippage, fee, funding, '
                    'liquidation, API outage, dan gap '
                    'dapat membuat kerugian aktual '
                    'berbeda dari estimasi. '
                    'Uji TESTNET dan DRY-RUN '
                    'sebelum LIVE.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(dialogContext);
                      },
                      child: const Text('OK'),
                    ),
                  ],
                );
              },
            );
          },
          child: const Text('Lihat aturan risiko'),
        ),
      ],
    );
  }

  // ============================================================
  // TEXT FIELD
  // ============================================================

  Widget _field(
    String label,
    TextEditingController controller, {
    bool obscure = false,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  // ============================================================
  // METRIC
  // ============================================================

  Widget _metric(String title, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 10,
            color: Color(0xFF91A098),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _scoreBadge(int score) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFC4E86B).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$score/100',
        style: const TextStyle(
          color: Color(0xFFC4E86B),
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  // ============================================================
  // CARD
  // ============================================================

  Widget _card(Widget child) {
    return Card(
      color: const Color(0xFF111916),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF25332B)),
      ),
      elevation: 0,
      child: Padding(padding: const EdgeInsets.all(14), child: child),
    );
  }
}
