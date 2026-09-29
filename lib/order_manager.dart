import 'dart:math' as math;

import 'models.dart';

enum OrderFillState { filled, partiallyFilled, noFill, pending, inconclusive }

class OrderFillVerification {
  final OrderFillState state;
  final String orderStatus;
  final String finishAs;
  final double? orderSize;
  final double? leftSize;
  final double filledSize;
  final bool matchingPositionFound;

  const OrderFillVerification({
    required this.state,
    required this.orderStatus,
    required this.finishAs,
    required this.orderSize,
    required this.leftSize,
    required this.filledSize,
    required this.matchingPositionFound,
  });

  bool get isVerifiedFill =>
      state == OrderFillState.filled || state == OrderFillState.partiallyFilled;

  bool get shouldRetry =>
      state == OrderFillState.pending || state == OrderFillState.inconclusive;
}

OrderFillVerification verifyFuturesOrder({
  required Map<String, dynamic> order,
  required List<PositionInfo> positions,
  required String contract,
  required String side,
}) {
  final orderStatus = '${order['status'] ?? 'unknown'}'.toLowerCase();
  final finishAs = '${order['finish_as'] ?? 'unknown'}'.toLowerCase();
  final orderSize = _parseNumber(order['size'])?.abs();
  final leftSize = _parseNumber(order['left'])?.abs();

  if (orderSize == null || leftSize == null || orderSize <= 0) {
    return OrderFillVerification(
      state: OrderFillState.inconclusive,
      orderStatus: orderStatus,
      finishAs: finishAs,
      orderSize: orderSize,
      leftSize: leftSize,
      filledSize: 0,
      matchingPositionFound: false,
    );
  }

  const sizeEpsilon = 1e-9;
  final filledSize = math
      .max(0, math.min(orderSize, orderSize - leftSize))
      .toDouble();
  if (filledSize <= sizeEpsilon) {
    final isTerminal = orderStatus == 'finished' || orderStatus == 'closed';
    return OrderFillVerification(
      state: isTerminal ? OrderFillState.noFill : OrderFillState.pending,
      orderStatus: orderStatus,
      finishAs: finishAs,
      orderSize: orderSize,
      leftSize: leftSize,
      filledSize: 0,
      matchingPositionFound: false,
    );
  }

  final isBuy = side.toUpperCase() == 'BUY';
  final matchingPositionFound = positions.any((position) {
    if (position.contract != contract) return false;
    final correctDirection = isBuy ? position.size > 0 : position.size < 0;
    return correctDirection && position.size.abs() + sizeEpsilon >= filledSize;
  });

  final state = !matchingPositionFound
      ? OrderFillState.inconclusive
      : leftSize > sizeEpsilon
      ? OrderFillState.partiallyFilled
      : OrderFillState.filled;

  return OrderFillVerification(
    state: state,
    orderStatus: orderStatus,
    finishAs: finishAs,
    orderSize: orderSize,
    leftSize: leftSize,
    filledSize: filledSize,
    matchingPositionFound: matchingPositionFound,
  );
}

double? _parseNumber(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
