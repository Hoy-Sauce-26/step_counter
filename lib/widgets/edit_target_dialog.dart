import 'package:flutter/material.dart';

/// Shows a dialog to edit the daily step target; returns the new target
/// (or null if cancelled).
Future<int?> showEditTargetDialog(BuildContext context, int currentTarget) {
  final controller = TextEditingController(text: currentTarget.toString());

  return showDialog<int>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Daily step target'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            suffixText: 'steps',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value != null && value > 0) {
                Navigator.of(context).pop(value);
              }
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}
