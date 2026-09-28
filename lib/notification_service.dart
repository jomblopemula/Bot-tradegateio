import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'models.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings: settings);
  }

  Future<bool> requestPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.requestNotificationsPermission() ?? false;
  }

  Future<void> showSignal(Signal signal) async {
    final notificationId = DateTime.now().microsecondsSinceEpoch.remainder(
      2147483647,
    );
    await _plugin.show(
      id: notificationId,
      title: '${signal.side} • ${signal.contract}',
      body: 'Entry ${signal.entry}  |  SL ${signal.stop}  |  TP ${signal.tp}',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'smc_signal_alerts',
          'SMC Signal Alerts',
          channelDescription: 'Peringatan saat bot menemukan signal SMC.',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
      payload: signal.contract,
    );
  }
}
