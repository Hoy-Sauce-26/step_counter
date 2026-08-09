import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
  FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsIOS =
    DarwinInitializationSettings();

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await _notificationsPlugin.initialize(settings: initializationSettings);
  }

  // Request permission (Android 13+ / iOS)
  static Future<void> requestPermissions() async {
    final androidImplementation = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImplementation?.requestNotificationsPermission();
  }

  static const int _stepNotificationId = 888;

  static Future<void> updateStepNotification({
    required int steps,
    required int target,
  }) async {
    final double percentage = ((steps / target) * 100).clamp(0, 100);

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'step_counter_channel', // Channel ID
      'Step Counter Updates', // Channel Name
      channelDescription: 'Ongoing daily step counter notification',
      importance: Importance.low, // Keeps it quiet when updating frequently
      priority: Priority.low,
      ongoing: true,              // Prevents swipe-to-dismiss
      autoCancel: false,          // Keeps notification active on click
      onlyAlertOnce: true,       // Prevents sound/vibration on every step update
      icon: '@mipmap/ic_launcher',
      showProgress: true,
      maxProgress: target,
      progress: steps.clamp(0, target),
    );

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(),
    );

    await _notificationsPlugin.show(
      id: _stepNotificationId,
      title: 'Today\'s Steps: $steps / $target',
      body: '${percentage.toStringAsFixed(1)}% of your daily goal reached!',
      notificationDetails: notificationDetails,
    );
  }

  static Future<void> cancelNotification() async {
    await _notificationsPlugin.cancel(id: _stepNotificationId);
  }
}