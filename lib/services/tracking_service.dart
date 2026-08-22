import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The app-side and service-side halves of the step-tracking service.
///
/// Replaces `flutter_background_service`. The shape is deliberately the same
/// — `invoke` to send, `on` to receive — so `service_channel.dart` sits on
/// top of it unchanged.
///
/// Both halves talk to Kotlin over their own MethodChannel; `ServiceBridge`
/// routes between the two isolates. Messages arrive wrapped as
/// `{method, args}` and are unwrapped here.
class _MessagePump {
  _MessagePump(this._channel) {
    _channel.setMethodCallHandler(_receive);
  }

  final MethodChannel _channel;
  final _controller = StreamController<_Message>.broadcast();

  Future<void> _receive(MethodCall call) async {
    if (call.method != 'onMessage') return;
    final payload = call.arguments;
    if (payload is! Map) return;
    final method = payload['method'];
    if (method is! String) return;
    _controller.add(_Message(method, _asStringMap(payload['args'])));
  }

  /// Only messages for [method], with the envelope stripped.
  Stream<Map<String, dynamic>?> on(String method) => _controller.stream
      .where((message) => message.method == method)
      .map((message) => message.args);

  static Map<String, dynamic>? _asStringMap(Object? value) {
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
}

class _Message {
  const _Message(this.method, this.args);

  final String method;
  final Map<String, dynamic>? args;
}

/// The app's handle on the tracking service.
class TrackingService {
  TrackingService._();

  static final TrackingService _instance = TrackingService._();

  factory TrackingService() => _instance;

  static const MethodChannel _channel =
      MethodChannel('com.nttech.roamfree/service_ui');

  late final _MessagePump _pump = _MessagePump(_channel);

  /// Whether the service is up.
  ///
  /// Reports that an Android service object exists and its isolate was
  /// started — not that a reading has arrived since. `stalledFor` in
  /// `background_service.dart` is the liveness question.
  Future<bool> isRunning() async =>
      await _channel.invokeMethod<bool>('isRunning') ?? false;

  /// Starts the service, registering [onServiceStart] as what it runs.
  ///
  /// The handle is persisted on the platform side so a boot start has
  /// something to execute long before any Dart has run.
  Future<void> start(Function entrypoint) async {
    final handle = PluginUtilities.getCallbackHandle(entrypoint);
    if (handle == null) {
      throw StateError(
        'The service entrypoint must be a top-level or static function '
        'annotated @pragma(\'vm:entry-point\').',
      );
    }
    await _channel.invokeMethod<bool>('start', {
      'handle': handle.toRawHandle(),
    });
  }

  /// Stops the service, and with it the ongoing notification.
  Future<void> stop() async {
    invoke('stopService');
  }

  /// Sends a command to the service isolate. Dropped if it isn't running.
  void invoke(String method, [Map<String, dynamic>? args]) {
    _channel.invokeMethod<bool>('sendToService', {
      'method': method,
      'args': args,
    });
  }

  Stream<Map<String, dynamic>?> on(String method) => _pump.on(method);
}

/// The service's handle on itself, from inside its own isolate.
class TrackingServiceInstance {
  TrackingServiceInstance._();

  static final TrackingServiceInstance _instance = TrackingServiceInstance._();

  factory TrackingServiceInstance() => _instance;

  static const MethodChannel _channel =
      MethodChannel('com.nttech.roamfree/service_bg');

  late final _MessagePump _pump = _MessagePump(_channel);

  /// Sends a report to the app. Dropped if the app isn't running — there is
  /// nobody to receive it, and the app re-reads state on resume regardless.
  void invoke(String method, [Map<String, dynamic>? args]) {
    _channel.invokeMethod<bool>('sendToUi', {
      'method': method,
      'args': args,
    });
  }

  Stream<Map<String, dynamic>?> on(String method) => _pump.on(method);

  Future<void> stopSelf() async {
    try {
      await _channel.invokeMethod<bool>('stopService');
    } on PlatformException catch (error) {
      debugPrint('[TrackingService] stopSelf failed: $error');
    }
  }
}
