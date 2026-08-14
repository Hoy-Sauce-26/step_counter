import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/saved_route.dart';
import '../services/metrics.dart';
import '../services/providers.dart';

/// Saved routes: add one, start/stop tracking against it, see a rough step
/// estimate from past sessions. Shows the live tracking/summary view
/// instead of the list whenever a route is active, however this page was
/// reached.
class RoutesPage extends ConsumerWidget {
  const RoutesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeRoute = ref.watch(activeRouteProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My Routes')),
      body: SafeArea(
        child: activeRoute == null
            ? const _RoutesList()
            : _ActiveRouteView(activeRoute: activeRoute),
      ),
    );
  }
}

class _RoutesList extends ConsumerStatefulWidget {
  const _RoutesList();

  @override
  ConsumerState<_RoutesList> createState() => _RoutesListState();
}

class _RoutesListState extends ConsumerState<_RoutesList> {
  final _nameController = TextEditingController();

  // Ids removed optimistically on swipe — Dismissible needs the item gone
  // by the next build, but the DB delete + refetch is async, so without
  // this the stale list briefly re-shows the same row and Flutter throws.
  final Set<int> _pendingDeletes = {};

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _addAndStart() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final db = ref.read(databaseHelperProvider);
    final id = await db.insertRoute(name);
    ref.invalidate(routesProvider);
    _nameController.clear();
    await ref.read(activeRouteProvider.notifier).startRoute(id, name);
  }

  Future<void> _start(SavedRoute route) async {
    await ref
        .read(activeRouteProvider.notifier)
        .startRoute(route.id, route.name);
  }

  Future<void> _delete(SavedRoute route) async {
    setState(() => _pendingDeletes.add(route.id));
    await ref.read(databaseHelperProvider).deleteRoute(route.id);
    ref.invalidate(routesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final routesAsync = ref.watch(routesProvider);
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      hintText: 'Name a new route',
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _addAndStart(),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _nameController,
                  builder: (context, value, _) => FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start Route'),
                    onPressed:
                        value.text.trim().isEmpty ? null : _addAndStart,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        routesAsync.when(
          data: (allRoutes) {
            final routes = allRoutes
                .where((r) => !_pendingDeletes.contains(r.id))
                .toList();
            return routes.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      'No routes yet — add one above.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                : Column(
                    children: [
                      for (final route in routes)
                        _RouteRow(
                          route: route,
                          onStart: () => _start(route),
                          onDelete: () => _delete(route),
                        ),
                    ],
                  );
          },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child:
                Text('Error loading routes: $e', textAlign: TextAlign.center),
          ),
        ),
      ],
    );
  }
}

class _RouteRow extends StatelessWidget {
  final SavedRoute route;
  final VoidCallback onStart;
  final VoidCallback onDelete;

  const _RouteRow({
    required this.route,
    required this.onStart,
    required this.onDelete,
  });

  Future<bool> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete route?'),
        content: Text(
          'This removes "${route.name}" and its history. This can\'t be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final estimate = route.avgSteps == null
        ? 'Not yet completed'
        : '~${NumberFormat.decimalPattern().format(route.avgSteps!.round())} steps';
    return Dismissible(
      key: ValueKey(route.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) => onDelete(),
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          title: Text(route.name),
          subtitle: Text(estimate),
          trailing: FilledButton.tonalIcon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start Route'),
            onPressed: onStart,
          ),
        ),
      ),
    );
  }
}

/// Frozen stats shown while reviewing the "Stop Route" summary. Only ever
/// held in local widget state — see [_ActiveRouteViewState].
class _RouteSnapshot {
  final int steps;
  final Duration elapsed;
  final DistanceResult distance;
  final double calories;

  const _RouteSnapshot({
    required this.steps,
    required this.elapsed,
    required this.distance,
    required this.calories,
  });
}

class _ActiveRouteView extends ConsumerStatefulWidget {
  final ActiveRoute activeRoute;

  const _ActiveRouteView({required this.activeRoute});

  @override
  ConsumerState<_ActiveRouteView> createState() => _ActiveRouteViewState();
}

class _ActiveRouteViewState extends ConsumerState<_ActiveRouteView> {
  Timer? _ticker;

  // Non-null means "reviewing the Stop Route summary". Setting this is all
  // "Stop Route" does — the route is still genuinely active underneath
  // until "Done" commits it; "Resume" just clears this back to null.
  _RouteSnapshot? _summary;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _stopAndReview(
    int steps,
    Duration elapsed,
    double? heightCm,
    double? weightKg,
    UnitSystem unitSystem,
  ) {
    setState(() {
      _summary = _RouteSnapshot(
        steps: steps,
        elapsed: elapsed,
        distance: StepMetrics.distance(steps, heightCm: heightCm, unit: unitSystem),
        calories: StepMetrics.calories(steps, weightKg: weightKg),
      );
    });
  }

  void _resume() {
    setState(() => _summary = null);
  }

  Future<void> _confirmDone() async {
    final summary = _summary;
    if (summary == null) return;
    final db = ref.read(databaseHelperProvider);
    await db.insertRouteSession(
      routeId: widget.activeRoute.routeId,
      date: _todayString(),
      steps: summary.steps,
      durationSeconds: summary.elapsed.inSeconds,
    );
    ref.invalidate(routesProvider);
    await ref.read(activeRouteProvider.notifier).stopRoute();
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mStr = m.toString().padLeft(2, '0');
    final sStr = s.toString().padLeft(2, '0');
    return h > 0 ? '${h}h ${mStr}m ${sStr}s' : '${m}m ${sStr}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heightCm = ref.watch(heightCmProvider);
    final weightKg = ref.watch(weightKgProvider);
    final unitSystem = ref.watch(unitSystemProvider);
    final liveSteps =
        ref.watch(activeRouteStepsProvider(widget.activeRoute.startTime)).value ??
            0;
    final liveElapsed =
        DateTime.now().difference(widget.activeRoute.startTime);

    final summary = _summary;
    final steps = summary?.steps ?? liveSteps;
    final elapsed = summary?.elapsed ?? liveElapsed;
    final distance = summary?.distance ??
        StepMetrics.distance(steps, heightCm: heightCm, unit: unitSystem);
    final calories =
        summary?.calories ?? StepMetrics.calories(steps, weightKg: weightKg);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.activeRoute.routeName, style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            Text(
              '$steps',
              style: theme.textTheme.displayMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text('steps', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 24),
            Text(_formatDuration(elapsed), style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${distance.value.toStringAsFixed(2)} ${distance.unit}',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(width: 24),
                Text(
                  '${calories.toStringAsFixed(0)} kcal',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 40),
            if (summary == null)
              FilledButton.icon(
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop Route'),
                onPressed: () => _stopAndReview(
                  steps,
                  elapsed,
                  heightCm,
                  weightKg,
                  unitSystem,
                ),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Resume'),
                    onPressed: _resume,
                  ),
                  const SizedBox(width: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Done'),
                    onPressed: _confirmDone,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
