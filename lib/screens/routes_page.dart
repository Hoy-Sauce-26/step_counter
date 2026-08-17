import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/saved_route.dart';
import '../services/formatting.dart';
import '../services/metrics.dart';
import '../services/providers.dart';

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
    if (mounted) setState(() => _pendingDeletes.remove(route.id));
  }

  Future<void> _logToday(SavedRoute route) async {
    final amount = route.avgSteps!.round();
    await ref.read(pedometerServiceProvider).addManualSteps(amount);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added $amount steps to today')),
    );
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
                          onLogToday: () => _logToday(route),
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
  final VoidCallback onLogToday;

  const _RouteRow({
    required this.route,
    required this.onStart,
    required this.onDelete,
    required this.onLogToday,
  });

  Future<void> _confirmLogToday(BuildContext context) async {
    final amount = route.avgSteps!.round();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add to today?'),
        content: Text(
          'This adds ~$amount steps (this route\'s average) to today\'s '
          'total, without starting a new tracked route.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (confirmed == true) onLogToday();
  }

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
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                tooltip: 'More',
                padding: EdgeInsets.zero,
                onSelected: (value) async {
                  if (value == 'logToday') {
                    await _confirmLogToday(context);
                  } else if (value == 'delete') {
                    final confirmed = await _confirmDelete(context);
                    if (confirmed) onDelete();
                  }
                },
                itemBuilder: (context) => [
                  if (route.avgSteps != null)
                    const PopupMenuItem(
                      value: 'logToday',
                      child: Text("Add to Today's Steps"),
                    ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Delete',
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(route.name, style: Theme.of(context).textTheme.titleMedium),
                    Text(
                      estimate,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start Route'),
                onPressed: onStart,
              ),
            ],
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

  // Non-null means "reviewing the Stop Route summary".
  _RouteSnapshot? _summary;

  @override
  void initState() {
    super.initState();
    // Only drives the elapsed-time readout, which is frozen while the stop
    // summary is up — no point repainting the screen once a second behind it.
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (_summary == null) setState(() {});
      },
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
      date: todayKey(),
      steps: summary.steps,
      durationSeconds: summary.elapsed.inSeconds,
    );
    ref.invalidate(routesProvider);
    await ref.read(activeRouteProvider.notifier).stopRoute();
  }

  Future<void> _cancel() async {
    final db = ref.read(databaseHelperProvider);
    final isUnused =
        await db.getSessionCountForRoute(widget.activeRoute.routeId) == 0;
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this route?'),
        content: Text(
          isUnused
              ? "This route has no completed sessions yet, so cancelling "
                  "removes it entirely rather than leaving an empty entry."
              : "This route's progress won't be saved, and its average "
                  "won't change — your steps still count toward today's "
                  "total either way.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep Going'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel Route'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // No insertRouteSession call — that's the whole point, this route's
    // average stays exactly as it was.
    if (isUnused) {
      await db.deleteRoute(widget.activeRoute.routeId);
    }
    // Both of these must happen before stopRoute()
    ref.invalidate(routesProvider);
    await ref.read(activeRouteProvider.notifier).stopRoute();
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
            Text(formatDuration(elapsed), style: theme.textTheme.headlineSmall),
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
              Column(
                children: [
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
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _cancel,
                    child: const Text('Cancel Route'),
                  ),
                ],
              )
            else
              Column(
                children: [
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
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _cancel,
                    child: const Text('Cancel Route'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
