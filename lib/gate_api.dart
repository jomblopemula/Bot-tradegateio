import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'models.dart';

class GateApiException implements Exception {
  final int status;
  final String message;
  GateApiException(this.status, this.message);
  @override
  String toString() => 'Gate API $status: $message';
}

class GateApi {
  final String apiKey;
  final String apiSecret;
  final bool testnet;
  final http.Client _client;

  GateApi({
    required this.apiKey,
    required this.apiSecret,
    required this.testnet,
    http.Client? client,
  }) : _client = client ?? http.Client();

  String get base =>
      testnet ? 'https://api-testnet.gateapi.io/api/v4'
              : 'https://api.gateio.ws/api/v4';

  String _sha512(String s) => sha512.convert(utf8.encode(s)).toString();

  Map<String, String> _headers(
      String method, String path, String query, String body) {
    final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final payloadHash = _sha512(body);
    final signString =
        '$method\n/api/v4$path\n$query\n$payloadHash\n$ts';
    final sign = Hmac(sha512, utf8.encode(apiSecret))
        .convert(utf8.encode(signString))
        .toString();

    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'KEY': apiKey,
      'Timestamp': ts,
      'SIGN': sign,
      'X-Gate-Size-Decimal': '1',
    };
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, String> query = const {},
    Object? body,
    bool auth = false,
  }) async {
    final queryString = query.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final bodyText = body == null ? '' : jsonEncode(body);
    final uri = Uri.parse('$base$path${queryString.isEmpty ? '' : '?$queryString'}');
    final headers = auth
        ? _headers(method, path, queryString, bodyText)
        : {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'X-Gate-Size-Decimal': '1',
          };

    http.Response r;
    switch (method) {
      case 'GET':
        r = await _client.get(uri, headers: headers);
        break;
      case 'POST':
        r = await _client.post(uri, headers: headers, body: bodyText);
        break;
      case 'DELETE':
        r = await _client.delete(uri, headers: headers);
        break;
      default:
        throw ArgumentError('Unsupported method $method');
    }

    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw GateApiException(r.statusCode, r.body);
    }
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  Future<List<ContractInfo>> contracts() async {
    final data = await _request('GET', '/futures/usdt/contracts');
    return (data as List)
        .map((e) => ContractInfo.fromJson(e as Map<String, dynamic>))
        .where((c) => c.state == 'normal' || c.state == 'true')
        .toList();
  }

  Future<List<Candle>> candles(String contract, String interval,
      {int limit = 220}) async {
    final data = await _request(
      'GET',
      '/futures/usdt/candlesticks',
      query: {'contract': contract, 'interval': interval, 'limit': '$limit'},
    );
    final list = (data as List)
        .map((e) => Candle.fromGate(Map<String, dynamic>.from(e)))
        .toList();
    list.sort((a, b) => a.time.compareTo(b.time));
    return list;
  }

  Future<Map<String, dynamic>> futuresAccount() async =>
      Map<String, dynamic>.from(
          await _request('GET', '/futures/usdt/accounts', auth: true));

  Future<List<PositionInfo>> positions() async {
    final data = await _request('GET', '/futures/usdt/positions', auth: true);
    return (data as List)
        .map((e) => PositionInfo.fromJson(Map<String, dynamic>.from(e)))
        .where((p) => p.size != 0)
        .toList();
  }

  Future<void> setIsolatedLeverage(String contract, int leverage) async {
    await _request(
      'POST',
      '/futures/usdt/positions/$contract/leverage',
      query: {'leverage': '$leverage'},
      auth: true,
    );
  }

  Future<Map<String, dynamic>> placeMarketOrder({
    required String contract,
    required double size,
    required double tp,
    required double sl,
    required String clientId,
  }) async {
    final body = {
      'contract': contract,
      'size': size.toString(),
      'price': '0',
      'tif': 'ioc',
      'text': clientId,
      'pos_margin_mode': 'isolated',
      'tpsl_tp_trigger_price': tp.toString(),
      'tpsl_sl_trigger_price': sl.toString(),
      'market_order_slip_ratio': '0.03',
    };
    return Map<String, dynamic>.from(await _request(
      'POST',
      '/futures/usdt/orders',
      body: body,
      auth: true,
    ));
  }

  Future<Map<String, dynamic>> closePosition(String contract) async {
    final body = {
      'contract': contract,
      'size': '0',
      'price': '0',
      'tif': 'ioc',
      'reduce_only': true,
      'close': true,
    };
    return Map<String, dynamic>.from(await _request(
      'POST',
      '/futures/usdt/orders',
      body: body,
      auth: true,
    ));
  }

  Future<bool> testConnection() async {
    await _request('GET', '/futures/usdt/contracts');
    if (apiKey.isEmpty || apiSecret.isEmpty) return true;
    await futuresAccount();
    return true;
  }

  void dispose() => _client.close();
}
