import 'package:flutter/material.dart';

import '../services/metrics.dart';
import '../services/pedometer_service.dart';
import '../services/preferences_service.dart';
import 'cadence_test_dialog.dart';
import 'calibration_test_dialog.dart';

/// The two calibrations, which measure different things and are saved
/// together: [correctionFactor] corrects the sensor's counting,
/// [stepsPerMinute] describes the walker.
class CalibrationResult {
  final double correctionFactor;
  final double stepsPerMinute;

  const CalibrationResult({
    required this.correctionFactor,
    required this.stepsPerMinute,
  });
}

/// Shows the calibration dialog. [currentFactor] and the returned
/// [CalibrationResult.correctionFactor] are fractions (1.0 = 100%, i.e. no
/// correction); cadence is in steps per minute. Returns null if cancelled.
Future<CalibrationResult?> showCalibrationDialog(
  BuildContext context,
  double currentFactor,
  double currentStepsPerMinute,
  PedometerService pedometerService,
) {
  var factor = currentFactor.clamp(
    PreferencesService.minCorrectionFactor,
    PreferencesService.maxCorrectionFactor,
  );
  var cadence = currentStepsPerMinute.clamp(
    PreferencesService.minStepsPerMinute,
    PreferencesService.maxStepsPerMinute,
  );

  return showDialog<CalibrationResult>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          final theme = Theme.of(context);

          return AlertDialog(
            title: const Text('Calibration'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Step count', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  const Text(
                    'If the app is over- or under-counting compared to your '
                    'actual steps, adjust this to correct it. For example, '
                    'if it reads 10% high, set this to 90%.',
                  ),
                  const SizedBox(height: 8),
                  _CalibrationSlider(
                    min: PreferencesService.minCorrectionFactor,
                    max: PreferencesService.maxCorrectionFactor,
                    divisions: 40,
                    value: factor,
                    label: '${(factor * 100).round()}%',
                    onChanged: (v) => setState(() => factor = v),
                  ),
                  Center(
                    child: TextButton.icon(
                      icon: const Icon(Icons.directions_walk),
                      label: const Text('Begin 100-step test'),
                      onPressed: () async {
                        final result = await showCalibrationTestDialog(
                          context,
                          pedometerService,
                        );
                        if (result != null) {
                          setState(() => factor = result);
                        }
                      },
                    ),
                  ),
                  const Divider(height: 24),
                  Text('Walking pace', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  const Text(
                    'How many steps you take in a minute. Sets how long the '
                    'app thinks you were active, and — together with your '
                    'height — how hard it thinks you were working.',
                  ),
                  const SizedBox(height: 8),
                  _CalibrationSlider(
                    min: PreferencesService.minStepsPerMinute,
                    max: PreferencesService.maxStepsPerMinute,
                    divisions:
                        (PreferencesService.maxStepsPerMinute -
                                PreferencesService.minStepsPerMinute)
                            .round(),
                    value: cadence,
                    label: '${cadence.round()}',
                    valueLabel: '${cadence.round()}/min',
                    onChanged: (v) => setState(() => cadence = v),
                  ),
                  Center(
                    child: TextButton.icon(
                      icon: const Icon(Icons.timer_outlined),
                      label: const Text('Measure for 1 minute'),
                      onPressed: () async {
                        final result = await showCadenceTestDialog(context);
                        if (result != null) {
                          setState(() => cadence = result);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => setState(() {
                  factor = PreferencesService.defaultCorrectionFactor;
                  cadence = StepMetrics.defaultStepsPerMinute;
                }),
                child: const Text('Reset'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  CalibrationResult(
                    correctionFactor: factor,
                    stepsPerMinute: cadence,
                  ),
                ),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// A slider with its value pinned to the right, so the two calibrations
/// line up instead of each inventing their own layout.
class _CalibrationSlider extends StatelessWidget {
  final double min;
  final double max;
  final int divisions;
  final double value;
  final String label;
  final String? valueLabel;
  final ValueChanged<double> onChanged;

  const _CalibrationSlider({
    required this.min,
    required this.max,
    required this.divisions,
    required this.value,
    required this.label,
    required this.onChanged,
    this.valueLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Slider(
            min: min,
            max: max,
            divisions: divisions,
            value: value.clamp(min, max),
            label: label,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(
            valueLabel ?? label,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ],
    );
  }
}
