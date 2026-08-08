import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/metrics.dart';
import '../services/providers.dart';
import '../widgets/charts/monthly_bar_chart.dart';
import '../widgets/charts/weekly_bar_chart.dart';
import '../widgets/charts/yearly_bar_chart.dart';

class AnalyticsPage extends ConsumerWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(dailyTargetProvider);
    final past7Days = ref.watch(past7DaysProvider);
    final monthRecords = ref.watch(currentMonthRecordsProvider);
    final yearlyTotals = ref.watch(yearlyMonthlyTotalsProvider);

    final now = DateTime.now();
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;

    return Scaffold(
      appBar: AppBar(title: const Text('Analytics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionTitle('Past 7 days'),
          past7Days.when(
            data: (records) {
              final avg = records.isEmpty
                  ? 0.0
                  : records.fold<int>(0, (s, r) => s + r.stepCount) /
                      records.length;
              return WeeklyBarChart(last7Days: records, average: avg);
            },
            loading: () => const _ChartLoading(),
            error: (e, _) => _ChartError('$e'),
          ),
          const SizedBox(height: 32),
          _SectionTitle('This month'),
          monthRecords.when(
            data: (records) => MonthlyBarChart(
              monthRecords: records,
              daysInMonth: daysInMonth,
            ),
            loading: () => const _ChartLoading(),
            error: (e, _) => _ChartError('$e'),
          ),
          const SizedBox(height: 32),
          _SectionTitle('This year vs target'),
          yearlyTotals.when(
            data: (totals) {
              final percentages = <int, double>{};
              for (var m = 1; m <= 12; m++) {
                final dim = DateTime(now.year, m + 1, 0).day;
                percentages[m] = StepMetrics.monthlyProgressPercent(
                  totalSteps: totals[m] ?? 0,
                  dailyTarget: target,
                  daysInMonth: dim,
                );
              }
              return YearlyBarChart(monthlyProgressPercent: percentages);
            },
            loading: () => const _ChartLoading(),
            error: (e, _) => _ChartError('$e'),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _ChartLoading extends StatelessWidget {
  const _ChartLoading();
  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      );
}

class _ChartError extends StatelessWidget {
  final String message;
  const _ChartError(this.message);
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 220,
        child: Center(child: Text('Error: $message')),
      );
}
