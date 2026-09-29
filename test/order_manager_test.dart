import 'package:flutter_test/flutter_test.dart';
import 'package:gateio_smc_pro/models.dart';
import 'package:gateio_smc_pro/order_manager.dart';

void main() {
  test('missing left field is inconclusive, not a zero-fill rejection', () {
    final result = verifyFuturesOrder(
      order: const {'status': 'finished', 'size': '10'},
      positions: [_position(10)],
      contract: 'BTC_USDT',
      side: 'BUY',
    );

    expect(result.state, OrderFillState.inconclusive);
    expect(result.shouldRetry, isTrue);
  });

  test('fully filled order requires a matching Gate position', () {
    final verified = verifyFuturesOrder(
      order: const {'status': 'finished', 'size': '10', 'left': '0'},
      positions: [_position(10)],
      contract: 'BTC_USDT',
      side: 'BUY',
    );
    final missingPosition = verifyFuturesOrder(
      order: const {'status': 'finished', 'size': '10', 'left': '0'},
      positions: const [],
      contract: 'BTC_USDT',
      side: 'BUY',
    );

    expect(verified.state, OrderFillState.filled);
    expect(missingPosition.state, OrderFillState.inconclusive);
  });

  test('partial fill verifies when matching position covers filled size', () {
    final result = verifyFuturesOrder(
      order: const {'status': 'finished', 'size': '-10', 'left': '-4'},
      positions: [_position(-6)],
      contract: 'BTC_USDT',
      side: 'SELL',
    );

    expect(result.state, OrderFillState.partiallyFilled);
    expect(result.filledSize, 6);
  });

  test('terminal order with no fill is reported as no-fill', () {
    final result = verifyFuturesOrder(
      order: const {
        'status': 'finished',
        'finish_as': 'ioc',
        'size': '10',
        'left': '10',
      },
      positions: const [],
      contract: 'BTC_USDT',
      side: 'BUY',
    );

    expect(result.state, OrderFillState.noFill);
  });

  test('wrong direction or undersized position is not verified', () {
    final result = verifyFuturesOrder(
      order: const {'status': 'finished', 'size': '10', 'left': '0'},
      positions: [_position(-10)],
      contract: 'BTC_USDT',
      side: 'BUY',
    );

    expect(result.state, OrderFillState.inconclusive);
  });
}

PositionInfo _position(double size) => PositionInfo(
  contract: 'BTC_USDT',
  size: size,
  entryPrice: 100,
  markPrice: 100,
  unrealisedPnl: 0,
  leverage: '15',
  marginMode: 'isolated',
);
