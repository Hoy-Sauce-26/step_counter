import 'package:flutter/material.dart';

/// Shows a dialog to calibrate the step sensor's known over/under-counting.
/// [currentFactor] and the return value are both fractions (1.0 = 100%,
/// i.e. no correction). Returns null if cancelled.
Future<double?> showCalibrationDialog(
  BuildContext context,
  double currentFactor,
) {
  var factor = currentFactor;

  return showDialog<double>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Step calibration'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'If the app is over- or under-counting compared to your '
                  'actual steps, adjust this to correct it. For example, '
                  'if it reads 10% high, set this to 90%.',
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        min: 0.7,
                        max: 1.3,
                        divisions: 60,
                        value: factor.clamp(0.7, 1.3),
                        label: '${(factor * 100).round()}%',
                        onChanged: (v) => setState(() => factor = v),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(
                        '${(factor * 100).round()}%',
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => setState(() => factor = 1.0),
                child: const Text('Reset'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(factor),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );
}
