import 'dart:async';

import 'package:flutter_background_service/flutter_background_service.dart';

/// Every message crossing the isolate boundary, defined once.
///
/// These used to be bare strings written twice — once at the `invoke`, once at
/// the matching `on` — with untyped maps and hand-written casts at both ends.
/// Nothing checked that the two spellings agreed, and a mismatch is silent: the
/// sender succeeds, the listener simply never fires. That is exactly how B3
/// went unnoticed, with the daily target being written and never arriving.
///
/// Each channel below names itself once and carries its own encoding, so a
/// typo is a compile error rather than a setting that quietly stops working.
/// Direction is part of the type: [ServiceCommand] only travels app → service
/// and [ServiceReport] only service → app, so neither can be sent backwards.

/// A message the app sends to the background service.
class ServiceCommand<T> {
  const ServiceCommand(this.name, this._encode, this._decode);

  final String name;
  final Map<String, dynamic> Function(T value) _encode;
  final T? Function(Map<String, dynamic> payload) _decode;

  void send(FlutterBackgroundService service, T value) =>
      service.invoke(name, _encode(value));

  /// Registers [onCommand] in the service isolate. A payload that doesn't
  /// decode is dropped rather than thrown: the only sender is this same app,
  /// so a malformed one means an updated app is talking to a service still
  /// running the previous build, and killing the isolate would be worse than
  /// ignoring one message.
  StreamSubscription<Map<String, dynamic>?> handle(
    ServiceInstance service,
    void Function(T value) onCommand,
  ) {
    return service.on(name).listen((payload) {
      if (payload == null) return;
      final value = _decode(payload);
      if (value != null) onCommand(value);
    });
  }
}

/// A command with nothing to say beyond having happened.
class ServiceSignal {
  const ServiceSignal(this.name);

  final String name;

  void send(FlutterBackgroundService service) => service.invoke(name);

  StreamSubscription<Map<String, dynamic>?> handle(
    ServiceInstance service,
    void Function() onSignal,
  ) {
    return service.on(name).listen((_) => onSignal());
  }
}

/// A message the background service sends to the app.
class ServiceReport<T> {
  const ServiceReport(this.name, this._encode, this._decode);

  final String name;
  final Map<String, dynamic> Function(T value) _encode;
  final T? Function(Map<String, dynamic> payload) _decode;

  void send(ServiceInstance service, T value) =>
      service.invoke(name, _encode(value));

  StreamSubscription<Map<String, dynamic>?> listen(
    FlutterBackgroundService service,
    void Function(T value) onReport,
  ) {
    return service.on(name).listen((payload) {
      if (payload == null) return;
      final value = _decode(payload);
      if (value != null) onReport(value);
    });
  }
}

// ---------------------------------------------------------------------------
// Commands: app → service
// ---------------------------------------------------------------------------

/// Neither of these can be read from storage in the service isolate —
/// SharedPreferences hands each isolate a private copy — so this channel is
/// the only way a change reaches it.
final setCorrectionFactor = ServiceCommand<double>(
  'setCorrectionFactor',
  (factor) => {'factor': factor},
  // num, not double: a value that crosses the isolate boundary as a whole
  // number can arrive as an int.
  (payload) => (payload['factor'] as num?)?.toDouble(),
);

final setDailyTarget = ServiceCommand<int>(
  'setDailyTarget',
  (target) => {'target': target},
  (payload) => (payload['target'] as num?)?.toInt(),
);

final addManualSteps = ServiceCommand<int>(
  'addManualSteps',
  (steps) => {'steps': steps},
  (payload) => (payload['steps'] as num?)?.toInt(),
);

final startRoute = ServiceCommand<StartRoute>(
  'startRoute',
  (route) => {'routeId': route.routeId, 'routeName': route.routeName},
  (payload) {
    final id = payload['routeId'] as int?;
    final name = payload['routeName'] as String?;
    if (id == null || name == null) return null;
    return StartRoute(routeId: id, routeName: name);
  },
);

const stopRoute = ServiceSignal('stopRoute');

// ---------------------------------------------------------------------------
// Reports: service → app
// ---------------------------------------------------------------------------

final stepUpdate = ServiceReport<StepUpdate>(
  'stepUpdate',
  (update) => {'steps': update.steps, 'date': update.date},
  (payload) => StepUpdate(
    steps: payload['steps'] as int? ?? 0,
    date: payload['date'] as String?,
  ),
);

final rawStep = ServiceReport<int>(
  'rawStep',
  (raw) => {'raw': raw},
  (payload) => payload['raw'] as int?,
);

final routeUpdate = ServiceReport<int>(
  'routeUpdate',
  (steps) => {'steps': steps},
  (payload) => payload['steps'] as int?,
);

final sensorStatus = ServiceReport<bool>(
  'sensorStatus',
  (available) => {'available': available},
  (payload) => payload['available'] as bool?,
);

// ---------------------------------------------------------------------------
// Payloads
// ---------------------------------------------------------------------------

class StartRoute {
  const StartRoute({required this.routeId, required this.routeName});

  final int routeId;
  final String routeName;
}

class StepUpdate {
  const StepUpdate({required this.steps, required this.date});

  final int steps;

  /// The day this count belongs to, so the app can tell a live figure from a
  /// stored one that may be seconds behind it.
  final String? date;
}
