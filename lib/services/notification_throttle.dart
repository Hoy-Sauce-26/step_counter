import 'dart:async';

/// Rate-limits rewrites of the foreground notification: leading edge fires
/// immediately, anything arriving inside [interval] is coalesced into one
/// trailing send so the last reading of a walk always lands.
class NotificationThrottle {
  NotificationThrottle({
    this.interval = const Duration(seconds: 1),
    DateTime Function() clock = DateTime.now,
  }) : _clock = clock;

  final Duration interval;
  final DateTime Function() _clock;

  DateTime? _lastSentAt;
  Future<void> Function()? _pending;
  Timer? _timer;

  void run(Future<void> Function() send) {
    final now = _clock();
    final last = _lastSentAt;
    final sinceLast = last == null ? null : now.difference(last);

    if (sinceLast == null || sinceLast >= interval || sinceLast.isNegative) {
      _lastSentAt = now;
      unawaited(send());
      return;
    }

    _pending = send;
    // ??= : the window is measured from the last send, so a later arrival
    // must not push the trailing send further out.
    _timer ??= Timer(interval - sinceLast, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Sends whatever is still held. Also called directly before the service
  /// stops, since a timer that never fires would leave it one update behind.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    _lastSentAt = _clock();
    await pending();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
