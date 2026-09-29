import 'package:flutter_test/flutter_test.dart';
import 'package:gateio_smc_pro/main.dart';

void main() {
  testWidgets('SMC Futures AI Trader app loads', (tester) async {
    await tester.pumpWidget(const GateSmcApp());

    expect(find.byType(GateSmcApp), findsOneWidget);
    expect(find.text('SMC FUTURES AI TRADER'), findsOneWidget);
  });
}
