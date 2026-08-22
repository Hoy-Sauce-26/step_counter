import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roameter/roameter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const roameter = Roameter();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  void answerWith(Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(Roameter.methodChannel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(Roameter.methodChannel, null));

  group('StepCountReading.tryParse', () {
    test('reads a well-formed payload', () {
      final reading = StepCountReading.tryParse({
        'steps': 41234,
        'timestamp': 1787412002812,
      });

      expect(reading?.steps, 41234);
      expect(
        reading?.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1787412002812),
      );
    });

    test('accepts a count that crossed the boundary as a double', () {
      // Sensor values are floats on the platform side, so a whole number can
      // arrive either way.
      expect(StepCountReading.tryParse({'steps': 900.0, 'timestamp': 1})?.steps,
          900);
    });

    test('drops rather than throws on anything malformed', () {
      for (final payload in <Object?>[
        null,
        'not a map',
        <String, Object?>{},
        {'steps': 10},
        {'timestamp': 10},
        {'steps': 'ten', 'timestamp': 10},
      ]) {
        expect(StepCountReading.tryParse(payload), isNull,
            reason: 'a malformed message must not throw inside a stream');
      }
    });
  });

  group('isStepCountingAvailable', () {
    test('reports what the platform says', () async {
      answerWith((_) => true);
      expect(await roameter.isStepCountingAvailable(), isTrue);

      answerWith((_) => false);
      expect(await roameter.isStepCountingAvailable(), isFalse);
    });

    test('a platform that answers nothing counts as no sensor', () async {
      answerWith((_) => null);
      expect(await roameter.isStepCountingAvailable(), isFalse);
    });
  });

  group('readStepCount', () {
    test('returns the reading the platform hands back', () async {
      answerWith((_) => {'steps': 5150, 'timestamp': 1787412002812});

      final reading = await roameter.readStepCount();

      expect(calls.single.method, 'readStepCount');
      expect(reading?.steps, 5150);
    });

    test('null when no sensor answered in time', () async {
      answerWith((_) => null);
      expect(await roameter.readStepCount(), isNull);
    });
  });

  group('stepCounts', () {
    test('passes the batch latency the caller asked for', () async {
      Object? seenArguments;
      messenger.setMockStreamHandler(
        Roameter.stepCountChannel,
        _RecordingStreamHandler((arguments) => seenArguments = arguments),
      );
      addTearDown(
        () => messenger.setMockStreamHandler(Roameter.stepCountChannel, null),
      );

      await roameter
          .stepCounts(batchLatency: const Duration(minutes: 5))
          .first
          .timeout(const Duration(seconds: 5), onTimeout: () => throw 'no event');

      expect(
        (seenArguments as Map)['batchLatencyMicros'],
        const Duration(minutes: 5).inMicroseconds,
        reason: 'maxReportLatencyUs is the whole point of the package',
      );
    });

    test('defaults to no batching, so live updates stay live', () async {
      Object? seenArguments;
      messenger.setMockStreamHandler(
        Roameter.stepCountChannel,
        _RecordingStreamHandler((arguments) => seenArguments = arguments),
      );
      addTearDown(
        () => messenger.setMockStreamHandler(Roameter.stepCountChannel, null),
      );

      await roameter.stepCounts().first;

      expect((seenArguments as Map)['batchLatencyMicros'], 0);
    });
  });
}

/// Records the arguments a listen was opened with, then emits one reading.
class _RecordingStreamHandler extends MockStreamHandler {
  _RecordingStreamHandler(this.onArguments);

  final void Function(Object? arguments) onArguments;

  @override
  void onListen(Object? arguments, MockStreamHandlerEventSink events) {
    onArguments(arguments);
    events.success({'steps': 1, 'timestamp': 1787412002812});
  }

  @override
  void onCancel(Object? arguments) {}
}
