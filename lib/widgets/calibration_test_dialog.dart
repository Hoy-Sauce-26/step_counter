import 'dart:async';
import '../services/preferences_service.dart';

import 'package:flutter/material.dart';

import '../services/pedometer_service.dart';

const _targetSteps = 100;
const _minStepsToFinish = 20;

/// Guided calibration test: tap Start, walk ~100 steps, tap Done.
/// Compares the raw count to 100 and suggests a factor, clamped to the
/// same 90-110% range as the manual slider. Returns null if cancelled.
Future<double?> showCalibrationTestDialog(
  BuildContext context,
  PedometerService pedometerService,
) {
  return showDialog<double>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _CalibrationTestDialog(pedometerService: pedometerService),
  );
}

class _CalibrationTestDialog extends StatefulWidget {
  final PedometerService pedometerService;
  const _CalibrationTestDialog({required this.pedometerService});

  @override
  State<_CalibrationTestDialog> createState() =>
      _CalibrationTestDialogState();
}

class _CalibrationTestDialogState extends State<_CalibrationTestDialog> {
  StreamSubscription<int>? _subscription;
  int _rawSteps = 0;
  bool _started = false;

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _start() {
    setState(() {
      _started = true;
      _rawSteps = 0;
    });
    _subscription = widget.pedometerService.startCalibrationTest((raw) {
      if (mounted) setState(() => _rawSteps = raw);
    });
  }

  double get _suggestedFactor =>
      (_targetSteps / _rawSteps).clamp(PreferencesService.minCorrectionFactor, PreferencesService.maxCorrectionFactor);

  void _finish() {
    _subscription?.cancel();
    Navigator.of(context).pop(_rawSteps > 0 ? _suggestedFactor : null);
  }

  void _cancel() {
    _subscription?.cancel();
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Calibration test'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_started)
            Text(
              'Tap Start, then walk exactly $_targetSteps steps carrying '
              "your phone the way you normally do. Tap Done when you're "
              'finished — the closer to exactly $_targetSteps steps, the '
              'more accurate the result.',
            )
          else ...[
            Text(
              '$_rawSteps',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              'raw steps counted so far (target: $_targetSteps)',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (_rawSteps > 0)
              Text(
                _rawSteps < _minStepsToFinish
                    ? 'Keep walking — need at least $_minStepsToFinish '
                        'steps counted before finishing.'
                    : 'If you stop now: suggested calibration '
                        '${(_suggestedFactor * 100).round()}%',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
        if (!_started)
          FilledButton(onPressed: _start, child: const Text('Start'))
        else
          FilledButton(
            onPressed: _rawSteps >= _minStepsToFinish ? _finish : null,
            child: const Text('Done'),
          ),
      ],
    );
  }
}
