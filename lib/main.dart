import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'gate_api.dart';
import 'models.dart';
import 'smc_engine.dart';

void main() => runApp(const GateSmcApp());

class GateSmcApp extends StatelessWidget {
  const GateSmcApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const storage = FlutterSecureStorage();
  final apiKey = TextEditingController();
  final apiSecret = TextEditingController();
  final risk = TextEditingController(text: '2');
  final rr = TextEditingController(text: '3');
  final maxPos = TextEditingController(text: '3');
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

  void log(String s) {
    if (!mounted) return;
    setState(() {
      logs.insert(0, '${DateTime.now().toLocal().toString().substring(0, 19)}  $s');
      if (logs.length > 120) logs.removeLast();
    });
  }

  Future<void> loadSaved() async {
    apiKey.text = await storage.read(key: 'api_key') ?? '';
    apiSecret.text = await storage.read(key: 'api_secret') ?? '';
    testnet = (await storage.read(key: 'testnet')) != 'false';
    dryRun = (await storage.read(key: 'dry_run')) != 'false';
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    loadSaved();
  }

  Future<void> saveAndTest() async {
    try {
      await storage.write(key: 'api_key', value: apiKey.text.trim());
      await storage.write(key: 'api_secret', value: apiSecret.text.trim());
      await storage.write(key: 'testnet', value: '$testnet');
      await storage.write(key: 'dry_run', value: '$dryRun');
      api?.dispose();
      api = GateApi(
        apiKey: apiKey.text.trim(),
        apiSecret: apiSecret.text.trim(),
        testnet: testnet,
      );
      await api!.testConnection();
      final acc = await api!.futuresAccount();
      equity = double.tryParse('${acc['total'] ?? acc['available'] ?? 0}') ?? 0;
      positions = await api!.positions();
      setState(() => status = 'Terhubung • Equity ${equity.toStringAsFixed(2)} USDT');
      log('Connection OK • ${testnet ? 'TESTNET' : 'LIVE'}');
    } catch (e) {
      setState(() => status = 'Gagal: $e');
      log('ERROR: $e');
    }
  }

  BotSettings get settings => BotSettings(
        testnet: testnet,
        dryRun: dryRun,
        riskPercent: double.tryParse(risk.text) ?? 2,
        rr: double.tryParse(rr.text) ?? 3,
        leverage: leverage,
        maxPositions: int.tryParse(maxPos.text) ?? 3,
        scanSeconds: int.tryParse(scan.text) ?? 60,
      );

  Future<void> toggleBot() async {
    if (running) {
      timer?.cancel();
      setState(() => running = false);
      log('BOT STOPPED');
      return;
    }
    if (api == null) {
      await saveAndTest();
      if (api == null) return;
    }
    if (!settings.dryRun && settings.testnet == false) {
      final ok = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Konfirmasi LIVE'),
              content: const Text(
                'Mode LIVE akan mengirim order ke Gate.io. '
                'Pastikan API key hanya memiliki izin yang diperlukan, '
                'dan uji TESTNET/DRY-RUN terlebih dahulu.',
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('BATAL')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('LANJUT')),
              ],
            ),
          ) ??
          false;
      if (!ok) return;
    }
    setState(() => running = true);
    log('BOT STARTED • ${settings.dryRun ? 'DRY-RUN' : 'ORDER ENABLED'}');
    await scanOnce();
    timer = Timer.periodic(Duration(seconds: settings.scanSeconds.clamp(15, 3600)),
        (_) => scanOnce());
  }

  Future<void> scanOnce() async {
    if (api == null) return;
    try {
      final list = await api!.contracts();
      positions = await api!.positions();
      final active = positions.length;
      if (mounted) setState(() {});

      final limit = settings.maxPositions;
      if (active >= limit) {
        log('Max positions reached: $active/$limit');
        return;
      }

      // Scan a bounded batch to reduce API load. The full list remains visible
      // through the contracts endpoint; scanning all symbols every minute can
      // hit rate limits on a mobile connection.
      final batch = list.take(30).toList();
      for (final c in batch) {
        if (!running) break;
        if (positions.any((p) => p.contract == c.name)) continue;
        try {
          final candles = await api!.candles(c.name, settings.interval);
          final s = engine.analyze(
            contract: c.name,
            candles: candles,
            equity: equity,
            info: c,
            riskPercent: settings.riskPercent,
            rr: settings.rr,
          );
          if (s == null) continue;

          signals.insert(0, s);
          if (signals.length > 30) signals.removeLast();
          log('${s.side} ${s.contract} Entry ${s.entry} SL ${s.stop} TP ${s.tp} score ${s.score}%');

          if (settings.dryRun) continue;
          if (positions.length >= settings.maxPositions) break;

          await api!.setIsolatedLeverage(s.contract, settings.leverage);
          final signedSize = s.side == 'BUY' ? s.size : -s.size;
          final id = 't-smc-${DateTime.now().millisecondsSinceEpoch % 100000000}';
          final result = await api!.placeMarketOrder(
            contract: s.contract,
            size: signedSize,
            tp: s.tp,
            sl: s.stop,
            clientId: id,
          );
          log('ORDER SENT ${s.contract}: ${result['id'] ?? result}');
          positions = await api!.positions();
        } catch (e) {
          log('SCAN ${c.name}: $e');
        }
        if (positions.length >= settings.maxPositions) break;
      }
      setState(() {});
    } catch (e) {
      log('BOT ERROR: $e');
    }
  }

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

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Gate.io SMC PRO'),
            actions: [
              Icon(running ? Icons.play_circle : Icons.stop_circle,
                  color: running ? Colors.greenAccent : Colors.redAccent),
              const SizedBox(width: 12),
            ],
            bottom: const TabBar(
              tabs: [
                Tab(icon: Icon(Icons.dashboard), text: 'Dashboard'),
                Tab(icon: Icon(Icons.candlestick_chart), text: 'Signals'),
                Tab(icon: Icon(Icons.account_balance_wallet), text: 'Positions'),
                Tab(icon: Icon(Icons.settings), text: 'Settings'),
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

  Widget _dashboard() => RefreshIndicator(
        onRefresh: saveAndTest,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(status,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: _metric('Equity', '${equity.toStringAsFixed(2)} USDT')),
                      Expanded(child: _metric('Risk', '${settings.riskPercent}%')),
                      Expanded(child: _metric('RR', '1:${settings.rr}')),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _card(Column(
              children: [
                SwitchListTile(
                  title: const Text('TESTNET'),
                  subtitle: Text(testnet ? 'Gate testnet' : 'Gate LIVE'),
                  value: testnet,
                  onChanged: (v) => setState(() => testnet = v),
                ),
                SwitchListTile(
                  title: const Text('DRY-RUN'),
                  subtitle: Text(dryRun ? 'Tidak mengirim order' : 'Order diizinkan'),
                  value: dryRun,
                  onChanged: (v) => setState(() => dryRun = v),
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
            )),
            const SizedBox(height: 12),
            _card(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Engine',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('15m closed candle • EMA200 • Liquidity Sweep • BOS • FVG proxy • ATR SL • RR 1:3'),
                const SizedBox(height: 8),
                Text('Leverage: ${settings.leverage}x isolated • Max positions: ${settings.maxPositions}'),
              ],
            )),
            const SizedBox(height: 12),
            _card(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (logs.isEmpty) const Text('Belum ada log.')
                else ...logs.take(12).map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(e, style: const TextStyle(fontSize: 11)),
                    )),
              ],
            )),
          ],
        ),
      );

  Widget _signals() => ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: signals.length,
        itemBuilder: (_, i) {
          final s = signals[i];
          return Card(
            child: ListTile(
              title: Text('${s.side} • ${s.contract}'),
              subtitle: Text(
                  'Entry ${s.entry}\nSL ${s.stop}  TP ${s.tp}\nRisk ${s.riskAmount.toStringAsFixed(3)} USDT • Size ${s.size}'),
              trailing: Text('${s.score}%'),
            ),
          );
        },
      );

  Widget _positions() => ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: positions.length,
        itemBuilder: (_, i) {
          final p = positions[i];
          return Card(
            child: ListTile(
              title: Text(p.contract),
              subtitle: Text(
                  'Size ${p.size} • Entry ${p.entryPrice}\nMark ${p.markPrice} • ${p.marginMode}'),
              trailing: Text(
                p.unrealisedPnl.toStringAsFixed(4),
                style: TextStyle(
                  color: p.unrealisedPnl >= 0 ? Colors.greenAccent : Colors.redAccent,
                ),
              ),
            ),
          );
        },
      );

  Widget _settings() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field('Gate API Key', apiKey, obscure: true),
          _field('Gate API Secret', apiSecret, obscure: true),
          _field('Risk per position (%)', risk, keyboard: TextInputType.number),
          _field('Risk/Reward', rr, keyboard: TextInputType.number),
          _field('Max positions', maxPos, keyboard: TextInputType.number),
          _field('Scan seconds', scan, keyboard: TextInputType.number),
          DropdownButtonFormField<int>(
            initialValue: leverage,
            decoration: const InputDecoration(labelText: 'Isolated leverage'),
            items: const [5, 10, 15, 20, 25]
                .map((e) => DropdownMenuItem(value: e, child: Text('${e}x')))
                .toList(),
            onChanged: (v) => setState(() => leverage = v ?? 15),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<bool>(
            initialValue: testnet,
            decoration: const InputDecoration(labelText: 'Environment'),
            items: const [
              DropdownMenuItem(value: true, child: Text('TESTNET')),
              DropdownMenuItem(value: false, child: Text('LIVE')),
            ],
            onChanged: (v) => setState(() => testnet = v ?? true),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<bool>(
            initialValue: dryRun,
            decoration: const InputDecoration(labelText: 'Execution'),
            items: const [
              DropdownMenuItem(value: true, child: Text('DRY-RUN')),
              DropdownMenuItem(value: false, child: Text('SEND ORDERS')),
            ],
            onChanged: (v) => setState(() => dryRun = v ?? true),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: saveAndTest,
            icon: const Icon(Icons.save),
            label: const Text('SAVE & TEST CONNECTION'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Risk warning'),
                content: const Text(
                  'Risk 2% dihitung dari equity yang terbaca saat scan. '
                  'Leverage 15x tidak berarti risiko 30%; leverage mengubah margin/notional. '
                  'Slippage, fee, funding, liquidation, API outage, dan gap dapat membuat '
                  'kerugian aktual berbeda dari estimasi. Uji TESTNET dan DRY-RUN sebelum LIVE.',
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('OK')),
                ],
              ),
            ),
            child: const Text('Lihat aturan risiko'),
          ),
        ],
      );

  Widget _field(String label, TextEditingController c,
      {bool obscure = false, TextInputType? keyboard}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          obscureText: obscure,
          keyboardType: keyboard,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  Widget _metric(String a, String b) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(a, style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 3),
          Text(b, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      );

  Widget _card(Widget child) => Card(
        elevation: 0,
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      );
}
