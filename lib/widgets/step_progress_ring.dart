import 'package:flutter/material.dart';

/// Circular progress indicator showing currentSteps / dailyTarget,
/// clamped to 100% once the goal is reached.
class StepProgressRing extends StatelessWidget {
  final int currentSteps;
  final int dailyTarget;

  const StepProgressRing({
    super.key,
    required this.currentSteps,
    required this.dailyTarget,
  });

  @override
  Widget build(BuildContext context) {
    final progress = dailyTarget > 0
        ? (currentSteps / dailyTarget).clamp(0.0, 1.0)
        : 0.0;
    final theme = Theme.of(context);

    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 220,
            height: 220,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 14,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
              strokeCap: StrokeCap.round,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$currentSteps',
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              Text(
                'of $dailyTarget steps',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                '${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
