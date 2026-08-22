import 'package:flutter/material.dart';

/// Dialog to add steps the sensor missed — a walk with the phone left behind,
/// a session that went untracked — to today's total. Returns the amount, or
/// null if cancelled.
///
/// The credit lands on the day and on no hour (see
/// `StepProjection.creditManualSteps`), so the hourly chart is never made to
/// claim someone walked at a time they didn't. The dialog says so, because a
/// total that moves while the hourly breakdown doesn't otherwise reads as a
/// bug.
Future<int?> showAddStepsDialog(BuildContext context) {
  return showDialog<int>(
    context: context,
    builder: (context) => const _AddStepsDialog(),
  );
}

class _AddStepsDialog extends StatefulWidget {
  const _AddStepsDialog();

  @override
  State<_AddStepsDialog> createState() => _AddStepsDialogState();
}

class _AddStepsDialogState extends State<_AddStepsDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The entered amount, or null if it isn't one. Steps can only be added:
  /// the accumulator rejects anything at or below zero, and a total that can
  /// be typed downwards is a total that can be typed below the sensor's own
  /// reading, which the next reading would silently undo.
  int? get _amount {
    final value = int.tryParse(_controller.text.trim());
    return (value != null && value > 0) ? value : null;
  }

  void _submit() {
    final amount = _amount;
    if (amount != null) Navigator.of(context).pop(amount);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Add steps'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: const InputDecoration(suffixText: 'steps'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          Text(
            "Added to today's total. Credited steps have no time of day, so "
            "they won't appear in the hourly breakdown.",
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Disabled rather than silently doing nothing on an empty or
          // nonsense entry.
          onPressed: _amount == null ? null : _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
