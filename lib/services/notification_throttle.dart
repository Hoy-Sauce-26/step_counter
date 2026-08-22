import 'dart:async';

/// Rate-limits rewrites of the foreground notification.
///
/// The notification is rewritten on every sensor reading — up to twice a
/// second while walking — and each rewrite is a platform-channel hop, an IPC
/// to `NotificationManagerService` and a SystemUI relayout. Nobody can read a
/// number that changes faster than about once a second, so updates are
/// collapsed into [interval].
///
/// The first update in a quiet period goes out immediately, which is what
/// keeps the notification feeling live. Anything arriving during the window
/// is held, and the most recent one is sent when the window ends — held
/// updates would only overwrite each other anyway, since they all target the
/// same notification id.
///
/// The trailing send is the load-bearing part: the last reading of a walk
/// always reaches the notification, so it can never settle showing a stale
/// total just because the walk ended inside a quiet window.
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

  /// Runs [send] now if the last send is at least [interval] old, otherwise
  /// holds it until the window ends.
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
    // `??=` rather than a reschedule: the window is measured from the last
    // send, so a later arrival must not push the trailing send further out.
    _timer ??= Timer(interval - sinceLast, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Sends whatever is still held. Called on the timer, and directly before
  /// the service stops — a timer that never fires would otherwise leave the
  /// notification one update behind for as long as it stays on screen.
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
