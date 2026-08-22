import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/preferences_service.dart';

const _testDuration = Duration(minutes: 1);

/// Guided cadence test: tap Start, walk normally counting your own steps,
/// and enter the count when the minute is up. One minute means the number
/// counted *is* the steps-per-minute — no arithmetic, and no reliance on the
/// sensor, so it stays honest even when the step counter is miscounting.
///
/// Returns steps per minute, clamped to the stored range, or null if
/// cancelled.
Future<double?> showCadenceTestDialog(BuildContext context) {
  return showDialog<double>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _CadenceTestDialog(),
  );
}

class _CadenceTestDialog extends StatefulWidget {
  const _CadenceTestDialog();

  @override
  State<_CadenceTestDialog> createState() => _CadenceTestDialogState();
}

class _CadenceTestDialogState extends State<_CadenceTestDialog> {
  final _controller = TextEditingController();
  Timer? _ticker;
  Duration _remaining = _testDuration;
  bool _started = false;
  bool _finished = false;

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    setState(() {
      _started = true;
      _remaining = _testDuration;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      final left = _remaining - const Duration(seconds: 1);
      if (left > Duration.zero) {
        setState(() => _remaining = left);
        return;
      }
      timer.cancel();
      setState(() {
        _remaining = Duration.zero;
        _finished = true;
      });
      // Both, because the phone is in a pocket: a walker won't see the
      // screen, and either the sound or the buzz may be the one they get.
      unawaited(HapticFeedback.vibrate());
      unawaited(SystemSound.play(SystemSoundType.alert));
    });
  }

  int? get _counted {
    final value = int.tryParse(_controller.text.trim());
    return (value != null && value > 0) ? value : null;
  }

  /// What the entered figure will actually be stored as.
  double? get _clamped => _counted?.toDouble().clamp(
        PreferencesService.minStepsPerMinute,
        PreferencesService.maxStepsPerMinute,
      );

  void _finishUp() {
    final clamped = _clamped;
    if (clamped == null) return;
    Navigator.of(context).pop(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counted = _counted;
    final clamped = _clamped;

    return AlertDialog(
      title: const Text('Measure your pace'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_started)
            const Text(
              'Tap Start and walk at your normal pace for one minute, '
              'counting your steps as you go. Your phone will buzz when the '
              "minute is up — then type in the number you counted.\n\n"
              "Count them yourself rather than trusting the sensor: that's "
              'what makes this independent of the step calibration above.',
            )
          else if (!_finished) ...[
            Text(
              '${_remaining.inSeconds}',
              textAlign: TextAlign.center,
              style: theme.textTheme.displaySmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              'seconds left — keep walking and counting',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ] else ...[
            Text(
              'How many steps did you count?',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                suffixText: 'steps',
              ),
            ),
            if (counted != null && clamped != counted) ...[
              const SizedBox(height: 8),
              Text(
                '$counted is outside the range this can use '
                '(${PreferencesService.minStepsPerMinute.round()}–'
                '${PreferencesService.maxStepsPerMinute.round()}), so it '
                'will be saved as ${clamped!.round()}.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (!_started)
          FilledButton(onPressed: _start, child: const Text('Start'))
        else
          FilledButton(
            onPressed: _finished && counted != null ? _finishUp : null,
            child: const Text('Save'),
          ),
      ],
    );
  }
}
