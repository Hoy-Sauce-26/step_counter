import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'formatting.dart';

class NotificationService {
  /// The channel id is a durable identifier: users' per-channel settings hang
  /// off it, so changing it orphans their choices and quietly creates a second
  /// channel. The name is display text and is safe to change.
  static const String channelId = 'step_counter_channel';
  static const String channelName = 'Step tracking';
  static const String channelDescription =
      'Ongoing daily step counter notification';

  /// One id for one ongoing notification — the foreground service's and this
  /// service's must match, or the service's placeholder never gets replaced.
  static const int notificationId = 888;

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

    final androidPlugin = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin != null) {
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDescription,
        importance: Importance.low,
      );

      await androidPlugin.createNotificationChannel(channel);
    }
  }

  // For a future "enable notifications" button, if we need one manually.
  static Future<void> requestPermissions() async {
    final androidImplementation = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImplementation?.requestNotificationsPermission();
  }

  static Future<void> updateStepNotification({
    required int steps,
    required int target,
  }) async {
    final double percentage = ((steps / target) * 100).clamp(0, 100);

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.low, // Keeps it quiet when updating frequently
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      playSound: false,
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
      id: notificationId,
      title: 'Today\'s Steps: $steps / $target',
      body: '${percentage.toStringAsFixed(1)}% of your daily goal reached!',
      notificationDetails: notificationDetails,
    );
  }

  /// Same notification, showing route progress instead of the daily total.
  /// No progress bar — a route has no target.
  static Future<void> updateRouteNotification({
    required String routeName,
    required int steps,
    required Duration elapsed,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      playSound: false,
      icon: '@mipmap/ic_launcher',
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(),
    );

    await _notificationsPlugin.show(
      id: notificationId,
      title: 'On Route: $routeName',
      body: '$steps steps · ${formatDuration(elapsed)}',
      notificationDetails: notificationDetails,
    );
  }

  static Future<void> showSensorUnavailableNotification() async {
    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      playSound: false,
      icon: '@mipmap/ic_launcher',
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(),
    );

    await _notificationsPlugin.show(
      id: notificationId,
      title: 'Step tracking unavailable',
      body: "This device doesn't have a step-count sensor.",
      notificationDetails: notificationDetails,
    );
  }

}