import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:step_counter/services/notification_throttle.dart';

void main() {
  group('NotificationThrottle', () {
    late DateTime clock;
    late List<String> sent;
    late NotificationThrottle throttle;

    Future<void> send(String label) async => sent.add(label);

    setUp(() {
      clock = DateTime(2026, 8, 21, 12);
      sent = [];
      throttle = NotificationThrottle(
        interval: const Duration(seconds: 1),
        clock: () => clock,
      );
    });

    tearDown(() => throttle.dispose());

    test('sends the first update immediately', () {
      throttle.run(() => send('a'));
      expect(sent, ['a']);
    });

    test('holds an update that lands inside the window', () {
      throttle.run(() => send('a'));
      clock = clock.add(const Duration(milliseconds: 200));
      throttle.run(() => send('b'));
      expect(sent, ['a']);
    });

    test('sends again once the window has passed', () {
      throttle.run(() => send('a'));
      clock = clock.add(const Duration(seconds: 1));
      throttle.run(() => send('b'));
      expect(sent, ['a', 'b']);
    });

    test('a held update is not lost — flush sends it', () async {
      throttle.run(() => send('a'));
      clock = clock.add(const Duration(milliseconds: 200));
      throttle.run(() => send('b'));
      await throttle.flush();
      expect(sent, ['a', 'b']);
    });

    test('only the most recent held update is sent', () async {
      throttle.run(() => send('a'));
      clock = clock.add(const Duration(milliseconds: 100));
      throttle.run(() => send('b'));
      throttle.run(() => send('c'));
      throttle.run(() => send('d'));
      await throttle.flush();
      // b and c would only have been overwritten by d — they target the same
      // notification id.
      expect(sent, ['a', 'd']);
    });

    test('the trailing send fires on its own timer', () {
      fakeAsync((async) {
        throttle.run(() => send('a'));
        clock = clock.add(const Duration(milliseconds: 400));
        throttle.run(() => send('b'));
        expect(sent, ['a']);
        async.elapse(const Duration(milliseconds: 600));
        expect(sent, ['a', 'b']);
      });
    });

    test('flush is a no-op with nothing held', () async {
      throttle.run(() => send('a'));
      await throttle.flush();
      await throttle.flush();
      expect(sent, ['a']);
    });

    test('a backwards clock does not wedge the throttle', () {
      throttle.run(() => send('a'));
      clock = clock.subtract(const Duration(hours: 1));
      throttle.run(() => send('b'));
      expect(sent, ['a', 'b']);
    });
  });
}
