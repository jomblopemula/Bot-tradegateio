import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'gate_api.dart';
import 'models.dart';
import 'smc_engine.dart';

void main() {
  runApp(const GateSmcApp());
}

class GateSmcApp extends StatelessWidget {
  const GateSmcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Gate SMC Pro',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF081014),
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

  final apiKey = TextEditingController();
  final apiSecret = TextEditingController();

  // Default sesuai kebutuhan:
  // 2% modal/equity per posisi
  final risk = TextEditingController(text: '2');

  // Risk reward 1:3
  final rr = TextEditingController(text: '3');

  final maxPos = TextEditingController(text: '3');

  // Scan setiap 60 detik
  final scan = TextEditingController(text: '60');

  bool testnet = true;
  bool dryRun = true;
  bool running = false;

  int leverage = 15;

  double equity = 0;

  String status = 'Belum terhubung';

  Timer? timer;

  GateApi? api;

  final engine = const SmcEngine();

  final logs = <String>[];
  final signals = <Signal>[];

  List<PositionInfo> positions = [];

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

  // ============================================================
  // LOAD SETTINGS
  // ============================================================

  Future<void> loadSaved() async {
    apiKey.text = await storage.read(key: 'api_key') ?? '';
    apiSecret.text = await storage.read(key: 'api_secret') ?? '';

    testnet = (await storage.read(key: 'testnet')) != 'false';
    dryRun = (await storage.read(key: 'dry_run')) != 'false';

    if (!mounted) return;

    setState(() {});
  }

  @override
  void initState() {
    super.initState();

    loadSaved();
  }

  // ============================================================
  // SAVE + TEST CONNECTION
  // ============================================================

  Future<void> saveAndTest() async {
    try {
      await storage.write(
        key: 'api_key',
        value: apiKey.text.trim(),
      );

      await storage.write(
        key: 'api_secret',
        value: apiSecret.text.trim(),
      );

      await storage.write(
        key: 'testnet',
        value: '$testnet',
      );

      await storage.write(
        key: 'dry_run',
        value: '$dryRun',
      );

      api?.dispose();

      api = GateApi(
        apiKey: apiKey.text.trim(),
        apiSecret: apiSecret.text.trim(),
        testnet: testnet,
      );

      await api!.testConnection();

      final acc = await api!.futuresAccount();

      equity = double.tryParse(
            '${acc['total'] ?? acc['available'] ?? 0}',
          ) ??
          0;

      positions = await api!.positions();

      if (!mounted) return;

      setState(() {
        status =
            'Terhubung • Equity ${equity.toStringAsFixed(2)} USDT';
      });

      log(
        'Connection OK • ${testnet ? 'TESTNET' : 'LIVE'}',
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        status = 'Gagal: $e';
      });

      log('ERROR: $e');
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
      maxPositions: int.tryParse(maxPos.text) ?? 3,
      scanSeconds: int.tryParse(scan.text) ?? 60,
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
      final ok = await showDialog<bool>(
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
      Duration(
        seconds: settings.scanSeconds.clamp(15, 3600),
      ),
      (_) {
        scanOnce();
      },
    );
  }

  // ============================================================
  // SCAN MARKET
  // ============================================================

  Future<void> scanOnce() async {
    if (api == null) {
      return;
    }

    try {
      // --------------------------------------------------------
      // GET CONTRACTS
      // --------------------------------------------------------

      final list = await api!.contracts();
      log('Market scan: ${list.length} active contracts');

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
        log(
          'Max positions reached: $active/$limit',
        );

        return;
      }

      // --------------------------------------------------------
      // BATCH SCAN
      // --------------------------------------------------------

      final batch = list.take(30).toList();

      for (final c in batch) {
        if (!running) {
          break;
        }

        // Jangan entry contract yang sudah punya posisi
        if (positions.any(
          (p) => p.contract == c.name,
        )) {
          continue;
        }

        try {
          // ----------------------------------------------------
          // GET CANDLES
          // ----------------------------------------------------

          final candles = await api!.candles(
            c.name,
            settings.interval,
          );

          // ----------------------------------------------------
          // SMC ENGINE
          // ----------------------------------------------------

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
            'TP ${signal.tp} '
            'score ${signal.score}%',
          );

          // ----------------------------------------------------
          // DRY RUN
          // ----------------------------------------------------

          if (settings.dryRun) {
            continue;
          }

          // ----------------------------------------------------
          // MAX POSITION CHECK
          // ----------------------------------------------------

          if (positions.length >= settings.maxPositions) {
            break;
          }

          // ----------------------------------------------------
          // SET ISOLATED LEVERAGE
          // ----------------------------------------------------

          await api!.setIsolatedLeverage(
            signal.contract,
            settings.leverage,
          );

          // ----------------------------------------------------
          // ORDER SIZE
          // ----------------------------------------------------

          final signedSize =
              signal.side == 'BUY' ? signal.size : -signal.size;

          final id =
              't-smc-${DateTime.now().millisecondsSinceEpoch % 100000000}';

          // ----------------------------------------------------
          // PLACE MARKET ORDER
          // ----------------------------------------------------

          final result = await api!.placeMarketOrder(
            contract: signal.contract,
            size: signedSize,
            tp: signal.tp,
            sl: signal.stop,
            clientId: id,
          );

          log(
            'ORDER SENT ${signal.contract}: '
            '${result['id'] ?? result}',
          );

          // ----------------------------------------------------
          // REFRESH POSITIONS
          // ----------------------------------------------------

          positions = await api!.positions();
        } catch (e) {
          log(
            'SCAN ${c.name}: $e',
          );
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
      log(
        'BOT ERROR: $e',
      );
    }
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    timer?.cancel();

    api?.dispose();

    apiKey.dispose();
    apiSecret.dispose();
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
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Gate.io SMC PRO',
          ),
          actions: [
            Icon(
              running
                  ? Icons.play_circle
                  : Icons.stop_circle,
              color: running
                  ? Colors.greenAccent
                  : Colors.redAccent,
            ),
            const SizedBox(width: 12),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(
                icon: Icon(Icons.dashboard),
                text: 'Dashboard',
              ),
              Tab(
                icon: Icon(Icons.candlestick_chart),
                text: 'Signals',
              ),
              Tab(
                icon: Icon(Icons.account_balance_wallet),
                text: 'Positions',
              ),
              Tab(
                icon: Icon(Icons.settings),
                text: 'Settings',
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _dashboard(),
            _signals(),
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
              crossAxisAlignment:
                  CrossAxisAlignment.start,
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
                      child: _metric(
                        'Risk',
                        '${settings.riskPercent}%',
                      ),
                    ),
                    Expanded(
                      child: _metric(
                        'RR',
                        '1:${settings.rr}',
                      ),
                    ),
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
                  subtitle: Text(
                    testnet
                        ? 'Gate testnet'
                        : 'Gate LIVE',
                  ),
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
                    dryRun
                        ? 'Tidak mengirim order'
                        : 'Order diizinkan',
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
                    icon: Icon(
                      running
                          ? Icons.stop
                          : Icons.play_arrow,
                    ),
                    label: Text(
                      running
                          ? 'STOP BOT'
                          : 'START BOT',
                    ),
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
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                const Text(
                  'Engine',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 8),

                const Text(
                  '15m closed candle • '
                  'EMA200 • '
                  'Liquidity Sweep • '
                  'BOS • '
                  'FVG proxy • '
                  'ATR SL • '
                  'RR 1:3',
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

          // ----------------------------------------------------
          // LOG
          // ----------------------------------------------------

          _card(
            Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                const Text(
                  'Log',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 8),

                if (logs.isEmpty)
                  const Text(
                    'Belum ada log.',
                  )
                else
                  ...logs.take(12).map(
                    (entry) {
                      return Padding(
                        padding:
                            const EdgeInsets.only(
                          bottom: 4,
                        ),
                        child: Text(
                          entry,
                          style:
                              const TextStyle(
                            fontSize: 11,
                          ),
                        ),
                      );
                    },
                  ),
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
      return const Center(
        child: Text(
          'Belum ada signal.',
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: signals.length,
      itemBuilder: (_, index) {
        final signal = signals[index];

        return Card(
          child: ListTile(
            title: Text(
              '${signal.side} • ${signal.contract}',
            ),
            subtitle: Text(
              'Entry ${signal.entry}\n'
              'SL ${signal.stop}  '
              'TP ${signal.tp}\n'
              'Risk ${signal.riskAmount.toStringAsFixed(3)} USDT '
              '• Size ${signal.size}',
            ),
            trailing: Text(
              '${signal.score}%',
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // POSITIONS
  // ============================================================

  Widget _positions() {
    if (positions.isEmpty) {
      return const Center(
        child: Text(
          'Tidak ada posisi aktif.',
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: positions.length,
      itemBuilder: (_, index) {
        final position = positions[index];

        return Card(
          child: ListTile(
            title: Text(
              position.contract,
            ),
            subtitle: Text(
              'Size ${position.size} • '
              'Entry ${position.entryPrice}\n'
              'Mark ${position.markPrice} • '
              '${position.marginMode}',
            ),
            trailing: Text(
              position.unrealisedPnl
                  .toStringAsFixed(4),
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
        _field(
          'Gate API Key',
          apiKey,
          obscure: true,
        ),

        _field(
          'Gate API Secret',
          apiSecret,
          obscure: true,
        ),

        _field(
          'Risk per position (%)',
          risk,
          keyboard: TextInputType.number,
        ),

        _field(
          'Risk/Reward',
          rr,
          keyboard: TextInputType.number,
        ),

        _field(
          'Max positions',
          maxPos,
          keyboard: TextInputType.number,
        ),

        _field(
          'Scan seconds',
          scan,
          keyboard: TextInputType.number,
        ),

        // ------------------------------------------------------
        // LEVERAGE
        // ------------------------------------------------------

        DropdownButtonFormField<int>(
          initialValue: leverage,
          decoration: const InputDecoration(
            labelText: 'Isolated leverage',
          ),
          items: const [
            5,
            10,
            15,
            20,
            25,
          ]
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text('${value}x'),
                ),
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
          decoration: const InputDecoration(
            labelText: 'Environment',
          ),
          items: const [
            DropdownMenuItem(
              value: true,
              child: Text('TESTNET'),
            ),
            DropdownMenuItem(
              value: false,
              child: Text('LIVE'),
            ),
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
          decoration: const InputDecoration(
            labelText: 'Execution',
          ),
          items: const [
            DropdownMenuItem(
              value: true,
              child: Text('DRY-RUN'),
            ),
            DropdownMenuItem(
              value: false,
              child: Text('SEND ORDERS'),
            ),
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
          icon: const Icon(
            Icons.save,
          ),
          label: const Text(
            'SAVE & TEST CONNECTION',
          ),
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
                  title: const Text(
                    'Risk warning',
                  ),
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
                        Navigator.pop(
                          dialogContext,
                        );
                      },
                      child: const Text(
                        'OK',
                      ),
                    ),
                  ],
                );
              },
            );
          },
          child: const Text(
            'Lihat aturan risiko',
          ),
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
      padding: const EdgeInsets.only(
        bottom: 12,
      ),
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

  Widget _metric(
    String title,
    String value,
  ) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // CARD
  // ============================================================

  Widget _card(Widget child) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: child,
      ),
    );
  }
}
