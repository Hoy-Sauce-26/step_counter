import '../services/formatting.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../services/providers.dart';
import 'charts/hourly_bar_chart.dart';

/// Shows a modal with [date]'s (ISO-8601, e.g. "2026-08-11") hourly step
/// breakdown, fetched live via [hourlyStepsForDateProvider].
void showHourlyBreakdownDialog(BuildContext context, DateTime date) {
  final dateStr = dateKey(date);

  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(DateFormat.MMMEd().format(date)),
        content: SizedBox(
          width: double.maxFinite,
          child: Consumer(
            builder: (context, ref, _) {
              final hoursAsync = ref.watch(
                hourlyStepsForDateProvider(dateStr),
              );
              return hoursAsync.when(
                data: (hours) => HourlyBarChart(hours: hours),
                loading: () => const SizedBox(
                  height: 220,
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => SizedBox(
                  height: 220,
                  child: Center(child: Text('Error loading hours: $e')),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
