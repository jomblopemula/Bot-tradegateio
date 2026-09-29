import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gateio_smc_pro/gate_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Gate API error diagnostic extracts label and message', () {
    final error = GateApiException(
      400,
      jsonEncode({'label': 'SIZE_TOO_SMALL', 'message': 'Size is below min'}),
    );

    expect(error.toString(), 'Gate API 400: SIZE_TOO_SMALL: Size is below min');
  });

  test('order status is queried by exchange order id and contract', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v4/futures/usdt/orders/12345');
      expect(request.url.queryParameters['contract'], 'BTC_USDT');
      return http.Response(
        jsonEncode({
          'id': '12345',
          'status': 'finished',
          'size': '2',
          'left': '0',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = GateApi(
      apiKey: 'test-key',
      apiSecret: 'test-secret',
      testnet: true,
      client: client,
    );

    final result = await api.orderStatus(
      contract: 'BTC_USDT',
      orderId: '12345',
    );

    expect(result['id'], '12345');
    expect(result['left'], '0');
    api.dispose();
  });
}
